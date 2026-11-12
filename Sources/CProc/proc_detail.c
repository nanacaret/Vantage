/* SPDX-License-Identifier: MIT */
#include "CProc.h"
#include "cproc_internal.h"
#include "cproc_l10n_data.h"  /* 生成的双语表：中文是 value，key 是语义标识 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>          /* kill() —— 之前漏掉，C99 下不允许隐式声明 */
#include <sys/syscall.h>     /* SYS_csops：不引入私有头文件也能拿到 CS flags */
#include <dlfcn.h>           /* dlsym：动态解析 task_name_for_pid，规避 SDK 声明差异 */
#include <fcntl.h>           /* open / O_NOCTTY：读取目标 tty 设备属性 */
#include <termios.h>         /* tcgetattr / cfgetispeed */
#include <sys/ioctl.h>       /* TIOCGWINSZ / TIOCGPGRP */

#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <libproc.h>

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/task_info.h>
#include <mach/vm_region.h>
#include <pthread.h>

/* ------------------------------------------------------------------ */
/* 详情采集的取消标记                                                  */
/* ------------------------------------------------------------------ */

/* 单个 region 枚举最多迭代这么多次。重 app（浏览器 / IDE / Electron）的
 * vm_map 可能有上万条映射，每条要 2 次系统调用（proc_pidinfo +
 * proc_regionfilename）；没有上限时一次采集就能卡住数秒。
 * 上限由偏好设置下发（g_cproc_limits.max_regions，默认 20000）。 */
#define CPROC_MAX_REGIONS()  ((int)g_cproc_limits.max_regions)

static pthread_mutex_t g_epoch_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_epoch_next = 1;
static uint64_t g_epoch_canceled[64];
static int      g_epoch_canceled_n = 0;
static __thread uint64_t t_epoch = 0;

uint64_t cproc_detail_begin_epoch(void)
{
    pthread_mutex_lock(&g_epoch_lock);
    uint64_t e = g_epoch_next++;
    pthread_mutex_unlock(&g_epoch_lock);
    return e;
}

void cproc_detail_mark_epoch(uint64_t epoch)
{
    t_epoch = epoch;
}

void cproc_detail_cancel_epoch(uint64_t epoch)
{
    if (!epoch) return;
    pthread_mutex_lock(&g_epoch_lock);
    for (int i = 0; i < g_epoch_canceled_n; i++) {
        if (g_epoch_canceled[i] == epoch) {
            pthread_mutex_unlock(&g_epoch_lock);
            return;
        }
    }
    if (g_epoch_canceled_n >= 64) {
        memmove(g_epoch_canceled, g_epoch_canceled + 1,
                sizeof(uint64_t) * 63);
        g_epoch_canceled_n = 63;
    }
    g_epoch_canceled[g_epoch_canceled_n++] = epoch;
    pthread_mutex_unlock(&g_epoch_lock);
}

int cproc_detail_aborted(void)
{
    uint64_t e = t_epoch;
    if (!e) return 0;
    pthread_mutex_lock(&g_epoch_lock);
    int found = 0;
    for (int i = 0; i < g_epoch_canceled_n; i++) {
        if (g_epoch_canceled[i] == e) { found = 1; break; }
    }
    pthread_mutex_unlock(&g_epoch_lock);
    return found;
}

/*
 * proc_bsdinfo.pbi_flags 的公开位定义，值来自 xnu bsd/sys/proc_info.h。
 * 与 proc_collect.c 保持同一套常量；SDK 已导出时 #ifndef 不生效。
 *
 * 注意不要再补一个 PROC_FLAG_TRANSLATED：Rosetta 相关的位在
 * #ifdef PRIVATE 的 proc_info_private.h 里，公开 SDK 不导出。曾经用
 * 0x00002000 兜底，而 0x2000 其实是 PROC_FLAG_PSUGID（setuid 提权），
 * 导致 sudo / login 等被误判成 Rosetta 转译进程。
 */
#ifndef PROC_FLAG_SYSTEM
#define PROC_FLAG_SYSTEM       0x00000001u
#endif
#ifndef PROC_FLAG_TRACED
#define PROC_FLAG_TRACED       0x00000002u
#endif
#ifndef PROC_FLAG_INEXIT
#define PROC_FLAG_INEXIT       0x00000004u
#endif
#ifndef PROC_FLAG_PPWAIT
#define PROC_FLAG_PPWAIT       0x00000008u
#endif
#ifndef PROC_FLAG_LP64
#define PROC_FLAG_LP64         0x00000010u
#endif
#ifndef PROC_FLAG_SLEADER
#define PROC_FLAG_SLEADER      0x00000020u
#endif
#ifndef PROC_FLAG_CTTY
#define PROC_FLAG_CTTY         0x00000040u
#endif
#ifndef PROC_FLAG_CONTROLT
#define PROC_FLAG_CONTROLT     0x00000080u
#endif
#ifndef PROC_FLAG_THCWD
#define PROC_FLAG_THCWD        0x00000100u
#endif
#ifndef PROC_FLAG_PSUGID
#define PROC_FLAG_PSUGID       0x00002000u
#endif
#ifndef PROC_FLAG_EXEC
#define PROC_FLAG_EXEC         0x00004000u
#endif

/* proc_pidfdinfo / proc_pidinfo 的 SIZE 宏在不同 SDK 里可能缺失；
 * 一律用宏而不是 sizeof(本地结构)，避免内核期望的 buffer 大小与 SDK 结构不一致
 * 导致 proc_pidfdinfo 直接返回 0（这是之前「网络连接」页全空的主因之一）。 */
#ifndef PROC_PIDFDSOCKETINFO_SIZE
#define PROC_PIDFDSOCKETINFO_SIZE ((int)sizeof(struct socket_fdinfo))
#endif
#ifndef PROC_PIDFDPIPEINFO_SIZE
#define PROC_PIDFDPIPEINFO_SIZE   ((int)sizeof(struct pipe_fdinfo))
#endif
#ifndef PROC_PIDFDKQUEUEINFO_SIZE
#define PROC_PIDFDKQUEUEINFO_SIZE ((int)sizeof(struct kqueue_fdinfo))
#endif
#ifndef PROC_PIDFDVNODEPATHINFO_SIZE
#define PROC_PIDFDVNODEPATHINFO_SIZE ((int)sizeof(struct vnode_fdinfowithpath))
#endif
#ifndef PROC_PIDREGIONINFO_SIZE
#define PROC_PIDREGIONINFO_SIZE  ((int)sizeof(struct proc_regioninfo))
#endif
#ifndef PROC_PIDREGIONPATHINFO_SIZE
#define PROC_PIDREGIONPATHINFO_SIZE ((int)sizeof(struct proc_regionwithpathinfo))
#endif

/* socket_info.soi_kind —— 决定 soi_proto union 里哪个成员有效。
 * 不同 SDK 导出名略有差异，用数值兜底最稳。 */
#define CPROC_SOCKINFO_GENERIC     0
#define CPROC_SOCKINFO_IN          1
#define CPROC_SOCKINFO_TCP         2
#define CPROC_SOCKINFO_UN          3
#define CPROC_SOCKINFO_NDRV        4
#define CPROC_SOCKINFO_KERN_EVENT  5
#define CPROC_SOCKINFO_KERN_CTL    6

/* xnu bsd/sys/codesign.h 的真实 CS_OPS 编号。
 * CS_OPS_AUDITTOKEN=1 / CS_OPS_PID=2 这类常见写法是错的，
 * 以下为真实定义，且 CS_OPS_STATUS / CS_OPS_TEAMID 都是稳定公开值。 */
#define CPROC_CS_OPS_STATUS        0   /* 返回 csflags (uint32) */
#define CPROC_CS_OPS_CDHASH        5
#define CPROC_CS_OPS_ENTITLEMENTS_BLOB 7
#define CPROC_CS_OPS_BLOB         10
#define CPROC_CS_OPS_IDENTITY     11
#define CPROC_CS_OPS_TEAMID       14
#define CPROC_CS_OPS_DER_ENTITLEMENTS_BLOB 16

#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif
#ifndef PROC_TTY_ONLY
#define PROC_TTY_ONLY 3
#endif
#ifndef TOSTOP
#define TOSTOP 0x00400000u
#endif

/* ------------------------------------------------------------------ */
/* 行容器：每行用 '\t' 分隔字段，Swift 侧按列渲染                       */
/* ------------------------------------------------------------------ */

typedef struct {
    char **v;
    int    n;
    int    cap;
} line_builder_t;

static int lb_init(line_builder_t *b)
{
    b->cap = 64;
    b->n = 0;
    b->v = calloc((size_t)b->cap, sizeof(char *));
    return b->v ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* 双语输出：C 层中文是 *value*（模板），不是 key。
 *
 * 每个含中文的字段输出成：
 *     \x1eL:<semantic.key>\x1f<中文>\x1f<English>
 * \x1e / \x1f 是控制字符，不会出现在真实数据里。Swift 侧只按当前语言
 * 取其中一份，不做任何中文文本猜测：按短语替换会留下中英混杂的
 * 长句，这里从根上消除。
 * ------------------------------------------------------------------ */
#define CPROC_L10N_MARK "\x1eL:"
#define CPROC_L10N_SEP  "\x1f"

static void lb_add_raw(line_builder_t *b, const char *s)
{
    if (!s) s = "";
    if (b->n >= b->cap) {
        int nc = b->cap * 2;
        char **nv = realloc(b->v, (size_t)nc * sizeof(char *));
        if (!nv) return;
        b->v = nv;
        b->cap = nc;
    }
    b->v[b->n++] = strdup(s);
}

static void lb_add_bilingual(line_builder_t *b, const char *zh, const char *en)
{
    if (!en) en = zh;
    size_t cap = strlen(zh) * 3 + strlen(en) * 3 + 512;
    char *out = malloc(cap);
    if (!out) { lb_add_raw(b, zh); return; }
    size_t o = 0;
    const char *z = zh, *e = en;
    for (;;) {
        const char *zt = strchr(z, '\t');
        const char *et = strchr(e, '\t');
        size_t zl = zt ? (size_t)(zt - z) : strlen(z);
        size_t el = et ? (size_t)(et - e) : strlen(e);
        char zf[8192], ef[8192];
        if (zl >= sizeof(zf)) zl = sizeof(zf) - 1;
        if (el >= sizeof(ef)) el = sizeof(ef) - 1;
        memcpy(zf, z, zl); zf[zl] = '\0';
        memcpy(ef, e, el); ef[el] = '\0';

        /* 字段级精确译文优先：避免短词内联替换把长句切成
           "No控制终端…" 这类中英混杂。整字段命中时用整句译文；
           未命中（带变量的字段）才用 en_fmt 生成的英文，再兜底短词替换。 */
        const char *alt = cproc_l10n_en_field(zf);
        if (alt) {
            snprintf(ef, sizeof(ef), "%s", alt);
        } else {
            cproc_l10n_inline_en(ef, sizeof(ef));
        }
        if (o >= cap) break;
        if (strcmp(zf, ef) != 0) {
            const char *key = cproc_l10n_key_field(zf);
            int n = snprintf(out + o, cap - o, "%s%s%s%s%s%s\x1e",
                             CPROC_L10N_MARK, key ? key : "",
                             CPROC_L10N_SEP, zf, CPROC_L10N_SEP, ef);
            if (n < 0) break;
            o += (size_t)n;
        } else {
            int n = snprintf(out + o, cap - o, "%s", zf);
            if (n < 0) break;
            o += (size_t)n;
        }
        if (!zt) break;
        if (o < cap) out[o++] = '\t';
        z = zt + 1;
        e = et ? et + 1 : e + el;
    }
    out[o < cap ? o : cap - 1] = '\0';
    lb_add_raw(b, out);
    free(out);
}

static void lb_add(line_builder_t *b, const char *s)
{
    if (!s) s = "";
    const char *ef = cproc_l10n_en_fmt(s);
    lb_add_bilingual(b, s, ef ? ef : s);
}

static void lb_addf(line_builder_t *b, const char *fmt, ...)
{
    char zh[8192], en[8192];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(zh, sizeof(zh), fmt, ap);
    va_end(ap);

    const char *ef = cproc_l10n_en_fmt(fmt);
    if (ef) {
        va_start(ap, fmt);
        vsnprintf(en, sizeof(en), ef, ap);
        va_end(ap);
    } else {
        snprintf(en, sizeof(en), "%s", zh);
    }
    lb_add_bilingual(b, zh, en);
}

static int lb_finish(line_builder_t *b, cproc_lines_t *out)
{
    out->lines = b->v;
    out->count = b->n;
    b->v = NULL;
    b->n = b->cap = 0;
    return 0;
}

const char *cproc_line(const cproc_lines_t *lines, int32_t index)
{
    if (!lines || !lines->lines || index < 0 || index >= lines->count)
        return "";
    return lines->lines[index] ? lines->lines[index] : "";
}

void cproc_lines_free(cproc_lines_t *lines)
{
    if (!lines) return;
    if (lines->lines) {
        for (int32_t i = 0; i < lines->count; i++)
            free(lines->lines[i]);
        free(lines->lines);
    }
    lines->lines = NULL;
    lines->count = 0;
}

/* 提示行的第一列用稳定 ASCII 标记：Swift 侧据此按偏好过滤 / 翻译，
 * 不受界面语言影响（中文「提示」本地化后变成 Hint，无法当结构标记用）。 */
#define CPROC_HINT_TAG "__hint__"

static void lb_hint(line_builder_t *b, const char *msg)
{
    lb_addf(b, CPROC_HINT_TAG "\t%s", msg);
}

/* ------------------------------------------------------------------ */
/* 通用：FD 列表                                                       */
/* ------------------------------------------------------------------ */

/* proc_pidinfo(PROC_PIDLISTFDS) 的返回值是**写入的字节数**，不是 fd 个数。
 * 第一次传 NULL/0 拿到的是所需 buffer 字节数，直接用它分配即可。
 *
 * 若把字节数再乘 sizeof(proc_fdinfo) 来分配（多 8 倍），又把第二次调用的
 * 返回值 r（仍是字节数）直接当 fd 个数返回，buffer 后 7/8 就会是 malloc
 * 未初始化的堆内存，被当成有效 FD 逐条显示：0x7D0222A0 这类巨大数字正是
 * 堆地址低 32 位，fdtype 是垃圾值 → 全部落进 OTHER。 */
static struct proc_fdinfo *read_fds(int32_t pid, int *out_cnt)
{
    *out_cnt = 0;
    int needed = proc_pidinfo((int)pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (needed <= 0) return NULL;

    /* 留 32 项余量：两次调用之间进程可能又打开了新的 fd */
    size_t bytes = (size_t)needed + sizeof(struct proc_fdinfo) * 32;
    if (bytes > (size_t)g_cproc_limits.fd_max_bytes) return NULL;

    /* calloc 而非 malloc：尾部清零，配合下面的净化做双保险 */
    struct proc_fdinfo *fds = calloc(1, bytes);
    if (!fds) return NULL;

    int r = proc_pidinfo((int)pid, PROC_PIDLISTFDS, 0, fds, (int)bytes);
    if (r <= 0) { free(fds); return NULL; }

    int n = r / (int)sizeof(struct proc_fdinfo);

    /* 净化：正常 fd 号远小于 1<<20，fdtype 从 1 开始且目前最多十几种。
     * 过滤掉尾部残留与内核异常数据，避免再把堆地址显示成 FD。 */
    int w = 0;
    for (int i = 0; i < n; i++) {
        int32_t fd = fds[i].proc_fd;
        uint32_t t = fds[i].proc_fdtype;
        if (fd < 0 || fd > (1 << 20)) continue;
        if (t == 0 || t > 64) continue;
        if (w != i) fds[w] = fds[i];
        w++;
    }
    *out_cnt = w;
    return fds;
}

/* xnu bsd/sys/proc_info.h 的 proc_fdtype 编号（长期稳定）：
 *   1 ATALK  2 VNODE  3 SOCKET  4 PSHM  5 PSEM  6 KQUEUE  7 PIPE
 *   8 FSEVENTS  9 NETPOLICY  10 CHANNEL  11 NEXUS
 * SDK 导出了宏就用宏，没导出的按编号兜底，最后带数值输出未知类型。 */
static const char *fd_type_name(uint32_t t)
{
    switch (t) {
    case PROX_FDTYPE_VNODE:   return "VNODE";
    case PROX_FDTYPE_SOCKET:  return "SOCKET";
    case PROX_FDTYPE_PSHM:    return "PSHM";
    case PROX_FDTYPE_PSEM:    return "PSEM";
    case PROX_FDTYPE_KQUEUE:  return "KQUEUE";
    case PROX_FDTYPE_PIPE:    return "PIPE";
#ifdef PROX_FDTYPE_ATALK
    case PROX_FDTYPE_ATALK:   return "ATALK";
#endif
#ifdef PROX_FDTYPE_FSEVENTS
    case PROX_FDTYPE_FSEVENTS:  return "FSEVENTS";
#endif
#ifdef PROX_FDTYPE_NETPOLICY
    case PROX_FDTYPE_NETPOLICY: return "NETPOLICY";
#endif
#ifdef PROX_FDTYPE_CHANNEL
    case PROX_FDTYPE_CHANNEL:   return "CHANNEL";
#endif
#ifdef PROX_FDTYPE_NEXUS
    case PROX_FDTYPE_NEXUS:     return "NEXUS";
#endif
    default: break;
    }
    switch (t) {
    case 1:  return "ATALK";
    case 8:  return "FSEVENTS";
    case 9:  return "NETPOLICY";
    case 10: return "CHANNEL";
    case 11: return "NEXUS";
    default: break;
    }
    /* 内核新增了类型时带上编号，别再笼统显示成 OTHER 让人无从判断 */
    static __thread char unknown[32];
    snprintf(unknown, sizeof(unknown), "UNKNOWN(%u)", t);
    return unknown;
}

/* 非 vnode FD 到底代表什么内核对象，直接在列表里说清楚。
 * 之前一律写「非 vnode 描述符，详见文件监控页」，用户看到几十行
 * 一模一样的占位文字，无法判断是解析错了还是真有大量特殊 fd。 */
static const char *fd_type_desc(uint32_t t)
{
    switch (t) {
    case 1:  return "(AppleTalk 套接字，无 vnode 路径)";
    case 2:  return "(vnode 文件，见上方 VNODE 行)";   /* 防御：正常不会走到 */
    case 3:  return "(socket，协议/地址见「网络连接」页)";
    case 4:  return "(POSIX 共享内存对象，无文件路径)";
    case 5:  return "(POSIX 信号量，无文件路径)";
    case 6:  return "(kqueue，事件监听状态见「文件监控」页)";
    case 7:  return "(管道，对端进程见「文件监控」页)";
    case 8:  return "(FSEvents 文件系统事件监听 fd，无 vnode 路径)";
    case 9:  return "(网络策略 netpolicy fd，无 vnode 路径)";
    case 10: return "(channel 描述符，无 vnode 路径)";
    case 11: return "(Skywalk nexus 描述符，无 vnode 路径)";
    default: return "(内核新增 FD 类型，无 vnode 路径)";
    }
}

/* ================================================================== */
/* 无 task port 采集层                                                 */
/*                                                                    */
/* SIP 开启时 task_for_pid() 对受保护进程必然失败（与 root 无关）：      */
/*   - Apple《Runtime Protections》明确 task_for_pid / processor_set_tasks */
/*     对受保护进程返回 EPERM；                                           */
/*   - com.apple.security.cs.debugger 只对带 get-task-allow 的第三方进程  */
/*     有效；                                                             */
/*   - com.apple.system-task-ports 仅授予 Apple 自身。                    */
/* 因此镜像/内存映射改用 libproc 的 proc_pidinfo(PROC_PIDREGIONINFO)     */
/* 枚举（vmmap 本身就是这么做的，dtruss 证实它不调 Mach API），           */
/* Audit Token 改用 task_name_for_pid + task_info，                       */
/* CS flags 改用 csops 系统调用。                                         */
/* ================================================================== */

/* ---------- 内存映射 region 枚举（完全不需要 task port） ---------- */

typedef void (*region_visitor_t)(void *ctx, uint64_t start, uint64_t size,
                                 uint32_t prot, uint32_t maxprot,
                                 const char *path);

/*
 * 用 PROC_PIDREGIONINFO 逐个 region 迭代：
 *   传入 address → 内核返回包含该地址的 region（pri_address / pri_size）
 *   → 下一个 address = pri_address + pri_size
 * 再用 proc_regionfilename() 取该 region 的映射文件路径。
 * 这两个都是 libproc 公共 API，内部走 proc_info 系统调用，在内核态读 vm_map，
 * 用户态不需要持有目标进程的 Mach task port。
 */
static int enumerate_regions(int32_t pid, region_visitor_t visit, void *ctx)
{
    size_t bufsz = (size_t)PROC_PIDREGIONINFO_SIZE;
    if (bufsz < sizeof(struct proc_regioninfo))
        bufsz = sizeof(struct proc_regioninfo);

    void *buf = calloc(1, bufsz);
    if (!buf) return -1;

    char path[MAXPATHLEN];
    uint64_t addr = 0;
    int n = 0;

    const int max_regions = CPROC_MAX_REGIONS();
    for (int iter = 0; iter < max_regions; iter++) {
        /* 每 32 个 region 检查一次取消。加锁开销相对 2 次系统调用可忽略，
         * 但能让「快速点选另一个进程」时立刻从万次循环里退出。 */
        if ((iter & 31) == 0 && cproc_detail_aborted()) break;
        memset(buf, 0, bufsz);
        int ret = proc_pidinfo((int)pid, PROC_PIDREGIONINFO,
                               (uint64_t)addr, buf, (int)bufsz);
        if (ret <= 0) break;

        struct proc_regioninfo ri;
        memset(&ri, 0, sizeof(ri));
        size_t copy = ((size_t)ret < sizeof(ri)) ? (size_t)ret : sizeof(ri);
        memcpy(&ri, buf, copy);

        uint64_t start = ri.pri_address;
        uint64_t size  = ri.pri_size;
        path[0] = '\0';
        proc_regionfilename((int)pid, start, path, sizeof(path));

        visit(ctx, start, size,
              (uint32_t)ri.pri_protection,
              (uint32_t)ri.pri_max_protection,
              path);
        n++;

        uint64_t next = start + size;
        if (next <= addr) break;       /* 尺寸为 0 / 溢出，防止死循环 */
        addr = next;
    }

    free(buf);
    return n;
}

static const char *prot_string(uint32_t p, char *buf, size_t cap)
{
    snprintf(buf, cap, "%c%c%c",
             (p & VM_PROT_READ)    ? 'r' : '-',
             (p & VM_PROT_WRITE)   ? 'w' : '-',
             (p & VM_PROT_EXECUTE) ? 'x' : '-');
    return buf;
}

typedef struct {
    line_builder_t *b;
    char **seen;
    int seen_n;
    int seen_cap;
} image_ctx_t;

static int seen_contains(char **seen, int n, const char *p)
{
    for (int i = 0; i < n; i++)
        if (seen[i] && strcmp(seen[i], p) == 0) return 1;
    return 0;
}

static void image_visitor(void *ctx, uint64_t start, uint64_t size,
                          uint32_t prot, uint32_t maxprot, const char *path)
{
    (void)size; (void)prot; (void)maxprot;
    image_ctx_t *ic = (image_ctx_t *)ctx;
    if (!path || path[0] == '\0') return;

    /* 只要 Mach-O 镜像 / 动态库 / framework / 共享缓存 / 主可执行文件 */
    int is_image =
        strstr(path, ".dylib")        || strstr(path, ".framework/") ||
        strstr(path, ".framework)")   || strstr(path, ".bundle")      ||
        strstr(path, "/usr/lib/")     || strstr(path, "/System/Library/") ||
        strstr(path, "/Library/")     || strstr(path, "dyld_shared_cache") ||
        strstr(path, ".app/Contents/MacOS/");
    if (!is_image) return;
    if (seen_contains(ic->seen, ic->seen_n, path)) return;

    if (ic->seen_n >= ic->seen_cap) {
        int nc = ic->seen_cap ? ic->seen_cap * 2 : 128;
        char **nv = realloc(ic->seen, (size_t)nc * sizeof(char *));
        if (!nv) return;
        ic->seen = nv;
        ic->seen_cap = nc;
    }
    ic->seen[ic->seen_n++] = strdup(path);
    lb_addf(ic->b, "0x%llx\t-\t%s",
            (unsigned long long)start, path);
}

/* 主路径不可用时的镜像列表：region 枚举 + 路径名，无 task port */
static void dylibs_via_regions_noport(int32_t pid, line_builder_t *b)
{
    image_ctx_t ic;
    memset(&ic, 0, sizeof(ic));
    ic.b = b;
    enumerate_regions(pid, image_visitor, &ic);
    for (int i = 0; i < ic.seen_n; i++) free(ic.seen[i]);
    free(ic.seen);
}

typedef struct {
    line_builder_t *b;
    int n;
} region_ctx_t;

static void region_visitor(void *ctx, uint64_t start, uint64_t size,
                           uint32_t prot, uint32_t maxprot, const char *path)
{
    region_ctx_t *rc = (region_ctx_t *)ctx;
    char p1[8], p2[8];
    rc->n++;
    lb_addf(rc->b, "0x%llx\t0x%llx\t%llu\t%s / %s\t%s",
            (unsigned long long)start,
            (unsigned long long)(start + size),
            (unsigned long long)size,
            prot_string(prot, p1, sizeof(p1)),
            prot_string(maxprot, p2, sizeof(p2)),
            path[0] ? path : "(匿名映射)");
}

int cproc_regions(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    lb_add(&b, "起始地址\t结束地址\t大小 (bytes)\t保护 / 最大保护\t映射文件");
    region_ctx_t rc = { &b, 0 };
    int n = enumerate_regions(pid, region_visitor, &rc);

    if (n <= 0) {
        lb_addf(&b, "错误\t-\t-\t-\tproc_pidinfo(PROC_PIDREGIONINFO) 失败（%s）",
                strerror(errno));
        lb_hint(&b, "该进程可能已退出；内存映射枚举不需要 task port，SIP 开启时仍可用");
    } else {
        lb_addf(&b, "合计\t-\t-\t-\t共 %d 个内存映射 region（来源：libproc PROC_PIDREGIONINFO）",
                n);
        lb_hint(&b, "此页完全不依赖 Mach task port，SIP 开启时对系统进程同样有效");
        if (n >= CPROC_MAX_REGIONS())
            lb_addf(&b, CPROC_HINT_TAG "\t-\t-\t-\tregion 数达到上限 %d，结果已截断（可在偏好设置「采集上限」中调整）",
                    CPROC_MAX_REGIONS());
    }
    return lb_finish(&b, out);
}

/* ---------- 全局 pipe 索引：解析管道对端进程 ---------- */

/*
 * xnu bsd/kern/sys_pipe.c 的 fill_pipeinfo()：
 *   pipe_handle      = 本端 struct pipe 的内核地址（VM_KERNEL_ADDRPERM 混淆）
 *   pipe_peerhandle  = 对端 struct pipe 的内核地址
 * 混淆是内核全局的，所以「目标进程的 pipe_peerhandle」一定等于
 * 「对端进程某个 pipe FD 的 pipe_handle」。遍历全部进程的 PIPE FD 建索引即可
 * 反查对端 PID / 进程名 / FD —— 全程只用 libproc，不需要 task port。
 */
typedef struct {
    uint64_t handle;
    uint64_t peer;
    int32_t  pid;
    int32_t  fd;
    char     comm[CPROC_COMM_MAX];
} pipe_entry_t;

typedef struct {
    pipe_entry_t *v;
    int    n, cap;
    int    scanned_pids;
    uint64_t built_ns;
} pipe_index_t;

static pipe_index_t g_pipe_index = { NULL, 0, 0, 0, 0 };

static void pipe_index_add(pipe_index_t *ix, uint64_t handle, uint64_t peer,
                           int32_t pid, int32_t fd, const char *comm)
{
    if (!handle) return;
    if (ix->n >= ix->cap) {
        int nc = ix->cap ? ix->cap * 2 : 256;
        pipe_entry_t *nv = realloc(ix->v, (size_t)nc * sizeof(pipe_entry_t));
        if (!nv) return;
        ix->v = nv;
        ix->cap = nc;
    }
    pipe_entry_t *e = &ix->v[ix->n++];
    memset(e, 0, sizeof(*e));
    e->handle = handle;
    e->peer   = peer;
    e->pid    = pid;
    e->fd     = fd;
    if (comm) {
        size_t k = strnlen(comm, sizeof(e->comm) - 1);
        memcpy(e->comm, comm, k);
        e->comm[k] = '\0';
    }
}

static int pipe_index_build(pipe_index_t *ix)
{
    uint64_t now = cproc_now_ns();
    /* 缓存时长由偏好设置下发（默认 2 秒）：详情刷新不会每次都遍历全系统 FD。
     * 条件只看时间、不看 n：若要求 ix->v && ix->n > 0，「系统里恰好没有 pipe」
     * 或「扫描被取消」时 built_ns 已写但 n=0，每次调用都会重新全系统扫描一遍
     * ——这在无 pipe 的机器上是最重的一段空转。 */
    uint64_t cache_ns = (uint64_t)g_cproc_limits.pipe_cache_ms * 1000000ULL;
    if (ix->built_ns && now > ix->built_ns &&
        now - ix->built_ns < cache_ns)
        return ix->n > 0 ? 0 : -1;

    free(ix->v);
    memset(ix, 0, sizeof(*ix));
    /* 先记时间戳：即使下面失败 / 被取消，2 秒内也不会反复全系统扫描。
     * 取消路径会把它清零，避免把不完整的索引当缓存用。 */
    ix->built_ns = now;

    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    int *pids = calloc((size_t)bytes / sizeof(int) + 16, sizeof(int));
    if (!pids) return -1;

    int got = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes);
    int npids = got > 0 ? got / (int)sizeof(int) : 0;

    /* buffer 按 SIZE 宏分配，避免宏比 SDK 结构大时栈/堆越界 */
    size_t pbufsz = (size_t)PROC_PIDFDPIPEINFO_SIZE;
    if (pbufsz < sizeof(struct pipe_fdinfo))
        pbufsz = sizeof(struct pipe_fdinfo);
    void *pbuf = calloc(1, pbufsz);
    if (!pbuf) { free(pids); return -1; }

    for (int i = 0; i < npids; i++) {
        if ((i & 15) == 0 && cproc_detail_aborted()) {
            /* 被取消时丢弃不完整索引，并让缓存立即失效 */
            ix->built_ns = 0;
            free(ix->v);
            ix->v = NULL;
            ix->n = 0;
            ix->cap = 0;
            free(pbuf);
            free(pids);
            return -1;
        }
        int32_t p = (int32_t)pids[i];
        if (p <= 0) continue;

        int cnt = 0;
        struct proc_fdinfo *fds = read_fds(p, &cnt);
        if (!fds) continue;
        ix->scanned_pids++;

        char comm[CPROC_COMM_MAX] = { 0 };
        proc_name((int)p, comm, sizeof(comm));

        for (int j = 0; j < cnt; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_PIPE) continue;
            memset(pbuf, 0, pbufsz);
            int ret = proc_pidfdinfo((int)p, fds[j].proc_fd,
                                     PROC_PIDFDPIPEINFO, pbuf, (int)pbufsz);
            if (ret <= 0) continue;

            struct pipe_fdinfo pdi;
            memset(&pdi, 0, sizeof(pdi));
            size_t copy = ((size_t)ret < sizeof(pdi)) ? (size_t)ret : sizeof(pdi);
            memcpy(&pdi, pbuf, copy);

            pipe_index_add(ix, pdi.pipeinfo.pipe_handle,
                           pdi.pipeinfo.pipe_peerhandle,
                           p, fds[j].proc_fd, comm);
        }
        free(fds);
    }

    free(pbuf);
    free(pids);
    ix->built_ns = now;
    return ix->n > 0 ? 0 : -1;
}

static const pipe_entry_t *pipe_index_find(const pipe_index_t *ix,
                                           uint64_t handle)
{
    if (!handle) return NULL;
    for (int i = 0; i < ix->n; i++)
        if (ix->v[i].handle == handle) return &ix->v[i];
    return NULL;
}

/* 读取目标进程某个 pipe FD 的句柄信息 */
static int read_pipe_fdinfo(int32_t pid, int32_t fd, void *buf, size_t bufsz,
                            struct pipe_fdinfo *out)
{
    memset(buf, 0, bufsz);
    int ret = proc_pidfdinfo((int)pid, (int)fd, PROC_PIDFDPIPEINFO,
                             buf, (int)bufsz);
    if (ret <= 0) return -1;
    memset(out, 0, sizeof(*out));
    size_t copy = ((size_t)ret < sizeof(*out)) ? (size_t)ret : sizeof(*out);
    memcpy(out, buf, copy);
    return 0;
}

int cproc_pipe_peers(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    lb_add(&b, "FD\t本端句柄\t对端句柄\t对端 PID\t对端进程\t对端 FD\t状态");

    int built = pipe_index_build(&g_pipe_index);

    int cnt = 0;
    struct proc_fdinfo *fds = read_fds(pid, &cnt);
    if (!fds) {
        lb_addf(&b, "错误\t-\t-\t-\t-\t-\t无法读取 FD 列表（%s）",
                strerror(errno));
        return lb_finish(&b, out);
    }

    size_t pbufsz = (size_t)PROC_PIDFDPIPEINFO_SIZE;
    if (pbufsz < sizeof(struct pipe_fdinfo))
        pbufsz = sizeof(struct pipe_fdinfo);
    void *pbuf = calloc(1, pbufsz);

    int pipes = 0, resolved = 0, self_loop = 0;
    for (int i = 0; i < cnt; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_PIPE) continue;
        pipes++;
        struct pipe_fdinfo pdi;
        if (!pbuf || read_pipe_fdinfo(pid, fds[i].proc_fd, pbuf, pbufsz, &pdi) != 0) {
            lb_addf(&b, "%d\t-\t-\t-\t-\t-\t读取 PIPEINFO 失败",
                    fds[i].proc_fd);
            continue;
        }
        uint64_t h = pdi.pipeinfo.pipe_handle;
        uint64_t ph = pdi.pipeinfo.pipe_peerhandle;
        const pipe_entry_t *e = pipe_index_find(&g_pipe_index, ph);
        if (e) {
            resolved++;
            if (e->pid == pid) {
                self_loop++;
                lb_addf(&b, "%d\t0x%llx\t0x%llx\t%d\t%s\t%d\t同一进程（fork 共享 / 自环）",
                        fds[i].proc_fd,
                        (unsigned long long)h, (unsigned long long)ph,
                        (int)e->pid, e->comm, (int)e->fd);
            } else {
                lb_addf(&b, "%d\t0x%llx\t0x%llx\t%d\t%s\t%d\t已连接",
                        fds[i].proc_fd,
                        (unsigned long long)h, (unsigned long long)ph,
                        (int)e->pid, e->comm, (int)e->fd);
            }
        } else {
            lb_addf(&b, "%d\t0x%llx\t0x%llx\t-\t-\t-\t对端已关闭 / 内核持有 / 无权限枚举",
                    fds[i].proc_fd,
                    (unsigned long long)h, (unsigned long long)ph);
        }
    }

    free(pbuf);
    free(fds);

    lb_addf(&b, "合计\t-\t-\t-\t-\t-\tpipe=%d 已解析=%d 自环=%d",
            pipes, resolved, self_loop);
    if (built != 0) {
        lb_hint(&b, "全局 pipe 索引为空：部分进程的 PROC_PIDFDPIPEINFO 可能被系统拒绝");
    } else {
        lb_addf(&b, "索引\t-\t-\t-\t-\t-\t扫描 %d 个进程 / %d 个 pipe 端点",
                g_pipe_index.scanned_pids, g_pipe_index.n);
    }
    lb_hint(&b, "原理：pipe_peerhandle 是对端 struct pipe 的内核地址，与对端进程的 pipe_handle 相同");
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 1. 已打开文件                                                       */
/* ------------------------------------------------------------------ */

int cproc_open_files(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    int cnt = 0;
    struct proc_fdinfo *fds = read_fds(pid, &cnt);
    if (!fds) {
        lb_addf(&b, "错误\t无法读取 FD 列表（%s）", strerror(errno));
        lb_hint(&b, "进程可能已退出，或属于其他用户 / 受 SIP 保护");
        return lb_finish(&b, out);
    }

    int vnode_cnt = 0, vnode_fail = 0, other_cnt = 0;
    lb_addf(&b, "FD\t类型\t打开标志\t路径");
    for (int i = 0; i < cnt; i++) {
        if ((i & 31) == 0 && cproc_detail_aborted()) break;
        struct proc_fdinfo *fdi = &fds[i];
        if (fdi->proc_fdtype == PROX_FDTYPE_VNODE) {
            struct vnode_fdinfowithpath vpath;
            memset(&vpath, 0, sizeof(vpath));
            int ret = proc_pidfdinfo((int)pid, fdi->proc_fd,
                                     PROC_PIDFDVNODEPATHINFO,
                                     &vpath, (int)sizeof(vpath));
            if (ret > 0) {
                lb_addf(&b, "%d\tVNODE\t0x%x\t%s",
                        fdi->proc_fd, vpath.pfi.fi_openflags,
                        vpath.pvip.vip_path[0] ? vpath.pvip.vip_path : "(未知路径)");
            } else {
                /* 之前失败时整行被吞掉，合计里的 FD 总数与列出行数对不上 */
                lb_addf(&b, "%d\tVNODE\t-\t(路径读取失败：%s)",
                        fdi->proc_fd, strerror(errno));
                vnode_fail++;
            }
            vnode_cnt++;
        } else {
            other_cnt++;
            lb_addf(&b, "%d\t%s\t-\t%s",
                    fdi->proc_fd,
                    fd_type_name(fdi->proc_fdtype),
                    fd_type_desc(fdi->proc_fdtype));
        }
    }
    free(fds);

    if (vnode_cnt == 0)
        lb_addf(&b, "结果\t-\t-\t(没有 vnode 类型的已打开文件)");
    lb_addf(&b, "合计\t-\t-\tvnode=%d（路径失败 %d）, 其他=%d, FD 总数=%d",
            vnode_cnt, vnode_fail, other_cnt, cnt);
    lb_addf(&b, CPROC_HINT_TAG "\t-\t-\t类型列是内核 proc_fdtype：VNODE=磁盘文件，SOCKET=套接字，"
            "PIPE=管道，KQUEUE=事件队列，PSHM/PSEM=POSIX 共享内存/信号量，"
            "FSEVENTS=文件事件监听，NETPOLICY/CHANNEL/NEXUS=网络与 Skywalk 描述符；"
            "这些对象没有 vnode 路径，属正常");
    lb_addf(&b, CPROC_HINT_TAG "\t-\t-\tUNKNOWN(n) 表示内核出现了本版本尚未收录的 FD 类型；"
            "若同时出现上亿的 FD 号，则是 FD 列表解析异常，请对照「文件监控」页的合计数字");
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 2. 环境变量                                                         */
/* ------------------------------------------------------------------ */

/*
 * mib 必须是 {CTL_KERN, KERN_PROCARGS, pid}：
 *   {CTL_KERN, KERN_PROC, pid} 查的是 KERN_PROC 下以 pid 为第三个参数的
 *   子项，取不到 argv+envp 缓冲区。
 */
int cproc_env_vars(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    int mib[3] = { CTL_KERN, KERN_PROCARGS, (int)pid };
    size_t need = 0;
    if (sysctl(mib, 3, NULL, &need, NULL, 0) == -1) {
        lb_addf(&b, "错误\tsysctl(KERN_PROCARGS) 失败（%s）", strerror(errno));
        return lb_finish(&b, out);
    }
    if (need == 0 || need > 4 * 1024 * 1024) {
        lb_addf(&b, "错误\t数据异常（%zu bytes）", need);
        return lb_finish(&b, out);
    }

    /* 多分配 2 字节并清零，保证末尾一定有双 NUL 哨兵 */
    char *buf = calloc(need + 2, 1);
    if (!buf) {
        lb_add(&b, "错误\t内存不足");
        return lb_finish(&b, out);
    }
    size_t got = need;
    if (sysctl(mib, 3, buf, &got, NULL, 0) == -1) {
        lb_addf(&b, "错误\t读取失败（%s）", strerror(errno));
        free(buf);
        return lb_finish(&b, out);
    }
    char *end = buf + got;
    char *p = buf + sizeof(int);

    /* 用 argc 精确定位 envp：KERN_PROCARGS 的布局是
     *   [int argc][exe\0][argv0\0..argvN\0][\0][env0\0..envM\0][\0]
     * 靠「找双 NUL」跳 argv 会在布局有差异时整段错位。 */
    int argc = 0;
    memcpy(&argc, buf, sizeof(int));
    if (argc < 0 || argc > 4096) argc = 0;

    /* exe path */
    while (p < end && *p) p++;
    if (p < end) p++;
    /* 对齐 / 分隔用的多余 NUL */
    while (p < end && *p == '\0') p++;
    /* 精确跳过 argc 个 argv 串 */
    for (int i = 0; i < argc && p < end; i++) {
        while (p < end && *p) p++;
        if (p < end) p++;
    }
    /* 跳过 argv 与 envp 之间的分隔 NUL */
    while (p < end && *p == '\0') p++;

    lb_add(&b, "变量\t值");
    int env_count = 0;
    while (p < end && *p) {
        char *e = p;
        while (e < end && *e) e++;
        char *eq = NULL;
        for (char *q = p; q < e; q++) {
            if (*q == '=') { eq = q; break; }
        }
        if (eq) {
            lb_addf(&b, "%.*s\t%.*s",
                    (int)(eq - p), p, (int)(e - eq - 1), eq + 1);
        } else {
            lb_addf(&b, "%.*s\t(空值)", (int)(e - p), p);
        }
        env_count++;
        p = e;
        if (p < end) p++;
    }
    if (env_count == 0)
        lb_addf(&b, "结果\t(无环境变量，可能是内核任务或守护进程)");
    lb_addf(&b, "合计\t共 %d 个环境变量", env_count);
    free(buf);
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 3. 已加载镜像（dylib / framework）                                  */
/* ------------------------------------------------------------------ */

struct dyld_image_info_local {
    uint64_t loadAddress;
    uint64_t imagePath;
    uint64_t imageModDate;
};

static mach_port_t task_for(int32_t pid)
{
    mach_port_t t = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), (int)pid, &t) != KERN_SUCCESS)
        return MACH_PORT_NULL;
    return t;
}

/* 从目标进程地址空间读取 C 字符串。
 * imgs[i].imagePath 是目标进程地址，直接当本机 const char* 用会读错地址
 * 甚至崩溃；这里必须再做一次跨进程读取。 */
static void read_remote_cstring(mach_port_t task, uint64_t addr,
                                char *out, size_t cap)
{
    out[0] = '\0';
    if (!addr || cap == 0) return;

    char tmp[4096];
    memset(tmp, 0, sizeof(tmp));
    mach_vm_size_t outsz = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        task, (mach_vm_address_t)addr, (mach_vm_size_t)sizeof(tmp) - 1,
        (mach_vm_address_t)tmp, &outsz);
    if (kr != KERN_SUCCESS || outsz == 0) return;

    if (outsz > sizeof(tmp) - 1) outsz = sizeof(tmp) - 1;
    tmp[outsz] = '\0';
    size_t n = strnlen(tmp, (size_t)outsz);
    if (n > cap - 1) n = cap - 1;
    memcpy(out, tmp, n);
    out[n] = '\0';
}

static int dylibs_fast_path(mach_port_t task, line_builder_t *b)
{
    struct task_dyld_info di;
    memset(&di, 0, sizeof(di));
    mach_msg_type_number_t c = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &c) != KERN_SUCCESS ||
        di.all_image_info_addr == 0)
        return -1;

    /* dyld_all_image_infos 的真实开头（dyld_images.h）：
     *   uint32_t version;
     *   uint32_t infoArrayCount;
     *   const struct dyld_image_info *infoArray;   // 64 位指针
     *   ...
     * 注意 version / count 是 uint32，不是 uint64。
     * 这里只读前 24 字节并用 memcpy 取值，不依赖完整结构布局，跨 dyld 版本更稳。 */
    uint8_t hdr[24] = { 0 };
    mach_vm_size_t outsz = 0;
    if (mach_vm_read_overwrite(task, (mach_vm_address_t)di.all_image_info_addr,
                               (mach_vm_size_t)sizeof(hdr),
                               (mach_vm_address_t)hdr, &outsz) != KERN_SUCCESS ||
        outsz < (mach_vm_size_t)sizeof(hdr))
        return -1;

    uint32_t version = 0, count32 = 0;
    uint64_t array_addr = 0;
    memcpy(&version,    hdr,      sizeof(version));
    memcpy(&count32,    hdr + 4,  sizeof(count32));
    memcpy(&array_addr, hdr + 8,  sizeof(array_addr));

    uint64_t img_count = (version >= 1) ? (uint64_t)count32 : 0;
    uint64_t img_addr  = array_addr;
    if (img_count == 0 || img_count > 16384 || img_addr == 0)
        return -1;

    size_t arrsz = (size_t)img_count * sizeof(struct dyld_image_info_local);
    struct dyld_image_info_local *imgs = malloc(arrsz);
    if (!imgs) return -1;

    outsz = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        task, (mach_vm_address_t)img_addr, (mach_vm_size_t)arrsz,
        (mach_vm_address_t)imgs, &outsz);
    if (kr != KERN_SUCCESS || outsz < (mach_vm_size_t)arrsz) {
        free(imgs);
        return -1;
    }

    for (uint64_t i = 0; i < img_count; i++) {
        if (!imgs[i].loadAddress || !imgs[i].imagePath) continue;
        char path[MAXPATHLEN];
        read_remote_cstring(task, imgs[i].imagePath, path, sizeof(path));
        if (path[0] == '\0') continue;
        lb_addf(b, "0x%llx\t%llu\t%s",
                (unsigned long long)imgs[i].loadAddress,
                (unsigned long long)imgs[i].imageModDate,
                path);
    }
    free(imgs);
    return b->n > 1 ? 0 : -1;
}

/*
 * task port 只是「加分项」：
 *   拿得到 → TASK_DYLD_INFO + mach_vm_read_overwrite，结果最精确；
 *   拿不到（SIP 开启时的绝大多数系统进程）→ libproc PROC_PIDREGIONINFO
 *   枚举内存映射 + proc_regionfilename，完全不需要 task port。
 * 旧实现拿不到 task port 就直接返回「需要 root」，在 SIP 下等于该页永远空白，
 * 且 root 也救不了 —— 这里彻底改掉。
 */
int cproc_dylibs(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    lb_add(&b, "加载地址\t修改时间\t镜像路径");

    int had_task = 0, used_fast = 0;
    mach_port_t task = task_for(pid);
    if (task != MACH_PORT_NULL) {
        had_task = 1;
        used_fast = (dylibs_fast_path(task, &b) == 0);
        mach_port_deallocate(mach_task_self(), task);
    }

    if (!used_fast)
        dylibs_via_regions_noport(pid, &b);

    int image_count = b.n - 1;
    if (image_count <= 0)
        lb_addf(&b, "结果\t-\t(未发现已加载镜像，或目标进程不是 Mach-O 用户进程)");
    lb_addf(&b, "合计\t-\t共 %d 个镜像条目", image_count);

    if (used_fast) {
        lb_hint(&b, "来源：TASK_DYLD_INFO（精确，含每个镜像的加载地址与修改时间）");
    } else if (!had_task) {
        lb_hint(&b, "来源：libproc PROC_PIDREGIONINFO 内存映射枚举 + proc_regionfilename");
        lb_hint(&b, "SIP 开启时 task_for_pid 对受保护进程必然失败（与是否 root 无关），此路径不依赖 task port");
        lb_hint(&b, "局限：dyld 共享缓存内的单个 framework 不会逐个展开，只显示缓存文件本身");
    } else {
        lb_hint(&b, "已取得 task port 但 TASK_DYLD_INFO 不可用，已回退到 libproc 内存映射枚举");
        lb_hint(&b, "局限：共享缓存内的单个 framework 不会逐个展开");
    }
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 4. 网络连接 / 5. 文件监控                                           */
/* ------------------------------------------------------------------ */

static const char *tcp_state_name(int s)
{
    static const char *names[] = {
        "CLOSED", "LISTEN", "SYN_SENT", "SYN_RECV", "ESTABLISHED",
        "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2",
        "TIME_WAIT", "RESERVED"
    };
    if (s >= 0 && s < (int)(sizeof(names) / sizeof(names[0]))) return names[s];
    return "UNKNOWN";
}

/*
 * 从 in_sockinfo 的地址字段按字节取地址，避免依赖 SDK 中
 * ina_6 / ina_46 / i46a_addr4 等字段名的版本差异。
 *
 * Darwin 的 in_addr_4in6 布局是：3 个 pad (12 bytes) + in_addr (4 bytes)，
 * 所以 IPv4 地址在 16 字节块的「末尾 4 字节」；直接 memcpy 前 4 字节
 * 会得到 0.0.0.0。IPv6 则整块 16 字节就是 in6_addr。
 */
static void format_addr(const struct in_sockinfo *ini, int foreign,
                        int is_ipv6, char *buf, size_t cap)
{
    char addr[INET6_ADDRSTRLEN] = { 0 };
    const void *src = foreign ? (const void *)&ini->insi_faddr
                              : (const void *)&ini->insi_laddr;
    int port = foreign ? ntohs((uint16_t)ini->insi_fport)
                       : ntohs((uint16_t)ini->insi_lport);

    uint8_t raw[16] = { 0 };
    size_t n = sizeof(ini->insi_laddr);      /* 编译期常量，绝不越界读 */
    if (n > sizeof(raw)) n = sizeof(raw);
    memcpy(raw, src, n);

    if (is_ipv6 && n >= 16) {
        inet_ntop(AF_INET6, raw, addr, sizeof(addr));
    } else if (n >= 16) {
        inet_ntop(AF_INET, raw + 12, addr, sizeof(addr));
    } else {
        inet_ntop(AF_INET, raw, addr, sizeof(addr));
    }
    snprintf(buf, cap, "%s:%d", addr, port);
}

static const char *socket_kind_name(int k)
{
    switch (k) {
    case CPROC_SOCKINFO_GENERIC:    return "GENERIC";
    case CPROC_SOCKINFO_IN:         return "IN";
    case CPROC_SOCKINFO_TCP:        return "TCP";
    case CPROC_SOCKINFO_UN:         return "UN";
    case CPROC_SOCKINFO_NDRV:       return "NDRV";
    case CPROC_SOCKINFO_KERN_EVENT: return "KERN_EVENT";
    case CPROC_SOCKINFO_KERN_CTL:   return "KERN_CTL";
    default:                        return "UNKNOWN";
    }
}

static const char *socket_type_name(int t)
{
    switch (t) {
    case SOCK_STREAM:    return "STREAM";
    case SOCK_DGRAM:     return "DGRAM";
    case SOCK_RAW:       return "RAW";
    case SOCK_RDM:       return "RDM";
    case SOCK_SEQPACKET: return "SEQPACKET";
    default:             return "?";
    }
}

/*
 * 之前「网络连接」页全空的两个直接原因：
 *  1) 传 sizeof(struct socket_fdinfo) 而不是 PROC_PIDFDSOCKETINFO_SIZE，
 *     SDK 结构与内核期望的 buffer 大小不一致时 proc_pidfdinfo 直接返回 0；
 *  2) 所有失败的 FD 都被 continue 吞掉，最后只显示「没有 socket」，
 *     把「读取失败」误报成「进程没有网络连接」。
 * 现在按 SIZE 宏分配堆 buffer，并显式统计成功/失败数。
 */
int cproc_sockets(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    int cnt = 0;
    struct proc_fdinfo *fds = read_fds(pid, &cnt);
    if (!fds) {
        lb_addf(&b, "错误\t-\t-\t-\t-\t无法读取 FD 列表（%s）", strerror(errno));
        return lb_finish(&b, out);
    }

    lb_add(&b, "FD\t协议 / 族\t本地地址\t远端地址\t状态\t补充 (kind / type / PCB)");

    size_t sbufsz = (size_t)PROC_PIDFDSOCKETINFO_SIZE;
    if (sbufsz < sizeof(struct socket_fdinfo))
        sbufsz = sizeof(struct socket_fdinfo);
    void *sbuf = calloc(1, sbufsz);
    if (!sbuf) {
        lb_addf(&b, "错误\t-\t-\t-\t-\t内存不足");
        free(fds);
        return lb_finish(&b, out);
    }

    int socket_fd_cnt = 0, ok_cnt = 0, fail_cnt = 0;
    int first_errno = 0;

    for (int i = 0; i < cnt; i++) {
        if ((i & 31) == 0 && cproc_detail_aborted()) break;
        struct proc_fdinfo *fdi = &fds[i];
        if (fdi->proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        socket_fd_cnt++;

        memset(sbuf, 0, sbufsz);
        int ret = proc_pidfdinfo((int)pid, fdi->proc_fd,
                                 PROC_PIDFDSOCKETINFO, sbuf, (int)sbufsz);
        if (ret <= 0) {
            fail_cnt++;
            if (first_errno == 0) first_errno = errno ? errno : EINVAL;
            continue;
        }

        struct socket_fdinfo sdi;
        memset(&sdi, 0, sizeof(sdi));
        size_t copy = ((size_t)ret < sizeof(sdi)) ? (size_t)ret : sizeof(sdi);
        memcpy(&sdi, sbuf, copy);
        ok_cnt++;

        int family = sdi.psi.soi_family;
        int kind   = sdi.psi.soi_kind;
        int is6    = (family == AF_INET6);
        char extra[512];
        snprintf(extra, sizeof(extra),
                 "kind=%s type=%s proto=%d pcb=0x%llx soi_state=0x%x qlen=%d/%d",
                 socket_kind_name(kind),
                 socket_type_name(sdi.psi.soi_type),
                 sdi.psi.soi_protocol,
                 (unsigned long long)sdi.psi.soi_pcb,
                 (unsigned)sdi.psi.soi_state,
                 (int)sdi.psi.soi_qlen, (int)sdi.psi.soi_qlimit);

        char local[INET6_ADDRSTRLEN + 16]  = { 0 };
        char remote[INET6_ADDRSTRLEN + 16] = { 0 };

        if (family == AF_INET || family == AF_INET6) {
            /* tcpsi_ini 与 pri_in 在 soi_proto union 起始偏移相同；
             * 继续用 pri_in 取地址可避免依赖 SDK 中 tcp_sockinfo 的字段名。 */
            struct in_sockinfo *ini = &sdi.psi.soi_proto.pri_in;
            format_addr(ini, 0, is6, local, sizeof(local));
            format_addr(ini, 1, is6, remote, sizeof(remote));

            if (sdi.psi.soi_protocol == IPPROTO_TCP) {
                struct tcp_sockinfo *tcp = &sdi.psi.soi_proto.pri_tcp;
                lb_addf(&b, "%d\tTCP%s\t%s\t%s\t%s\t%s",
                        fdi->proc_fd, is6 ? "6" : "4",
                        local, remote, tcp_state_name(tcp->tcpsi_state), extra);
            } else if (sdi.psi.soi_protocol == IPPROTO_UDP) {
                lb_addf(&b, "%d\tUDP%s\t%s\t-\t-\t%s",
                        fdi->proc_fd, is6 ? "6" : "4", local, extra);
            } else {
                lb_addf(&b, "%d\tIP proto:%d\t%s\t%s\t-\t%s",
                        fdi->proc_fd, sdi.psi.soi_protocol,
                        local, remote, extra);
            }
        } else if (family == AF_UNIX && kind == CPROC_SOCKINFO_UN) {
            struct un_sockinfo *un = &sdi.psi.soi_proto.pri_un;
            const char *p = un->unsi_addr.ua_sun.sun_path;
            lb_addf(&b, "%d\tUNIX\t%s\t-\t-\t%s",
                    fdi->proc_fd, (p && p[0]) ? p : "(anonymous)", extra);
        } else {
            /* 路由 / NDRV / kern control / VSOCK 等，也如实列出而不再丢弃 */
            lb_addf(&b, "%d\tfamily:%d\t-\t-\t-\t%s",
                    fdi->proc_fd, family, extra);
        }
    }

    free(sbuf);
    free(fds);

    if (socket_fd_cnt == 0) {
        lb_addf(&b, "结果\t-\t-\t-\t-\t(该进程当前没有 socket 描述符)");
    } else if (ok_cnt == 0) {
        lb_addf(&b, "错误\t-\t-\t-\t-\t%d 个 socket FD 全部读取失败（errno=%d: %s）",
                socket_fd_cnt, first_errno, strerror(first_errno));
        lb_hint(&b, "PROC_PIDFDSOCKETINFO 对受 SIP 保护 / 其他用户的进程可能被拒绝；这不是「没有网络连接」");
        lb_hint(&b, "可对照「打开文件」页确认 SOCKET 类型的 FD 是否存在");
    }

    lb_addf(&b, "合计\t-\t-\t-\t-\tsocket FD=%d，成功解析=%d，失败=%d",
            socket_fd_cnt, ok_cnt, fail_cnt);
    if (fail_cnt > 0 && ok_cnt > 0) {
        lb_hint(&b, "部分 socket FD 读取失败（通常是 FD 在两次调用之间被关闭，属正常现象）");
    }
    return lb_finish(&b, out);
}

int cproc_monitoring(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    /* 构建全局 pipe 索引（2 秒缓存），用于把 pipe_peerhandle 反查成对端进程 */
    int index_ok = (pipe_index_build(&g_pipe_index) == 0);

    int cnt = 0;
    struct proc_fdinfo *fds = read_fds(pid, &cnt);
    if (!fds) {
        lb_addf(&b, "错误\t-\t-\t无法读取 FD 列表（%s）", strerror(errno));
        return lb_finish(&b, out);
    }

    lb_add(&b, "FD\t类型\t句柄 / 状态\t说明（含 pipe 对端进程）");

    size_t pbufsz = (size_t)PROC_PIDFDPIPEINFO_SIZE;
    if (pbufsz < sizeof(struct pipe_fdinfo)) pbufsz = sizeof(struct pipe_fdinfo);
    size_t kbufsz = (size_t)PROC_PIDFDKQUEUEINFO_SIZE;
    if (kbufsz < sizeof(struct kqueue_fdinfo)) kbufsz = sizeof(struct kqueue_fdinfo);
    void *pbuf = calloc(1, pbufsz);
    void *kbuf = calloc(1, kbufsz);

    int pipe_n = 0, kq_n = 0, vnode_n = 0, sock_n = 0, other_n = 0;
    int peer_resolved = 0;

    for (int i = 0; i < cnt; i++) {
        if ((i & 31) == 0 && cproc_detail_aborted()) break;
        struct proc_fdinfo *fdi = &fds[i];
        switch (fdi->proc_fdtype) {
        case PROX_FDTYPE_PIPE: {
            struct pipe_fdinfo pdi;
            if (pbuf && read_pipe_fdinfo(pid, fdi->proc_fd,
                                         pbuf, pbufsz, &pdi) == 0) {
                uint64_t h  = pdi.pipeinfo.pipe_handle;
                uint64_t ph = pdi.pipeinfo.pipe_peerhandle;
                const pipe_entry_t *e = pipe_index_find(&g_pipe_index, ph);
                char peer[256];
                if (e) {
                    peer_resolved++;
                    if (e->pid == pid) {
                        snprintf(peer, sizeof(peer),
                                 "对端 PID %d (%s) FD %d — 同一进程（fork 共享 / 自环）",
                                 (int)e->pid, e->comm, (int)e->fd);
                    } else {
                        snprintf(peer, sizeof(peer),
                                 "对端 PID %d (%s) FD %d — 已连接",
                                 (int)e->pid, e->comm, (int)e->fd);
                    }
                } else {
                    snprintf(peer, sizeof(peer),
                             "对端已关闭 / 内核持有 / 无权限枚举");
                }
                lb_addf(&b, "%d\tPIPE\t0x%llx / 0x%llx\t%s",
                        fdi->proc_fd,
                        (unsigned long long)h, (unsigned long long)ph, peer);
            } else {
                lb_addf(&b, "%d\tPIPE\t-\tPIPEINFO 不可用", fdi->proc_fd);
            }
            pipe_n++;
            break;
        }
        case PROX_FDTYPE_KQUEUE: {
            if (kbuf) {
                memset(kbuf, 0, kbufsz);
                int ret = proc_pidfdinfo((int)pid, fdi->proc_fd,
                                         PROC_PIDFDKQUEUEINFO, kbuf, (int)kbufsz);
                if (ret > 0) {
                    struct kqueue_fdinfo kdi;
                    memset(&kdi, 0, sizeof(kdi));
                    size_t cp = ((size_t)ret < sizeof(kdi)) ? (size_t)ret : sizeof(kdi);
                    memcpy(&kdi, kbuf, cp);
                    lb_addf(&b, "%d\tKQUEUE\t0x%x\tkqueue 状态（事件监听）",
                            fdi->proc_fd, kdi.kqueueinfo.kq_state);
                } else {
                    lb_addf(&b, "%d\tKQUEUE\t-\tKQUEUEINFO 不可用", fdi->proc_fd);
                }
            } else {
                lb_addf(&b, "%d\tKQUEUE\t-\t内存不足", fdi->proc_fd);
            }
            kq_n++;
            break;
        }
        case PROX_FDTYPE_VNODE:
            /* 之前只计数不列行，导致「文件」页双击一个普通 vnode FD 跳到本页
             * 时找不到对应条目、无法定位。现在补一行（只给 FD 号与类型，不额外
             * 读路径，避免为几百个文件 FD 再做几百次 proc_pidfdinfo）。 */
            vnode_n++;
            lb_addf(&b, "%d\tVNODE\t-\t普通文件 / 目录（完整路径见「文件」页）",
                    fdi->proc_fd);
            break;
        case PROX_FDTYPE_SOCKET:  sock_n++;  break;
        default: {
            /* 之前只计数不列行，PSHM/FSEVENTS/NETPOLICY 等类型在这一页
             * 完全看不见，用户会以为它们「消失」了。现在逐行给出类型名
             * 与对象说明，与「打开文件」页口径一致。 */
            other_n++;
            lb_addf(&b, "%d\t%s\t-\t%s",
                    fdi->proc_fd,
                    fd_type_name(fdi->proc_fdtype),
                    fd_type_desc(fdi->proc_fdtype));
            break;
        }
        }
    }

    free(pbuf);
    free(kbuf);
    free(fds);

    lb_addf(&b, "合计\t-\t-\tFD=%d (vnode=%d socket=%d pipe=%d kqueue=%d 其他=%d)",
            cnt, vnode_n, sock_n, pipe_n, kq_n, other_n);
    if (pipe_n > 0) {
        if (index_ok) {
            lb_addf(&b, "索引\t-\t-\t全局扫描 %d 个进程 / %d 个 pipe 端点，本页解析出 %d 个对端",
                    g_pipe_index.scanned_pids, g_pipe_index.n, peer_resolved);
            lb_hint(&b, "pipe 对端完全由 libproc 反查，不需要 Mach task port");
        } else {
            lb_hint(&b, "全局 pipe 索引为空，对端进程可能显示为「无权限枚举」");
        }
    }
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 6. 控制终端 / 会话 / 作业控制（TTY）                                 */
/*                                                                    */
/* 全部来自 BSD 进程层（proc_bsdinfo.e_tdev / e_tpgid / pbi_pgid）与   */
/* libproc，不需要 Mach task port；SIP 开启时同样可读。                 */
/* ------------------------------------------------------------------ */

static const char *tty_job_state(uint32_t pgid, uint32_t tpgid, int has_ctty)
{
    if (!has_ctty) return "无控制终端（守护进程 / GUI 应用常见）";
    if (tpgid == 0 || tpgid == 0xffffffffu) return "终端未设置前台进程组";
    return (pgid == tpgid) ? "前台" : "后台";
}

/* 按 SIZE 宏分配堆 buffer 读 vnode 路径，避免与 socket 页同样的 buffer 大小坑 */
static int tty_read_vnode_path(int32_t pid, int32_t fd, char *out, size_t cap)
{
    if (!out || cap == 0) return -1;
    out[0] = '\0';
    size_t sz = (size_t)PROC_PIDFDVNODEPATHINFO_SIZE;
    if (sz < sizeof(struct vnode_fdinfowithpath))
        sz = sizeof(struct vnode_fdinfowithpath);
    void *buf = calloc(1, sz);
    if (!buf) return -1;

    int ret = proc_pidfdinfo((int)pid, fd, PROC_PIDFDVNODEPATHINFO,
                             buf, (int)sz);
    if (ret > 0) {
        struct vnode_fdinfowithpath vp;
        memset(&vp, 0, sizeof(vp));
        size_t cp = ((size_t)ret < sizeof(vp)) ? (size_t)ret : sizeof(vp);
        memcpy(&vp, buf, cp);
        size_t n = strnlen(vp.pvip.vip_path, sizeof(vp.pvip.vip_path) - 1);
        if (n > cap - 1) n = cap - 1;
        memcpy(out, vp.pvip.vip_path, n);
        out[n] = '\0';
    }
    free(buf);
    return ret > 0 ? 0 : -1;
}

/* 同一控制终端上的其他进程：proc_listpids(PROC_TTY_ONLY, dev) */
static void tty_add_peers(line_builder_t *b, uint32_t dev, int32_t self)
{
    int bytes = proc_listpids(PROC_TTY_ONLY, (int)dev, NULL, 0);
    if (bytes <= 0) {
        lb_hint(b, "无法按 TTY 枚举进程（proc_listpids(PROC_TTY_ONLY) 失败）");
        return;
    }
    int *pids = calloc((size_t)bytes / sizeof(int) + 16, sizeof(int));
    if (!pids) return;
    int got = proc_listpids(PROC_TTY_ONLY, (int)dev, pids, bytes);
    int n = got > 0 ? got / (int)sizeof(int) : 0;

    int shown = 0, fg = 0;
    for (int i = 0; i < n && shown < 200; i++) {
        int32_t p = (int32_t)pids[i];
        if (p <= 0) continue;

        char comm[CPROC_COMM_MAX] = { 0 };
        proc_name((int)p, comm, sizeof(comm));

        struct proc_bsdinfo bi;
        memset(&bi, 0, sizeof(bi));
        uint32_t pgid = 0, tpgid = 0;
        if (proc_pidinfo((int)p, PROC_PIDTBSDINFO, 0,
                         &bi, PROC_PIDTBSDINFO_SIZE) == PROC_PIDTBSDINFO_SIZE) {
            pgid  = (uint32_t)bi.pbi_pgid;
            tpgid = (uint32_t)bi.e_tpgid;
        }
        const char *st = tty_job_state(pgid, tpgid, cproc_tty_has_ctty(dev));
        if (strcmp(st, "前台") == 0) fg++;

        lb_addf(b, "同终端进程\t%d (%s)%s\tpgid=%u tpgid=%u · %s",
                (int)p, comm[0] ? comm : "?",
                (p == self) ? " ← 当前" : "",
                (unsigned)pgid, (unsigned)tpgid, st);
        shown++;
    }
    free(pids);

    lb_addf(b, "同终端合计\t%d 个前台 / %d 个列出\tPROC_TTY_ONLY 按 e_tdev 过滤（上限 200）",
            fg, shown);
    if (shown < n)
        lb_hint(b, "同终端进程较多，仅显示前 200 个");
}

/* 尽力读取 tty 设备本身的属性：窗口大小、前台进程组、termios */
static void tty_add_device_props(line_builder_t *b, const char *path)
{
    if (!path || path[0] == '\0' || strcmp(path, "??") == 0) {
        lb_hint(b, "无控制终端，跳过设备属性读取");
        return;
    }

    int fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        lb_addf(b, "设备属性\t不可读（%s）\t通常是其他用户的 pty / 权限限制；只读打开且带 O_NOCTTY，不影响目标进程",
                strerror(errno));
        return;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) {
        lb_addf(b, "终端窗口大小\t%u 行 × %u 列\t像素 %u × %u（TIOCGWINSZ）",
                (unsigned)ws.ws_row, (unsigned)ws.ws_col,
                (unsigned)ws.ws_xpixel, (unsigned)ws.ws_ypixel);
    } else {
        lb_addf(b, "终端窗口大小\t不可读\tTIOCGWINSZ 失败（%s）", strerror(errno));
    }

    pid_t fgp = -1;
    if (ioctl(fd, TIOCGPGRP, &fgp) == 0) {
        lb_addf(b, "设备前台进程组\t%d\tTIOCGPGRP（可与上方 e_tpgid 对照）", (int)fgp);
    } else {
        lb_addf(b, "设备前台进程组\t不可读\tTIOCGPGRP 失败（%s）", strerror(errno));
    }

    struct termios tio;
    memset(&tio, 0, sizeof(tio));
    if (tcgetattr(fd, &tio) == 0) {
        lb_addf(b, "termios 波特率\t%lu / %lu\t输入 / 输出（cfgetispeed / cfgetospeed）",
                (unsigned long)cfgetispeed(&tio),
                (unsigned long)cfgetospeed(&tio));
        char lf[256];
        snprintf(lf, sizeof(lf), "%s%s%s%s%s",
                 (tio.c_lflag & ICANON) ? "ICANON " : "",
                 (tio.c_lflag & ECHO)   ? "ECHO "   : "",
                 (tio.c_lflag & ISIG)   ? "ISIG "   : "",
                 (tio.c_lflag & IEXTEN) ? "IEXTEN " : "",
                 (tio.c_lflag & TOSTOP) ? "TOSTOP"  : "");
        lb_addf(b, "termios 本地模式\t%s\tcanonical / echo / 信号 / 扩展 / 后台写停",
                lf[0] ? lf : "(全部关闭)");
    } else {
        lb_addf(b, "termios\t不可读\ttcgetattr 失败（%s）", strerror(errno));
    }
    close(fd);
    lb_hint(b, "设备属性通过对 /dev 节点只读 ioctl 获取，不需要目标进程的 task port");
}

int cproc_tty(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;
    lb_add(&b, "项目\t值\t说明");

    struct proc_bsdinfo bi;
    memset(&bi, 0, sizeof(bi));
    int ret = proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0,
                           &bi, PROC_PIDTBSDINFO_SIZE);
    if (ret <= 0) {
        lb_addf(&b, "错误\t-\t无法读取 proc_bsdinfo（%s）；进程可能已退出",
                strerror(errno));
        return lb_finish(&b, out);
    }

    uint32_t dev   = (uint32_t)bi.e_tdev;
    uint32_t pgid  = (uint32_t)bi.pbi_pgid;
    uint32_t tpgid = (uint32_t)bi.e_tpgid;
    uint32_t jobc  = (uint32_t)bi.pbi_pjobc;
    int has = cproc_tty_has_ctty(dev);

    char path[CPROC_TTY_MAX] = { 0 };
    int named = cproc_tty_devname(dev, path, sizeof(path));

    lb_addf(&b, "控制终端 e_tdev\t0x%08x (%u)\tproc_bsdinfo.e_tdev / kinfo_proc.kp_eproc.e_tdev，BSD 层，不依赖 task port",
            (unsigned)dev, (unsigned)dev);
    lb_addf(&b, "主 / 次设备号\t%d / %d\tDarwin dev_t 编码（major 高 12 位 / minor 低 8 位）",
            cproc_tty_major(dev), cproc_tty_minor(dev));
    lb_addf(&b, "设备路径\t%s\t%s",
            named == 0 ? path : "??",
            named == 0 ? "devname_r 或 /dev 扫描反查" : "无终端显示为 ??（ps 的 TT 列同理）");
    lb_addf(&b, "有无控制终端\t%s\tNODEV / 0 表示无；GUI 应用与守护进程通常没有",
            has ? "有" : "无");
    lb_addf(&b, "进程组 PGID\t%u\tproc_bsdinfo.pbi_pgid", (unsigned)pgid);
    lb_addf(&b, "终端前台进程组 TPGID\t%u\tproc_bsdinfo.e_tpgid", (unsigned)tpgid);
    lb_addf(&b, "作业控制状态\t%s\tpgid == tpgid 即前台（ps 的 STAT 里 + 号同理）",
            tty_job_state(pgid, tpgid, has));
    lb_addf(&b, "jobc\t%u\tpbi_pjobc：该进程组里仍关联此终端的作业数", (unsigned)jobc);
    lb_addf(&b, "是否进程组首进程\t%s\tpid == pgid（pid=%d, pgid=%u）",
            ((uint32_t)pid == pgid) ? "是" : "否", (int)pid, (unsigned)pgid);
    lb_addf(&b, "会话 ID (SID)\t不可用\tmacOS 不提供数字 SID；ps -o sess 打印的是内核 session 指针，可用 PGID/TPGID 推断");
    lb_addf(&b, "BSD flags\t0x%08x\tSLEADER=%s CTTY=%s CONTROLT=%s",
            (unsigned)bi.pbi_flags,
            (bi.pbi_flags & PROC_FLAG_SLEADER)  ? "是" : "否",
            (bi.pbi_flags & PROC_FLAG_CTTY)     ? "是" : "否",
            (bi.pbi_flags & PROC_FLAG_CONTROLT) ? "是" : "否");

    /* FD 0 / 1 / 2 是否指向该 tty（重定向后可能不同） */
    int cnt = 0;
    struct proc_fdinfo *fds = read_fds(pid, &cnt);
    const char *labels[3] = { "标准输入 FD 0", "标准输出 FD 1", "标准错误 FD 2" };
    for (int k = 0; k < 3; k++) {
        char vp[MAXPATHLEN] = { 0 };
        const char *type = "未知";
        if (fds) {
            for (int i = 0; i < cnt; i++) {
                if (fds[i].proc_fd == k) {
                    type = fd_type_name(fds[i].proc_fdtype);
                    break;
                }
            }
        }
        if (tty_read_vnode_path(pid, (int32_t)k, vp, sizeof(vp)) == 0 && vp[0]) {
            int same = (named == 0 && strcmp(vp, path) == 0);
            lb_addf(&b, "%s\t%s\t%s%s",
                    labels[k], vp, type,
                    same ? " · 与控制终端一致" : " · 已被重定向");
        } else {
            lb_addf(&b, "%s\t-\t%s（非 vnode 或读取失败）", labels[k], type);
        }
    }
    free(fds);

    /* 同一终端上的所有进程 */
    if (has) {
        tty_add_peers(&b, dev, pid);
    } else {
        lb_hint(&b, "该进程没有控制终端，不列出同终端进程");
    }

    /* 设备本身属性（尽力而为） */
    if (has) tty_add_device_props(&b, named == 0 ? path : NULL);

    lb_hint(&b, "全部数据来自 libproc / BSD proc_bsdinfo / 只读 ioctl，SIP 开启时同样可用");
    return lb_finish(&b, out);
}

/* ------------------------------------------------------------------ */
/* 7. Mach 安全信息（BSD 标志 + task port 相关）                        */
/* ------------------------------------------------------------------ */

int cproc_mach_security(int32_t pid, cproc_lines_t *out)
{
    line_builder_t b;
    if (lb_init(&b) != 0) return -1;

    struct proc_bsdinfo bi;
    memset(&bi, 0, sizeof(bi));
    int ret = proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0,
                           &bi, PROC_PIDTBSDINFO_SIZE);
    lb_add(&b, "项目\t值\t说明");
    if (ret <= 0) {
        lb_addf(&b, "错误\t-\t无法读取 proc_bsdinfo（%s）", strerror(errno));
        return lb_finish(&b, out);
    }

    lb_addf(&b, "PID\t%d\t短名 %.*s", (int)bi.pbi_pid,
            (int)sizeof(bi.pbi_comm), bi.pbi_comm);
    lb_addf(&b, "UID / GID\t%d / %d\tRUID %d / RGID %d",
            (int)bi.pbi_uid, (int)bi.pbi_gid,
            (int)bi.pbi_ruid, (int)bi.pbi_rgid);
    lb_addf(&b, "SVUID / SVGID\t%d / %d\t保存的 set-user/group ID",
            (int)bi.pbi_svuid, (int)bi.pbi_svgid);
    lb_addf(&b, "PGID / 会话\t%d / -\t进程组", (int)bi.pbi_pgid);
    lb_addf(&b, "nice\t%d\t调度优先级修正", (int)bi.pbi_nice);
    lb_addf(&b, "BSD flags\t0x%08x\t见下方逐位说明", bi.pbi_flags);

    enum { CPROC_NFLAGS = 11 };
    struct { uint32_t bit; const char *name; } flagdefs[CPROC_NFLAGS] = {
        { PROC_FLAG_SYSTEM,     "SYSTEM" },
        { PROC_FLAG_TRACED,     "TRACED" },
        { PROC_FLAG_INEXIT,     "INEXIT" },
        { PROC_FLAG_PPWAIT,     "PPWAIT" },
        { PROC_FLAG_LP64,       "LP64" },
        { PROC_FLAG_SLEADER,    "SLEADER" },
        { PROC_FLAG_CTTY,       "CTTY" },
        { PROC_FLAG_CONTROLT,   "CONTROLT" },
        { PROC_FLAG_THCWD,      "THCWD" },
        { PROC_FLAG_PSUGID,     "PSUGID" },
        { PROC_FLAG_EXEC,       "EXEC" },
    };
    char flagstr[512] = { 0 };
    size_t used = 0;
    for (size_t i = 0; i < CPROC_NFLAGS; i++) {
        if (bi.pbi_flags & flagdefs[i].bit) {
            int k = snprintf(flagstr + used, sizeof(flagstr) - used,
                             "%s%s", used ? " " : "", flagdefs[i].name);
            if (k > 0) used += (size_t)k;
            if (used >= sizeof(flagstr) - 1) break;
        }
    }
    lb_addf(&b, "标志位明细\t%s\t按位展开", used ? flagstr : "(none)");

    /* ---- 路径 A：csops 系统调用，完全不需要 task port ----
     * CS_OPS_* 编号容易记错；xnu bsd/sys/codesign.h 的真实值是
     * CS_OPS_STATUS=0 / CS_OPS_TEAMID=14 / CS_OPS_CDHASH=5 等。 */
#ifdef SYS_csops
/* csops 没有公开包装函数，只能走 syscall(2)。macOS 10.12 起 syscall 被
 * 标记 deprecated，但 Apple 并没有为 CS_OPS_* 提供替代 API（kdebug_signpost
 * 只对应 SYS_kdebug_trace，与代码签名无关）。这里局部关闭该警告，避免每次
 * 构建刷屏；push/pop 限定在这个 #ifdef 块内，不影响文件其它部分。 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    {
        uint32_t csflags = 0;
        int rc = (int)syscall(SYS_csops, (pid_t)pid,
                              (unsigned int)CPROC_CS_OPS_STATUS,
                              &csflags, sizeof(csflags));
        if (rc == 0) {
            lb_addf(&b, "CS flags (csops)\t0x%08x\t来自 sysctl 风格的 csops(CS_OPS_STATUS)，无需 task port",
                    csflags);
            struct { uint32_t bit; const char *n; } csdefs[] = {
                { 0x00000001u, "CS_VALID" },
                { 0x00000002u, "CS_ADHOC" },
                { 0x00000004u, "CS_GET_TASK_ALLOW" },
                { 0x00000100u, "CS_HARD" },
                { 0x00000200u, "CS_KILL" },
                { 0x00000400u, "CS_CHECK_EXPIRATION" },
                { 0x00000800u, "CS_RESTRICT" },
                { 0x00001000u, "CS_ENFORCEMENT" },
                { 0x00002000u, "CS_REQUIRE_LV" },
                { 0x00010000u, "CS_RUNTIME (Hardened Runtime)" },
                { 0x04000000u, "CS_PLATFORM_BINARY (Apple 平台二进制)" },
            };
            char csbuf[512] = { 0 };
            size_t cu = 0;
            for (size_t i = 0; i < sizeof(csdefs) / sizeof(csdefs[0]); i++) {
                if (csflags & csdefs[i].bit) {
                    int k = snprintf(csbuf + cu, sizeof(csbuf) - cu,
                                     "%s%s", cu ? ", " : "", csdefs[i].n);
                    if (k > 0) cu += (size_t)k;
                    if (cu >= sizeof(csbuf) - 1) break;
                }
            }
            lb_addf(&b, "CS 标志位明细\t%s\t按位展开（值为 xnu 常见定义）",
                    cu ? csbuf : "(无已知标志)");
        } else {
            lb_addf(&b, "CS flags (csops)\t-\t调用失败（%s）", strerror(errno));
        }

        char team[128] = { 0 };
        rc = (int)syscall(SYS_csops, (pid_t)pid,
                          (unsigned int)CPROC_CS_OPS_TEAMID,
                          team, sizeof(team));
        if (rc >= 0 && team[0])
            lb_addf(&b, "Team ID (csops)\t%s\t来自 csops(CS_OPS_TEAMID)", team);
    }
#pragma clang diagnostic pop
#else
    lb_hint(&b, "本 SDK 未导出 SYS_csops，CS flags 请查看「代码签名」页");
#endif

    /* ---- 路径 B：task_name_for_pid + task_info(TASK_AUDIT_TOKEN) ----
     * Apple DTS 明确推荐用 task_name_for_pid 取得任意进程的 task name port，
     * 再用 task_info 读 audit token。task name port 只授予 task_info 能力，
     * 不能读写内存，因此受 SIP 限制比 task_for_pid 少得多。
     * 用 dlsym 动态解析，避免不同 SDK 里该函数声明位置不同导致编译/链接失败。 */
#ifdef TASK_AUDIT_TOKEN
    {
        typedef kern_return_t (*tnfp_fn)(mach_port_t, int, mach_port_t *);
        void *sym = dlsym(RTLD_DEFAULT, "task_name_for_pid");
        tnfp_fn tnfp = NULL;
        if (sym) memcpy(&tnfp, &sym, sizeof(tnfp));

        if (!tnfp) {
            lb_hint(&b, "本系统未导出 task_name_for_pid，Audit Token 不可用");
        } else {
            mach_port_t tname = MACH_PORT_NULL;
            kern_return_t kr = tnfp(mach_task_self(), (int)pid, &tname);
            if (kr == KERN_SUCCESS && tname != MACH_PORT_NULL) {
                lb_addf(&b, "task name port\t%u\ttask_name_for_pid 取得（只读，可 task_info）",
                        (unsigned)tname);
                audit_token_t tok;
                memset(&tok, 0, sizeof(tok));
                mach_msg_type_number_t c = TASK_AUDIT_TOKEN_COUNT;
                if (task_info(tname, TASK_AUDIT_TOKEN,
                              (task_info_t)&tok, &c) == KERN_SUCCESS) {
                    lb_addf(&b, "Audit token\t%08x %08x %08x %08x %08x %08x %08x %08x\t8 × uint32；val[5] 为 pid，val[7] 为 idversion",
                            tok.val[0], tok.val[1], tok.val[2], tok.val[3],
                            tok.val[4], tok.val[5], tok.val[6], tok.val[7]);
                    lb_hint(&b, "Audit token 由 task_name_for_pid 取得，不需要 task_for_pid（SIP 开启时仍可能可用）");
                } else {
                    lb_hint(&b, "task_info(TASK_AUDIT_TOKEN) 在 task name port 上被拒绝");
                }
#ifdef TASK_SECURITY_TOKEN
                security_token_t sec;
                memset(&sec, 0, sizeof(sec));
                mach_msg_type_number_t sc = TASK_SECURITY_TOKEN_COUNT;
                if (task_info(tname, TASK_SECURITY_TOKEN,
                              (task_info_t)&sec, &sc) == KERN_SUCCESS) {
                    lb_addf(&b, "Security token\t%08x %08x\t2 × uint32",
                            sec.val[0], sec.val[1]);
                }
#endif
                mach_port_deallocate(mach_task_self(), tname);
            } else {
                lb_addf(&b, "task name port\t-\ttask_name_for_pid 失败 (kr=%d)",
                        (int)kr);
            }
        }
    }
#endif

    /* ---- 路径 C：完整 task port，仅作加分项 ---- */
    mach_port_t task = task_for(pid);
    if (task == MACH_PORT_NULL) {
        lb_hint(&b, "task_for_pid 失败：SIP 开启时对受保护进程必然失败，与是否 root 无关");
        lb_hint(&b, "Apple《Runtime Protections》：受保护进程的 task_for_pid / processor_set_tasks 返回 EPERM");
        lb_hint(&b, "com.apple.security.cs.debugger 只对带 get-task-allow 的第三方进程有效；com.apple.system-task-ports 仅授予 Apple");
        lb_hint(&b, "本页上方 CS flags / Audit token / BSD 信息均不依赖 task port；签名详情见「代码签名」页");
        return lb_finish(&b, out);
    }

    lb_addf(&b, "task port\t%u\t完整 Mach 任务端口（可读内存 / 枚举线程，SIP 下通常拿不到）",
            (unsigned)task);
#ifdef TASK_DYLD_INFO
    {
        struct task_dyld_info di;
        memset(&di, 0, sizeof(di));
        mach_msg_type_number_t c = TASK_DYLD_INFO_COUNT;
        if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &c) == KERN_SUCCESS) {
            lb_addf(&b, "dyld all_image_info_addr\t0x%llx\tTASK_DYLD_INFO 可用（精确镜像列表见「已加载镜像」页）",
                    (unsigned long long)di.all_image_info_addr);
        }
    }
#endif
    mach_port_deallocate(mach_task_self(), task);
    return lb_finish(&b, out);
}

int cproc_task_port(int32_t pid, uint32_t *out_port)
{
    if (!out_port) return -1;
    mach_port_t task = task_for(pid);
    if (task == MACH_PORT_NULL) {
        *out_port = 0;
        return -1;
    }
    *out_port = (uint32_t)task;
    mach_port_deallocate(mach_task_self(), task);
    return 0;
}

int cproc_signal(int32_t pid, int32_t sig)
{
    return kill((pid_t)pid, sig);
}
