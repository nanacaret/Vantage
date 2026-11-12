/* SPDX-License-Identifier: MIT */
#ifndef CPROC_H
#define CPROC_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * CProc —— macOS 进程信息采集层（公共 SDK 实现）
 *
 * 设计约定：
 *  1. 所有对外数据结构都是「扁平值 + 定长 char 数组」，Swift 侧通过
 *     cproc_xxx() accessor 读取字符串，避免处理 C 定长数组被导入成 tuple。
 *  2. 详情类接口统一返回 cproc_lines_t（字符串数组），每行用 '\t' 分隔字段，
 *     Swift 侧按字段拆成表格列。错误/提示信息也用行返回，UI 无需解析 stderr。
 *  3. SIP 开启时 task_for_pid() 对受保护进程必然失败（与 root 无关），因此
 *     所有能力都优先走 libproc / Security.framework / sysctl 这类「不需要 Mach
 *     task port」的路径；task port 只作为「能拿到时更精确」的加分项。
 */

#define CPROC_COMM_MAX     64
#define CPROC_NAME_MAX     128
#define CPROC_CMDLINE_MAX  4096
#define CPROC_EXEPATH_MAX  1024
#define CPROC_ARGV0_MAX    1024
#define CPROC_TTY_MAX      128

/* ---------- 可执行文件架构切片（Mach-O cputype） ----------
 * cproc_snapshot_t.exec_archs 是这些位的按位或；0 表示「读不到」，
 * 与「只有一个未知架构」(CPROC_ARCH_OTHER) 区分开。 */
#define CPROC_ARCH_X86       0x0001u  /* i386 */
#define CPROC_ARCH_X86_64    0x0002u
#define CPROC_ARCH_ARM       0x0004u  /* 32-bit ARM */
#define CPROC_ARCH_ARM64     0x0008u
#define CPROC_ARCH_ARM64_32  0x0010u  /* watchOS */
#define CPROC_ARCH_PPC       0x0020u
#define CPROC_ARCH_PPC64     0x0040u
#define CPROC_ARCH_ARM64E    0x0100u  /* cpusubtype=ARM64E，同时置 ARM64 位 */
#define CPROC_ARCH_OTHER     0x8000u

typedef struct {
    int32_t  pid;
    int32_t  ppid;
    int32_t  uid;
    int32_t  gid;
    int32_t  nice;
    int32_t  priority;
    uint32_t status;          /* SIDL / SRUN / SSLEEP / SSTOP / SZOMB */
    uint32_t flags;           /* proc_bsdinfo.pbi_flags */
    uint32_t translated;      /* 1 = 运行时经 Rosetta 2（由二进制架构可靠推出） */
    uint32_t exec_archs;      /* CPROC_ARCH_* 位掩码：可执行文件含哪些 slice */
    uint32_t pgid;

    uint64_t start_sec;
    uint64_t start_usec;
    uint64_t rss;             /* resident_size, bytes */
    uint64_t vss;             /* virtual_size, bytes */
    uint64_t cpu_user_ns;     /* 累积用户态 CPU 时间 */
    uint64_t cpu_sys_ns;      /* 累积内核态 CPU 时间 */
    uint64_t threads;
    uint64_t faults;
    uint64_t pageins;
    uint64_t cow_faults;
    uint64_t csw;
    uint64_t msg_sent;
    uint64_t msg_recv;
    uint64_t sys_mach;
    uint64_t sys_unix;
    uint64_t nfiles;

    /* 控制终端：BSD 层信息，不需要 task port，SIP 开启时同样可读 */
    uint32_t tty_dev;             /* proc_bsdinfo.e_tdev（dev_t），0/NODEV = 无控制终端 */
    uint32_t tty_tpgid;           /* proc_bsdinfo.e_tpgid：终端前台进程组 */
    uint32_t tty_pgid;            /* proc_bsdinfo.pbi_pgid：本进程进程组 */
    uint32_t tty_jobc;            /* proc_bsdinfo.pbi_pjobc：job control 计数 */

    char     comm[CPROC_COMM_MAX];
    char     name[CPROC_NAME_MAX];
    char     cmdline[CPROC_CMDLINE_MAX];
    char     exepath[CPROC_EXEPATH_MAX];
    char     argv0[CPROC_ARGV0_MAX];   /* KERN_PROCARGS2 里的原始 argv[0] */
    char     tty_name[CPROC_TTY_MAX];  /* /dev/ttysNNN，无终端时为 "??" */
} cproc_snapshot_t;

typedef struct {
    cproc_snapshot_t *items;
    int32_t  count;

    uint64_t timestamp_ns;    /* CLOCK_MONOTONIC，用于 CPU 差分 */
    uint32_t logical_cpus;
    uint32_t physical_cpus;
    uint32_t host_arm64;      /* 主机是否为 Apple Silicon */

    uint64_t mem_total;
    uint64_t mem_used;
    uint64_t mem_free;
    uint64_t mem_wired;
    uint64_t mem_compressed;
    uint64_t swap_used;
    uint64_t swap_total;

    uint64_t threads_total;
    double   load1;
    double   load5;
    double   load15;
} cproc_system_t;

typedef struct {
    char   **lines;
    int32_t  count;
} cproc_lines_t;

/* ---------- 进程快照 ---------- */
int  cproc_collect(cproc_system_t *out);
void cproc_free(cproc_system_t *sys);

/* 读 Mach-O 文件头，返回 CPROC_ARCH_* 位掩码（0 = 读不到 / 非 Mach-O）。
 * 按路径 + dev/ino/mtime/size 缓存，TTL 内不做任何系统调用。
 * cproc_exec_archs_flush() 供强制刷新时清空缓存。 */
uint32_t cproc_exec_archs(const char *path);
void     cproc_exec_archs_flush(void);

/* ---------- 单进程详情 ---------- */
int  cproc_open_files   (int32_t pid, cproc_lines_t *out);
int  cproc_env_vars     (int32_t pid, cproc_lines_t *out);
int  cproc_dylibs       (int32_t pid, cproc_lines_t *out);
int  cproc_sockets      (int32_t pid, cproc_lines_t *out);
int  cproc_monitoring   (int32_t pid, cproc_lines_t *out);
int  cproc_mach_security(int32_t pid, cproc_lines_t *out);
/* 以下接口完全不依赖 task port，SIP 开启时对系统进程同样可用 */
int  cproc_regions      (int32_t pid, cproc_lines_t *out);  /* 内存映射 region 枚举 */
int  cproc_pipe_peers   (int32_t pid, cproc_lines_t *out);  /* pipe 对端进程解析 */
int  cproc_tty          (int32_t pid, cproc_lines_t *out);  /* 控制终端 / 会话 / 作业控制 */
int  cproc_task_port    (int32_t pid, uint32_t *out_port);
int  cproc_signal       (int32_t pid, int32_t sig);
void cproc_lines_free   (cproc_lines_t *lines);

/* ---------- 详情采集的取消标记（epoch） ----------
 * 详情里的 region 枚举、全系统 pipe FD 扫描是长循环，Swift 侧切换进程 / 页签
 * 时必须能中止已在运行的旧批次，否则快速点选会排队等最慢的一次跑完。
 * 用法：begin_epoch() 取新 epoch → 后台队列开头 mark_epoch(e) →
 *      新批次开始时 cancel_epoch(旧 e) → 长循环里 aborted() 为真就提前返回。
 * epoch 绑在当前线程上，不同窗口 / 队列互不干扰。 */
uint64_t cproc_detail_begin_epoch (void);
void     cproc_detail_mark_epoch  (uint64_t epoch);
void     cproc_detail_cancel_epoch(uint64_t epoch);
int      cproc_detail_aborted     (void);

/* ---------- 运行时可配置上限（偏好设置） ----------
 * 这些值由 Swift 偏好设置下发，替代散落在各 .c 文件里的硬编码宏。
 * 采集线程按「下一次采集生效」读取，不需要重启 App。 */
typedef struct {
    uint32_t max_regions;       /* 详情 vm_map region 枚举上限 */
    uint32_t pipe_cache_ms;     /* 全系统 pipe 索引缓存时长 */
    uint32_t argv_max_bytes;    /* KERN_PROCARGS2 缓冲区上限 */
    uint32_t fd_max_bytes;      /* PROC_PIDLISTFDS 缓冲区上限 */
    uint32_t smc_max_keys;      /* SMC #KEY 枚举上限 */
} cproc_limits_t;

void cproc_get_limits(cproc_limits_t *out);
void cproc_set_limits(const cproc_limits_t *in);

/* ---------- 字符串 accessor（Swift 友好） ---------- */
const char *cproc_comm   (const cproc_snapshot_t *p);
const char *cproc_name   (const cproc_snapshot_t *p);
const char *cproc_cmdline(const cproc_snapshot_t *p);
const char *cproc_exepath(const cproc_snapshot_t *p);
const char *cproc_argv0   (const cproc_snapshot_t *p);
const char *cproc_tty_name(const cproc_snapshot_t *p);
const char *cproc_line   (const cproc_lines_t *lines, int32_t index);
const char *cproc_state_name(uint32_t status);
uint64_t    cproc_now_ns(void);

/* dev_t → "/dev/ttysNNN"。快照填充与 TTY 详情共用；
 * 返回 0 表示成功，buf 内为设备路径；无控制终端时返回 -1。 */
int  cproc_tty_devname(uint32_t dev, char *buf, size_t cap);
int  cproc_tty_has_ctty(uint32_t dev);
int  cproc_tty_major(uint32_t dev);
int  cproc_tty_minor(uint32_t dev);

/* ---------- IORegistry 设备树（ioreg.c） ----------
 * 纯公开 IOKit API，无需 root / task port。输出 '\t' 分隔的 ASCII 结构行，
 * 所有界面文案由 Swift 侧 L() 生成；这里不写中文。
 * plane 传 "IOService" / "IODeviceTree" / "IOPower" / "IOUSB" 等。 */
int  cproc_ioreg_tree(const char *plane, cproc_lines_t *out);
/* path 取 NODE 行最后一列的完整 registry path（已含 plane 前缀） */
int  cproc_ioreg_properties(const char *path, cproc_lines_t *out);
/* 单次枚举节点上限（默认 30000），由偏好设置下发 */
void cproc_ioreg_set_max_nodes(uint32_t n);

/* SwiftPM 生成的 module map 可能用 umbrella 目录，也可能只用单个头；
 * 这里显式引入，保证两种情况下 CPerf.h 的声明都会被导出到 Swift。
 * CPerf.h 自带 include guard，重复包含无害；放在 extern "C" 内兼容 C++。 */
#include "CPerf.h"

#ifdef __cplusplus
}
#endif

#endif /* CPROC_H */
