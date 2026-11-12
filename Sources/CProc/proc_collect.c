/* SPDX-License-Identifier: MIT */
#include "CProc.h"
#include "cproc_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>

#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/ucred.h>
#include <sys/vmmeter.h>
#include <libproc.h>

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/task_info.h>

/* xnu bsd/sys/proc_info.h 的 pbi_flags 公开位。旧兜底把 1/2/4/8/0x10…
 * 顺次编号，与真实值全部错位（例如 0x2000 其实是 PSUGID 而不是 LP64），
 * 这里按 xnu 头文件逐项校正。SDK 已导出时 #ifndef 不生效。 */
#ifndef PROC_FLAG_SYSTEM
#define PROC_FLAG_SYSTEM     0x00000001
#endif
#ifndef PROC_FLAG_TRACED
#define PROC_FLAG_TRACED     0x00000002
#endif
#ifndef PROC_FLAG_INEXIT
#define PROC_FLAG_INEXIT     0x00000004
#endif
#ifndef PROC_FLAG_PPWAIT
#define PROC_FLAG_PPWAIT     0x00000008
#endif
#ifndef PROC_FLAG_LP64
#define PROC_FLAG_LP64       0x00000010
#endif
#ifndef PROC_FLAG_SLEADER
#define PROC_FLAG_SLEADER    0x00000020
#endif
#ifndef PROC_FLAG_CTTY
#define PROC_FLAG_CTTY       0x00000040
#endif
#ifndef PROC_FLAG_CONTROLT
#define PROC_FLAG_CONTROLT   0x00000080
#endif
#ifndef PROC_FLAG_THCWD
#define PROC_FLAG_THCWD      0x00000100
#endif
#ifndef PROC_FLAG_PSUGID
#define PROC_FLAG_PSUGID     0x00002000
#endif
#ifndef PROC_FLAG_EXEC
#define PROC_FLAG_EXEC       0x00004000
#endif
/* 不再定义 PROC_FLAG_TRANSLATED：它在 #ifdef PRIVATE 的 proc_info_private.h
 * 里，公开 SDK 不导出，任何硬编码的兜底值都可能与公开位撞车。
 * 运行时是否经 Rosetta 改由 Mach-O 架构可靠推出，见下方 cproc_collect 末尾。 */
#ifndef NODEV
#define NODEV ((dev_t)(-1))
#endif
#ifndef PROC_TTY_ONLY
#define PROC_TTY_ONLY 3
#endif

/* KERN_PROCARGS2 缓冲区上限由偏好设置下发（默认 1 MiB）。
 * 太小会丢掉长命令行，太大则对异常进程做无意义的大额分配。 */
#define CPROC_ARGV_MAX_BYTES() ((size_t)g_cproc_limits.argv_max_bytes)
#define CPROC_ARGC_MAX       4096
#define CPROC_TTY_NODEV_U32  0xffffffffu   /* e_tdev 的「无控制终端」哨兵 */

uint64_t cproc_now_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

const char *cproc_state_name(uint32_t status)
{
    switch (status) {
    case SIDL:   return "IDLE";
    case SRUN:   return "RUNNING";
    case SSLEEP: return "SLEEPING";
    case SSTOP:  return "STOPPED";
    case SZOMB:  return "ZOMBIE";
    default:     return "UNKNOWN";
    }
}

const char *cproc_comm(const cproc_snapshot_t *p)    { return p ? p->comm    : ""; }
const char *cproc_name(const cproc_snapshot_t *p)    { return p ? p->name    : ""; }
const char *cproc_cmdline(const cproc_snapshot_t *p) { return p ? p->cmdline : ""; }
const char *cproc_exepath(const cproc_snapshot_t *p) { return p ? p->exepath : ""; }
const char *cproc_argv0(const cproc_snapshot_t *p)   { return p ? p->argv0   : ""; }
const char *cproc_tty_name(const cproc_snapshot_t *p)
{
    return (p && p->tty_name[0]) ? p->tty_name : "??";
}

/* ------------------------------------------------------------------ */
/* 控制终端 dev_t → /dev/ttysNNN                                       */
/*                                                                    */
/* proc_bsdinfo.e_tdev / kinfo_proc.kp_eproc.e_tdev 是 BSD 层的 dev_t， */
/* 完全不需要 task port。ps 的 TT 列、lsof 的 TTY 列都是这么来的。      */
/* ------------------------------------------------------------------ */

static int tty_has_ctty(uint32_t dev)
{
    return dev != 0 && dev != CPROC_TTY_NODEV_U32;
}

/* Darwin dev_t 编码（xnu bsd/sys/types.h）：major 高 12 位，minor 低 8 位。
 * 自己算，不依赖 SDK 里 major()/minor() 是宏还是函数。 */
static int tty_major(uint32_t dev) { return (int)((dev >> 8) & 0xfff); }
static int tty_minor(uint32_t dev) { return (int)(dev & 0xff); }

typedef struct {
    uint32_t dev;
    char     name[CPROC_TTY_MAX];
} tty_cache_entry_t;

#define CPROC_TTY_CACHE_MAX 128
static tty_cache_entry_t g_tty_cache[CPROC_TTY_CACHE_MAX];
static int g_tty_cache_n = 0;

static const char *tty_cache_get(uint32_t dev)
{
    for (int i = 0; i < g_tty_cache_n; i++)
        if (g_tty_cache[i].dev == dev) return g_tty_cache[i].name;
    return NULL;
}

static void tty_cache_put(uint32_t dev, const char *name)
{
    if (g_tty_cache_n >= CPROC_TTY_CACHE_MAX) return;
    tty_cache_entry_t *e = &g_tty_cache[g_tty_cache_n++];
    e->dev = dev;
    snprintf(e->name, sizeof(e->name), "%s", name);
}

/* 扫描 /dev 找 st_rdev == dev 的字符设备。只在缓存未命中时执行一次。 */
static int tty_scan_dev(uint32_t dev, char *buf, size_t cap)
{
    DIR *d = opendir("/dev");
    if (!d) return -1;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.' || de->d_name[0] == '\0') continue;
        char path[512];
        int k = snprintf(path, sizeof(path), "/dev/%s", de->d_name);
        if (k <= 0 || (size_t)k >= sizeof(path)) continue;

        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (!S_ISCHR(st.st_mode)) continue;
        if ((uint32_t)st.st_rdev != dev) continue;

        snprintf(buf, cap, "%s", path);
        found = 1;
        break;
    }
    closedir(d);
    return found ? 0 : -1;
}

int cproc_tty_devname(uint32_t dev, char *buf, size_t cap)
{
    if (!buf || cap < 8) return -1;
    buf[0] = '\0';
    if (!tty_has_ctty(dev)) return -1;

    const char *cached = tty_cache_get(dev);
    if (cached) {
        snprintf(buf, cap, "%s", cached);
        return 0;
    }

    /* 快速路径：devname_r(dev, S_IFCHR, name, len)。
     * 不同 SDK 里它的返回值可能是 int 也可能是 char*，这里只用 buf 内容、
     * 忽略返回值；在 ARM64 / x86_64 上两者 ABI 一致，不会有问题。 */
    typedef int (*devname_r_fn)(dev_t, mode_t, char *, int);
    void *sym = dlsym(RTLD_DEFAULT, "devname_r");
    devname_r_fn fn = NULL;
    if (sym) memcpy(&fn, &sym, sizeof(fn));
    if (fn) {
        char name[256] = { 0 };
        (void)fn((dev_t)dev, (mode_t)S_IFCHR, name, (int)sizeof(name));
        if (name[0] && name[0] != '?' && name[0] != '#') {
            char full[CPROC_TTY_MAX];
            snprintf(full, sizeof(full), "/dev/%s", name);
            tty_cache_put(dev, full);
            snprintf(buf, cap, "%s", full);
            return 0;
        }
    }

    /* 兜底 1：扫描 /dev 比对 st_rdev */
    char full[CPROC_TTY_MAX];
    if (tty_scan_dev(dev, full, sizeof(full)) == 0) {
        tty_cache_put(dev, full);
        snprintf(buf, cap, "%s", full);
        return 0;
    }

    /* 兜底 2：ptys slave 的名字按 minor 编号直接构造（devname_r 不可用、
     * /dev 扫描也找不到时给出可读结果，标注为推断值由 UI 负责） */
    snprintf(full, sizeof(full), "/dev/ttys%03d", tty_minor(dev));
    tty_cache_put(dev, full);
    snprintf(buf, cap, "%s", full);
    return 0;
}

/* 供 proc_detail.c 复用：判断 dev 是否代表有控制终端 */
int cproc_tty_has_ctty(uint32_t dev) { return tty_has_ctty(dev); }
int cproc_tty_major(uint32_t dev)    { return tty_major(dev); }
int cproc_tty_minor(uint32_t dev)    { return tty_minor(dev); }

static void cstr_copy(char *dst, size_t cap, const char *src)
{
    if (cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    size_t n = strnlen(src, cap - 1);
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static int get_all_kinfo(struct kinfo_proc **out_procs, int *out_cnt)
{
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t need = 0;
    struct kinfo_proc *procs = NULL;

    if (sysctl(mib, 3, NULL, &need, NULL, 0) == -1)
        return -1;
    if (need == 0 || need % sizeof(struct kinfo_proc) != 0)
        return -1;

    /* 进程数可能在两次调用之间变化，多申请一点余量 */
    need += sizeof(struct kinfo_proc) * 16;
    procs = malloc(need);
    if (!procs)
        return -1;

    if (sysctl(mib, 3, procs, &need, NULL, 0) == -1) {
        free(procs);
        return -1;
    }
    *out_procs = procs;
    *out_cnt = (int)(need / sizeof(struct kinfo_proc));
    return 0;
}

/*
 * 读取完整命令行 + 可执行文件路径。
 *
 * 两个容易踩的陷阱：
 *   - KERN_PROCARGS2 返回的 needed 是字节数，写进固定 4096 字节栈数组会溢出；
 *     这里按 needed 动态分配并全程做边界检查。
 *   - 把缓冲区里所有以 '\0' 结尾的串（含 envp）都拼进命令行会混入环境变量；
 *     这里严格按 argc 取 argv[0..argc-1]。
 *   - argv[0] 单独保留原始串：拼进 cmdline 后若参数含空格就无法还原，而
 *     argv[0] 可能与 proc_pidpath 给出的规范可执行名不同（硬链接 /bin/sh
 *     → /bin/bash、exec -a 自定义名、登录 shell 的 -bash 等）。
 */
static void read_cmdline(int32_t pid, char *out, size_t outcap,
                         char *exe, size_t execap,
                         char *argv0, size_t argv0cap)
{
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t need = 0;
    char *raw = NULL;
    char pathbuf[MAXPATHLEN];

    out[0] = '\0';
    exe[0] = '\0';
    if (argv0 && argv0cap) argv0[0] = '\0';

    if (sysctl(mib, 3, NULL, &need, NULL, 0) == 0 &&
        need > sizeof(int) && need <= CPROC_ARGV_MAX_BYTES()) {
        raw = malloc(need);
        if (raw) {
            size_t got = need;
            if (sysctl(mib, 3, raw, &got, NULL, 0) == 0) {
                char *end = raw + got;
                char *p = raw + sizeof(int);
                int argc = 0;
                memcpy(&argc, raw, sizeof(int));
                if (argc < 0 || argc > CPROC_ARGC_MAX) argc = 0;

                /* exe path：同样按已知长度复制，不假设末尾一定有 NUL */
                char *s = p;
                while (p < end && *p) p++;
                {
                    size_t n = (size_t)(p - s);
                    if (n >= execap) n = execap - 1;
                    memcpy(exe, s, n);
                    exe[n] = '\0';
                }
                if (p < end) p++;

                /* 对齐用的多余 NUL */
                while (p < end && *p == '\0') p++;

                char *o = out;
                char *olimit = out + outcap - 1;
                int written = 0;
                for (int i = 0; i < argc && p < end; i++) {
                    char *arg = p;
                    while (p < end && *p) p++;
                    size_t raw_len = (size_t)(p - arg);
                    size_t len = raw_len;
                    /* 缓冲区最后一个串可能没有 NUL 结尾，不能当 C 字符串用，
                     * 按已知长度复制，避免读越界。 */
                    if (i == 0 && argv0 && argv0cap) {
                        size_t n = raw_len < argv0cap ? raw_len : argv0cap - 1;
                        memcpy(argv0, arg, n);
                        argv0[n] = '\0';
                    }
                    if (written && o < olimit) *o++ = ' ';
                    size_t room = (size_t)(olimit - o);
                    if (len > room) len = room;
                    if (len && o < olimit) { memcpy(o, arg, len); o += len; }
                    written++;
                    if (p < end) p++;
                }
                *o = '\0';
            }
            free(raw);
        }
    }

    /* proc_pidpath 给出规范化的可执行文件路径，优先采用 */
    int n = proc_pidpath((int)pid, pathbuf, sizeof(pathbuf));
    if (n > 0)
        cstr_copy(exe, execap, pathbuf);
}

static void collect_system(cproc_system_t *s, int proc_count)
{
    int32_t v32 = 0;
    uint64_t v64 = 0;
    size_t sz;

    sz = sizeof(v32);
    if (sysctlbyname("hw.logicalcpu", &v32, &sz, NULL, 0) == 0)
        s->logical_cpus = (uint32_t)v32;
    sz = sizeof(v32);
    if (sysctlbyname("hw.physicalcpu", &v32, &sz, NULL, 0) == 0)
        s->physical_cpus = (uint32_t)v32;
    sz = sizeof(v64);
    if (sysctlbyname("hw.memsize", &v64, &sz, NULL, 0) == 0)
        s->mem_total = v64;
    sz = sizeof(v32);
    if (sysctlbyname("hw.optional.arm64", &v32, &sz, NULL, 0) == 0 && v32)
        s->host_arm64 = 1;
    if (s->logical_cpus == 0) s->logical_cpus = 1;
    if (s->physical_cpus == 0) s->physical_cpus = s->logical_cpus;

    vm_statistics64_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        uint64_t page = (uint64_t)getpagesize();
        uint64_t free_pages = vm.free_count > vm.speculative_count
                            ? vm.free_count - vm.speculative_count : 0;
        s->mem_free       = free_pages * page;
        s->mem_wired      = (uint64_t)vm.wire_count * page;
        s->mem_compressed = (uint64_t)vm.compressor_page_count * page;
        s->mem_used       = ((uint64_t)vm.active_count +
                             (uint64_t)vm.inactive_count +
                             (uint64_t)vm.wire_count +
                             (uint64_t)vm.compressor_page_count) * page;
        if (s->mem_total && s->mem_used > s->mem_total)
            s->mem_used = s->mem_total;
    }

    struct xsw_usage xsu;
    memset(&xsu, 0, sizeof(xsu));
    sz = sizeof(xsu);
    if (sysctlbyname("vm.swapusage", &xsu, &sz, NULL, 0) == 0) {
        s->swap_used  = xsu.xsu_used;
        s->swap_total = xsu.xsu_total;
    }

    double loads[3] = { 0, 0, 0 };
    if (getloadavg(loads, 3) == 3) {
        s->load1  = loads[0];
        s->load5  = loads[1];
        s->load15 = loads[2];
    }
    (void)proc_count;
}

int cproc_collect(cproc_system_t *out)
{
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    out->timestamp_ns = cproc_now_ns();

    struct kinfo_proc *kp = NULL;
    int cnt = 0;
    if (get_all_kinfo(&kp, &cnt) != 0)
        return -1;

    cproc_snapshot_t *items = calloc((size_t)(cnt > 0 ? cnt : 1),
                                     sizeof(cproc_snapshot_t));
    if (!items) {
        free(kp);
        return -1;
    }

    int n = 0;
    for (int i = 0; i < cnt; i++) {
        struct kinfo_proc *k = &kp[i];
        pid_t pid = k->kp_proc.p_pid;
        if (pid < 0) continue;

        cproc_snapshot_t *it = &items[n];
        it->pid       = (int32_t)pid;
        it->ppid      = (int32_t)k->kp_eproc.e_ppid;
        it->uid       = (int32_t)k->kp_eproc.e_ucred.cr_uid;
        it->gid       = (int32_t)k->kp_eproc.e_ucred.cr_gid;
        it->status    = (uint32_t)k->kp_proc.p_stat;
        it->flags     = (uint32_t)k->kp_proc.p_flag;
        it->start_sec  = (uint64_t)k->kp_proc.p_starttime.tv_sec;
        it->start_usec = (uint64_t)k->kp_proc.p_starttime.tv_usec;
        cstr_copy(it->comm, sizeof(it->comm), k->kp_proc.p_comm);

        struct proc_taskinfo ti;
        memset(&ti, 0, sizeof(ti));
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                         &ti, PROC_PIDTASKINFO_SIZE) == PROC_PIDTASKINFO_SIZE) {
            it->rss         = ti.pti_resident_size;
            it->vss         = ti.pti_virtual_size;
            it->cpu_user_ns = ti.pti_total_user;
            it->cpu_sys_ns  = ti.pti_total_system;
            it->threads     = ti.pti_threadnum;
            it->faults      = ti.pti_faults;
            it->pageins     = ti.pti_pageins;
            it->cow_faults  = ti.pti_cow_faults;
            it->csw         = ti.pti_csw;
            it->msg_sent    = ti.pti_messages_sent;
            it->msg_recv    = ti.pti_messages_received;
            it->sys_mach    = ti.pti_syscalls_mach;
            it->sys_unix    = ti.pti_syscalls_unix;
            it->priority    = (int32_t)ti.pti_priority;
        }

        /* e_tdev 在 kinfo_proc 里也有，对 PID 0 / BSDINFO 被拒的进程照样可读 */
        it->tty_dev = (uint32_t)k->kp_eproc.e_tdev;

        struct proc_bsdinfo bi;
        memset(&bi, 0, sizeof(bi));
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
                         &bi, PROC_PIDTBSDINFO_SIZE) == PROC_PIDTBSDINFO_SIZE) {
            cstr_copy(it->name, sizeof(it->name), bi.pbi_name);
            it->nice     = (int32_t)bi.pbi_nice;
            it->nfiles   = bi.pbi_nfiles;
            it->pgid     = bi.pbi_pgid;
            it->flags    = bi.pbi_flags;      /* BSD flags 更完整 */
            /* TTY / 作业控制：e_tdev 是控制终端 dev_t，e_tpgid 是终端前台进程组 */
            if (tty_has_ctty((uint32_t)bi.e_tdev))
                it->tty_dev   = (uint32_t)bi.e_tdev;
            it->tty_tpgid = (uint32_t)bi.e_tpgid;
            it->tty_pgid  = (uint32_t)bi.pbi_pgid;
            it->tty_jobc  = (uint32_t)bi.pbi_pjobc;
            if (bi.pbi_start_tvsec) {
                it->start_sec  = bi.pbi_start_tvsec;
                it->start_usec = bi.pbi_start_tvusec;
            }
        }

        if (cproc_tty_devname(it->tty_dev, it->tty_name,
                              sizeof(it->tty_name)) != 0)
            cstr_copy(it->tty_name, sizeof(it->tty_name), "??");

        if (it->name[0] == '\0')
            cstr_copy(it->name, sizeof(it->name), it->comm);

        read_cmdline(pid, it->cmdline, sizeof(it->cmdline),
                     it->exepath, sizeof(it->exepath),
                     it->argv0, sizeof(it->argv0));

        out->threads_total += it->threads;
        n++;
    }

    free(kp);
    out->items = items;
    out->count = n;
    collect_system(out, n);

    /* 架构切片 + 运行时 Rosetta 判定。必须放在 collect_system 之后：
     * 判定需要 out->host_arm64，而它是在那里由 hw.optional.arm64 填充的。
     *
     * 「Apple Silicon 主机 + 二进制只有 x86 slice」是 Apple 文档明确的
     * 必然转译条件；反过来 universal / arm64-only 二进制即使系统选了
     * Rosetta 也不能仅凭公开接口断定，因此不猜测、不误报。 */
    const uint32_t arm_bits = CPROC_ARCH_ARM64 | CPROC_ARCH_ARM64E |
                              CPROC_ARCH_ARM64_32 | CPROC_ARCH_ARM;
    const uint32_t x86_bits = CPROC_ARCH_X86 | CPROC_ARCH_X86_64;
    for (int i = 0; i < n; i++) {
        cproc_snapshot_t *it = &items[i];
        uint32_t a = cproc_exec_archs(it->exepath);
        it->exec_archs = a;
        int has_arm = (a & arm_bits) != 0;
        int has_x86 = (a & x86_bits) != 0;
        it->translated = (out->host_arm64 && a != 0 && has_x86 && !has_arm)
                         ? 1u : 0u;
    }
    return 0;
}

void cproc_free(cproc_system_t *sys)
{
    if (!sys) return;
    free(sys->items);
    sys->items = NULL;
    sys->count = 0;
}
