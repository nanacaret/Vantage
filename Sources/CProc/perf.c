/* SPDX-License-Identifier: MIT */
#include "CPerf.h"
#include "cproc_l10n_data.h"  /* 生成的双语表：中文是 value，key 是语义标识 */
#include "CProc.h"
#include "cproc_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/socket.h>
#include <notify.h>

#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/vmmeter.h>
#include <sys/stat.h>

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/processor_info.h>
#include <mach/vm_map.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/*
 * 参考 macmon (vladkens/macmon) 的采集分层，但用纯 C + 公共 SDK 实现：
 *   - IOReport：通过 dlopen/dlsym 动态解析（私有库，无 root 即可读）
 *   - AppleSMC：IOKit user client（selector 2 / 80 字节参数块）
 *   - IORegistry：pmgr voltage-states 得到 DVFS 频率上限
 *   - 公开层：host_statistics / host_processor_info / IOBlockStorageDriver /
 *            getifaddrs / vm_stat / notify 热压
 *
 * 所有私有 API 都是「能拿到就用，拿不到就降级」；绝不用 0 冒充读数。
 */

/* IOServiceGetMatchingServices / IOServiceGetMatchingService 的 mainPort。
 * kIOMainPortDefault（新 SDK）与 kIOMasterPortDefault（旧 SDK）都等于 0，
 * 直接传 0 可避开「是宏还是 extern 变量」的 SDK 差异。 */
#define CPERF_MAIN_PORT ((mach_port_t)0)

/* RTLD_DEFAULT 在部分 SDK / 编译模式下不是宏 */
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *)-2)
#endif

/* AF_LINK 定义在 <sys/socket.h>，个别 SDK 组合下可能没被间接包含 */
#ifndef AF_LINK
#define AF_LINK 18
#endif

#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif

#define CPERF_MAX_CORES   128
#define CPERF_MAX_META    4096
#define CPERF_MAX_FREQ_STATES 64

static int str_ends(const char *s, const char *suf)
{
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

static int str_starts(const char *s, const char *pre)
{
    return strncmp(s, pre, strlen(pre)) == 0;
}

/* SMC #KEY 枚举上限由偏好设置下发（默认 65535）。
 * 上限不能设成 1024：Apple Silicon 上约有 3246 个键，会导致键枚举失败。 */
#define CPERF_SMC_MAX_KEYS() ((uint32_t)g_cproc_limits.smc_max_keys)
#define CPERF_SMC_TEMP_KEYS 1024
#define CPERF_SMC_FAN_KEYS  128
#define CPERF_SMC_STRUCT_SZ 80
#define CPERF_SMC_READ       5
#define CPERF_SMC_GET_INFO   9
#define CPERF_SMC_FROM_IDX   8

/* SMC 参数块里的字节偏移（80 字节，含自然对齐产生的 padding） */
#define SMC_OFF_KEY        0
#define SMC_OFF_DATASIZE  28
#define SMC_OFF_DATATYPE  32
#define SMC_OFF_RESULT    40
#define SMC_OFF_STATUS    41
#define SMC_OFF_DATA8     42
#define SMC_OFF_DATA32    44
#define SMC_OFF_BYTES     48

/* IOReport channel format（xnu iorepdump 中一致） */
#define IOR_FORMAT_SIMPLE       1
#define IOR_FORMAT_STATE        2
#define IOR_FORMAT_SIMPLE_ARRAY 4

/* ------------------------------------------------------------------ */
/* 基础工具                                                           */
/* ------------------------------------------------------------------ */

uint64_t cproc_perf_now_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint32_t fourcc(const char *s)
{
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |
           (uint32_t)(uint8_t)s[3];
}

static void fourcc_str(uint32_t k, char out[5])
{
    out[0] = (char)((k >> 24) & 0xff);
    out[1] = (char)((k >> 16) & 0xff);
    out[2] = (char)((k >> 8) & 0xff);
    out[3] = (char)(k & 0xff);
    out[4] = '\0';
}

static void put_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, sizeof(v)); }
static uint32_t get_u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, sizeof(v)); return v; }

static int sysctl_int(const char *name, int64_t *out)
{
    if (!out) return -1;
    int64_t v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) {
        int iv = 0;
        len = sizeof(iv);
        if (sysctlbyname(name, &iv, &len, NULL, 0) != 0) return -1;
        v = iv;
    }
    *out = v;
    return 0;
}

static void cfstr_copy(CFStringRef s, char *buf, size_t cap)
{
    if (!buf || cap == 0) return;
    buf[0] = '\0';
    if (!s || CFGetTypeID(s) != CFStringGetTypeID()) return;
    CFStringGetCString(s, buf, (CFIndex)cap, kCFStringEncodingUTF8);
}

static void trim_space(char *s)
{
    if (!s) return;
    char *p = s;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' ||
                     s[n - 1] == '\n' || s[n - 1] == '\r')) {
        s[--n] = '\0';
    }
}

static uint64_t cfnum_u64(CFDictionaryRef dict, const char *key)
{
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return 0;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!k) return 0;
    CFTypeRef v = CFDictionaryGetValue(dict, k);
    CFRelease(k);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return 0;
    int64_t out = 0;
    if (!CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &out)) {
        int iv = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &iv)) out = iv;
    }
    return out > 0 ? (uint64_t)out : 0;
}

static CFArrayRef channels_array(CFDictionaryRef sample)
{
    if (!sample || CFGetTypeID(sample) != CFDictionaryGetTypeID()) return NULL;
    CFStringRef key = CFStringCreateWithCString(NULL, "IOReportChannels",
                                                 kCFStringEncodingUTF8);
    if (!key) return NULL;
    CFTypeRef v = CFDictionaryGetValue(sample, key);
    CFRelease(key);
    if (!v || CFGetTypeID(v) != CFArrayGetTypeID()) return NULL;
    return (CFArrayRef)v;
}

/* ------------------------------------------------------------------ */
/* 静态 SoC 信息                                                       */
/* ------------------------------------------------------------------ */

/* pmgr 的每一张 voltage-statesN[-sram] 表单独保留。
 * M5 起不再固定 1=E / 5=P：Apple 用 `acc-clusters` 属性给出「每个 CPU 簇
 * 对应哪张表的索引」，不同机型编号不同（实测 M5 Max 是 22/23/5），
 * 所以必须把所有表都留着，再按档数和频率范围匹配 P-state 通道。 */
typedef struct {
    int      id;                                  /* voltage-states 后面的编号 */
    int      is_sram;
    uint32_t freqs[CPERF_MAX_FREQ_STATES];
    int      n;
} dvfs_table_t;

#define CPERF_MAX_DVFS_TABLES 32

typedef struct {
    char     soc_name[CPERF_SOC_NAME_MAX];
    char     status[CPERF_STATUS_MAX];
    uint32_t p_cores, e_cores, gpu_cores, nperflevels;
    uint32_t p_freq_max_mhz, e_freq_max_mhz, m_freq_max_mhz, gpu_freq_max_mhz;

    /* 最终选中的簇频率表（升序）。state 名不带 MHz 时按索引反查。 */
    uint32_t e_freqs[CPERF_MAX_FREQ_STATES];
    uint32_t p_freqs[CPERF_MAX_FREQ_STATES];
    uint32_t m_freqs[CPERF_MAX_FREQ_STATES];
    uint32_t gpu_freqs[CPERF_MAX_FREQ_STATES];
    int      e_freq_n, p_freq_n, m_freq_n, gpu_freq_n;

    /* pmgr 原始表池，按 id 排序，供诊断输出与簇表匹配 */
    dvfs_table_t tables[CPERF_MAX_DVFS_TABLES];
    int          table_n;
    int          cpu_table_unit_khz;   /* 1 = M4+ CPU 表频率单位是 kHz */

    int      apple_silicon;
} soc_info_t;

static soc_info_t g_soc;

static int read_soc_name(char *buf, size_t cap)
{
    char tmp[256] = { 0 };
    size_t len = sizeof(tmp);
    if (sysctlbyname("machdep.cpu.brand_string", tmp, &len, NULL, 0) == 0 && tmp[0]) {
        snprintf(buf, cap, "%s", tmp);
        return 0;
    }
    char model[128] = { 0 };
    len = sizeof(model);
    if (sysctlbyname("hw.model", model, &len, NULL, 0) == 0 && model[0]) {
        snprintf(buf, cap, "%s", model);
        return 0;
    }
    snprintf(buf, cap, "Unknown Mac");
    return -1;
}

static int ioreg_iter(const char *class_name, io_iterator_t *it_out)
{
    *it_out = IO_OBJECT_NULL;
    CFMutableDictionaryRef m = IOServiceMatching(class_name);
    if (!m) return 0;
    /* IOServiceGetMatchingServices 会消费（释放）m，之后不能再引用它 */
    if (IOServiceGetMatchingServices(CPERF_MAIN_PORT, m, it_out) != KERN_SUCCESS)
        return 0;
    return 1;
}

static int cmp_u32(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

static void freq_array_finish(uint32_t *arr, int *n, uint32_t *max_out)
{
    if (*n > 1) qsort(arr, (size_t)*n, sizeof(uint32_t), cmp_u32);
    if (max_out && *n > 0) *max_out = arr[*n - 1];
}

/* pmgr 的 voltage-statesN[-sram] 是 CFData：(u32 freq, u32 voltage) 对。
 *
 * 单位随芯片代际变化，这是 M5 上 E/P 表解析出 0 档的主因之一：
 *   M1–M3 : freq 单位是 Hz（2064 MHz → 2_064_000_000）
 *   M4+   : CPU 表改成 kHz，因为 u32 装不下 4.6 GHz 的 Hz 值
 *           （4608 MHz → 4_608_000）
 *   GPU 表 9 在部分机型上是「预计算 Hz」，仍是 Hz。
 * 判别阈值取 1e8：kHz 值最大约 5e6，Hz 值最小约 3e8，中间留了很大空档。
 */
static int parse_dvfs_data(CFDataRef data, uint32_t *out, int cap,
                           int *used_khz_out)
{
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return 0;
    CFIndex len = CFDataGetLength(data);
    const uint8_t *p = CFDataGetBytePtr(data);
    if (!p || len < 8) return 0;
    CFIndex pairs = len / 8;
    if (pairs > 4096) pairs = 4096;

    int n = 0, khz = 0;
    for (CFIndex i = 0; i < pairs; i++) {
        uint32_t freq = 0, volt = 0;
        memcpy(&freq, p + i * 8, 4);
        memcpy(&volt, p + i * 8 + 4, 4);
        if (freq == 0 || volt == 0) continue;
        uint32_t mhz;
        if (freq >= 100000000u) {          /* Hz */
            mhz = freq / 1000000u;
        } else {                            /* kHz */
            mhz = freq / 1000u;
            khz = 1;
        }
        if (mhz < 100 || mhz >= 10000) continue;
        /* 刻意**不去重**：pmgr 表里同一频率可能对应不同电压档（或 OFF 与
         * 最低 P-state 同频），IOReport 的 state 是按索引一一对应的。
         * 去重会让档数变少、索引错位——M5 GPU 表 13 entries 会被压成 12 档，
         * 最低档因此与参考口径不一致。 */
        if (n < cap) out[n++] = mhz;
    }
    if (used_khz_out && khz) *used_khz_out = 1;
    return n;
}

/* 从 "voltage-states22-sram" / "voltage-states5" 里解析编号 N。
 * 不能用 str_ends(kbuf,"-1-sram")：真实键名是 "voltage-states1-sram"，
 * 结尾是 "s1-sram"，永远匹配不上 "-1-sram"，E/P 表会全部漏掉。 */
static int dvfs_key_id(const char *k, int *is_sram)
{
    const char *p = strstr(k, "voltage-states");
    if (!p) return -1;
    p += strlen("voltage-states");
    if (!(*p >= '0' && *p <= '9')) return -1;
    int id = (int)strtol(p, NULL, 10);
    *is_sram = (strstr(p, "-sram") != NULL) ? 1 : 0;
    return id;
}

static void dvfs_add_table(soc_info_t *s, int id, int is_sram,
                           const uint32_t *freqs, int n)
{
    if (n <= 0 || s->table_n >= CPERF_MAX_DVFS_TABLES) return;
    /* 同编号已有 sram 版本时优先保留 sram（频率是预计算好的，最可靠） */
    for (int i = 0; i < s->table_n; i++) {
        if (s->tables[i].id != id) continue;
        if (s->tables[i].is_sram && !is_sram) return;
        if (!s->tables[i].is_sram && is_sram) {
            memcpy(s->tables[i].freqs, freqs, sizeof(uint32_t) * (size_t)n);
            s->tables[i].n = n;
            s->tables[i].is_sram = 1;
            return;
        }
        return;   /* 重复，保留先到的 */
    }
    dvfs_table_t *t = &s->tables[s->table_n++];
    t->id = id;
    t->is_sram = is_sram;
    memcpy(t->freqs, freqs, sizeof(uint32_t) * (size_t)n);
    t->n = n;
}

/* 按 P-state 通道的「频率态数量」挑表。
 * M5 起 Apple 用 `acc-clusters` 动态指定每簇对应哪张表，编号不再是 1/5，
 * 硬编码编号必然失效。而 IOReport 的 ECPU 通道恰好 8 个频率态、
 * PCPU 19 个，与 pmgr 表的档数一一对应，按档数匹配最稳。 */
static const dvfs_table_t *dvfs_pick_cpu_table(const soc_info_t *s, int states_used,
                                               int prefer_high)
{
    const dvfs_table_t *best = NULL;
    int best_score = 1 << 30;
    for (int i = 0; i < s->table_n; i++) {
        const dvfs_table_t *t = &s->tables[i];
        if (t->id == 9 || t->n < 2) continue;         /* 9 是 GPU 表 */
        uint32_t hi = t->freqs[t->n - 1];
        if (hi < 800) continue;                        /* 排除 ANE / IO 低频表 */
        int d = t->n - states_used;
        if (d < 0) d = -d;
        /* prefer_high：P 簇偏向高频表，E 簇偏向低频表 */
        int score = d * 100 + (prefer_high ? -(int)(hi / 100) : (int)(hi / 100));
        if (score < best_score) { best_score = score; best = t; }
    }
    return best;
}

static void read_dvfs_table(soc_info_t *s)
{
    io_iterator_t it = IO_OBJECT_NULL;
    if (!ioreg_iter("AppleARMIODevice", &it)) return;
    io_object_t obj;
    while ((obj = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(obj, &props,
                                              kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFIndex n = CFDictionaryGetCount(props);
            if (n > 0 && n < 4096) {
                const void **keys = calloc((size_t)n, sizeof(void *));
                const void **vals = calloc((size_t)n, sizeof(void *));
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues(props, keys, vals);
                    for (CFIndex i = 0; i < n; i++) {
                        char kbuf[256];
                        cfstr_copy((CFStringRef)keys[i], kbuf, sizeof(kbuf));
                        if (!strstr(kbuf, "voltage-states")) continue;
                        if (CFGetTypeID(vals[i]) != CFDataGetTypeID()) continue;

                        int is_sram = 0;
                        int id = dvfs_key_id(kbuf, &is_sram);
                        if (id < 0) continue;

                        uint32_t tmp[CPERF_MAX_FREQ_STATES];
                        int tn = parse_dvfs_data((CFDataRef)vals[i], tmp,
                                                 CPERF_MAX_FREQ_STATES,
                                                 &s->cpu_table_unit_khz);
                        if (tn <= 0) continue;
                        if (tn > 1) qsort(tmp, (size_t)tn, sizeof(uint32_t), cmp_u32);
                        dvfs_add_table(s, id, is_sram, tmp, tn);
                    }
                }
                free(keys);
                free(vals);
                CFRelease(props);
            }
        }
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);

    /* GPU 表固定编号 9；CPU 表按最高频区分 E（最低）/ P（最高），
     * 运行时 calc_freq 再按频率态数量从表池精确挑表。 */
    const dvfs_table_t *e_tbl = NULL, *p_tbl = NULL;
    uint32_t e_hi = 0xffffffffu, p_hi = 0;
    for (int i = 0; i < s->table_n; i++) {
        const dvfs_table_t *t = &s->tables[i];
        if (t->id == 9) {
            if (s->gpu_freq_n == 0) {
                memcpy(s->gpu_freqs, t->freqs, sizeof(uint32_t) * (size_t)t->n);
                s->gpu_freq_n = t->n;
            }
            continue;
        }
        if (t->n < 2) continue;
        uint32_t hi = t->freqs[t->n - 1];
        if (hi < 800) continue;                 /* 排除 ANE / IO 低频表 */
        if (hi < e_hi) { e_hi = hi; e_tbl = t; }
        if (hi > p_hi) { p_hi = hi; p_tbl = t; }
    }
    if (e_tbl) {
        memcpy(s->e_freqs, e_tbl->freqs, sizeof(uint32_t) * (size_t)e_tbl->n);
        s->e_freq_n = e_tbl->n;
        s->e_freq_max_mhz = e_hi;
    }
    if (p_tbl && p_tbl != e_tbl) {
        memcpy(s->p_freqs, p_tbl->freqs, sizeof(uint32_t) * (size_t)p_tbl->n);
        s->p_freq_n = p_tbl->n;
        s->p_freq_max_mhz = p_hi;
    }
    freq_array_finish(s->gpu_freqs, &s->gpu_freq_n, &s->gpu_freq_max_mhz);
}

static void read_gpu_cores(soc_info_t *s)
{
    io_iterator_t it = IO_OBJECT_NULL;
    if (!ioreg_iter("AGXAccelerator", &it)) return;
    io_object_t obj = IOIteratorNext(it);
    if (obj != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(obj, &props,
                                              kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            const char *candidates[] = { "gpu-core-count", "GPU Core Count",
                                         "gpu-cores", "IOGPUCoreCount" };
            for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
                uint64_t v = cfnum_u64(props, candidates[i]);
                if (v > 0 && v < 1024) { s->gpu_cores = (uint32_t)v; break; }
            }
            CFRelease(props);
        }
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);
}

static void read_soc_info(soc_info_t *s)
{
    memset(s, 0, sizeof(*s));
    read_soc_name(s->soc_name, sizeof(s->soc_name));

    int64_t v = 0;
    if (sysctl_int("hw.nperflevels", &v) == 0 && v > 0 && v < 8)
        s->nperflevels = (uint32_t)v;
    if (sysctl_int("hw.perflevel0.logicalcpu_max", &v) == 0 && v > 0 && v < 128)
        s->p_cores = (uint32_t)v;
    if (s->nperflevels >= 2) {
        if (sysctl_int("hw.perflevel1.logicalcpu_max", &v) == 0 && v > 0 && v < 128)
            s->e_cores = (uint32_t)v;
    } else {
        s->e_cores = 0;
        s->p_cores = 0;   /* Intel / 单簇，不猜测分簇 */
    }

    read_dvfs_table(s);
    read_gpu_cores(s);

    s->apple_silicon = (strstr(s->soc_name, "Apple M") != NULL) || s->nperflevels > 1;
}

/* ------------------------------------------------------------------ */
/* IOReport（私有，动态解析）                                          */
/* ------------------------------------------------------------------ */

typedef struct {
    CFMutableDictionaryRef (*copy_all)(uint64_t, uint64_t);
    CFMutableDictionaryRef (*copy_group)(CFStringRef, CFStringRef,
                                         uint64_t, uint64_t, uint64_t);
    void (*merge)(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef);
    void *(*subscribe)(void *, CFMutableDictionaryRef,
                       CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*samples)(void *, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*get_group)(CFDictionaryRef);
    CFStringRef (*get_subgroup)(CFDictionaryRef);
    CFStringRef (*get_name)(CFDictionaryRef);
    CFStringRef (*get_unit)(CFDictionaryRef);
    int32_t (*get_format)(CFDictionaryRef);
    int64_t (*simple_int)(CFDictionaryRef, int32_t);
    int32_t (*state_count)(CFDictionaryRef);
    CFStringRef (*state_name)(CFDictionaryRef, int32_t);
    int64_t (*state_res)(CFDictionaryRef, int32_t);
    int64_t (*array_val)(CFDictionaryRef, int32_t);
} ior_api_t;

static ior_api_t ior;
static void *g_ior_handle = NULL;
static CFMutableDictionaryRef g_ior_channels = NULL;
static CFMutableDictionaryRef g_ior_subscribed = NULL;
static void *g_ior_subscription = NULL;
static int g_ior_ok = 0;

#define IOR_LOAD(field, sym) do {                                        \
        void *p_ = g_ior_handle ? dlsym(g_ior_handle, sym) : NULL;      \
        memcpy(&(ior.field), &p_, sizeof(p_));                          \
        if (!p_) missing++;                                              \
    } while (0)

static int ior_load_symbols(void)
{
    const char *paths[] = {
        "/usr/lib/libIOReport.dylib",
        "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
        "libIOReport.dylib",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *h = dlopen(paths[i], RTLD_LAZY | RTLD_LOCAL);
        if (h) { g_ior_handle = h; break; }
    }
    /* dyld shared cache 里的库可能已经在全局符号表中 */
    if (!g_ior_handle && dlsym(RTLD_DEFAULT, "IOReportCreateSamples"))
        g_ior_handle = RTLD_DEFAULT;

    memset(&ior, 0, sizeof(ior));
    int missing = 0;
    IOR_LOAD(copy_all,     "IOReportCopyAllChannels");
    IOR_LOAD(copy_group,   "IOReportCopyChannelsInGroup");
    IOR_LOAD(merge,        "IOReportMergeChannels");
    IOR_LOAD(subscribe,    "IOReportCreateSubscription");
    IOR_LOAD(samples,      "IOReportCreateSamples");
    IOR_LOAD(delta,        "IOReportCreateSamplesDelta");
    IOR_LOAD(get_group,    "IOReportChannelGetGroup");
    IOR_LOAD(get_subgroup, "IOReportChannelGetSubGroup");
    IOR_LOAD(get_name,     "IOReportChannelGetChannelName");
    IOR_LOAD(get_unit,     "IOReportChannelGetUnitLabel");
    IOR_LOAD(get_format,   "IOReportChannelGetFormat");
    IOR_LOAD(simple_int,   "IOReportSimpleGetIntegerValue");
    IOR_LOAD(state_count,  "IOReportStateGetCount");
    IOR_LOAD(state_name,   "IOReportStateGetNameForIndex");
    IOR_LOAD(state_res,    "IOReportStateGetResidency");
    IOR_LOAD(array_val,    "IOReportArrayGetValueAtIndex");

    /* 必需集合；copy_group / merge / copy_all / array_val 可缺失（有回退路径） */
    if (!ior.subscribe || !ior.samples || !ior.delta ||
        !ior.get_group || !ior.get_subgroup || !ior.get_name ||
        !ior.get_unit || !ior.get_format || !ior.simple_int ||
        !ior.state_count || !ior.state_name || !ior.state_res) {
        return -1;
    }
    (void)missing;
    return 0;
}

/* 只订阅三组：Energy Model（功耗）、CPU Stats / GPU Stats（P-state）。
 * CLPC / PMP 不整组订阅——CLPC 能量通道来自 AppleCLPC IOKit service 按机型表
 * 逐条构造，不是订阅 "CLPC Stats" 组。
 * 整组订阅会把几十个非能量通道也拉进来，解析时靠宽泛子串匹配就会
 * 重复计数（实测 M5 上匹配到 101 个「能量通道」，功耗虚高 2~3 倍、
 * 峰值虚高 8 倍）。解析阶段再按 ior_channel_allowed 逐条精确过滤。 */
static int ior_build_subscription(void)
{
    CFMutableDictionaryRef merged = NULL;
    const char *groups[] = { "Energy Model", "CPU Stats", "GPU Stats" };

    if (ior.copy_group && ior.merge) {
        for (size_t i = 0; i < sizeof(groups) / sizeof(groups[0]); i++) {
            CFStringRef g = CFStringCreateWithCString(NULL, groups[i],
                                                       kCFStringEncodingUTF8);
            if (!g) continue;
            CFMutableDictionaryRef d = ior.copy_group(g, NULL, 0, 0, 0);
            CFRelease(g);
            if (!d) continue;
            if (!merged) {
                merged = d;
            } else {
                ior.merge(merged, d, NULL);
                CFRelease(d);
            }
        }
    }
    if (!merged && ior.copy_all)
        merged = ior.copy_all(0, 0);
    if (!merged) return -1;

    CFMutableDictionaryRef subscribed = NULL;
    void *sub = ior.subscribe(NULL, merged, &subscribed, 0, NULL);
    if (!sub || !subscribed) {
        CFRelease(merged);
        if (subscribed) CFRelease(subscribed);
        return -1;
    }
    g_ior_channels = merged;
    g_ior_subscribed = subscribed;
    g_ior_subscription = sub;
    return 0;
}

static int ior_init(void)
{
    if (ior_load_symbols() != 0) return -1;
    if (ior_build_subscription() != 0) return -1;
    g_ior_ok = 1;
    return 0;
}

static void ior_shutdown(void)
{
    if (g_ior_subscribed) { CFRelease(g_ior_subscribed); g_ior_subscribed = NULL; }
    if (g_ior_channels)   { CFRelease(g_ior_channels);   g_ior_channels = NULL; }
    /* subscription 是私有不透明类型，不同实现里未必是 CF 对象；
     * 进程生命周期内只创建一次，这里刻意不 release，避免误判导致崩溃。 */
    g_ior_subscription = NULL;
    g_ior_ok = 0;
}

typedef struct {
    char group[64];
    char sub[128];
    char name[160];
    char unit[32];
} ch_meta_t;

static ch_meta_t *g_meta = NULL;
static int g_meta_cap = 0;
static int g_meta_n = 0;

static int meta_ensure(int n)
{
    if (n <= g_meta_cap) return 0;
    int cap = g_meta_cap ? g_meta_cap : 256;
    while (cap < n) cap *= 2;
    ch_meta_t *p = realloc(g_meta, (size_t)cap * sizeof(ch_meta_t));
    if (!p) return -1;
    g_meta = p;
    g_meta_cap = cap;
    return 0;
}

/* 从原始 sample（含元数据）建立 index → (group, sub, name, unit) 映射 */
static int ior_build_metadata(CFDictionaryRef sample)
{
    CFArrayRef arr = channels_array(sample);
    if (!arr) return -1;
    CFIndex n = CFArrayGetCount(arr);
    if (n <= 0 || n > CPERF_MAX_META) return -1;
    if (meta_ensure((int)n) != 0) return -1;
    g_meta_n = (int)n;

    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef raw = CFArrayGetValueAtIndex(arr, i);
        ch_meta_t *m = &g_meta[i];
        memset(m, 0, sizeof(*m));
        if (!raw || CFGetTypeID(raw) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef ch = (CFDictionaryRef)raw;
        cfstr_copy(ior.get_group(ch),    m->group, sizeof(m->group));
        cfstr_copy(ior.get_subgroup(ch), m->sub,   sizeof(m->sub));
        cfstr_copy(ior.get_name(ch),     m->name,  sizeof(m->name));
        cfstr_copy(ior.get_unit(ch),     m->unit,  sizeof(m->unit));
        trim_space(m->unit);
        trim_space(m->group);
        trim_space(m->sub);
        trim_space(m->name);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 逐通道诊断：把「到底哪些通道被算进去了」暴露到 UI 状态栏。           */
/* 数值对不上时不必猜，直接看原始通道名与换算后的 W。                  */
/* ------------------------------------------------------------------ */

/* 双语标记会让每行膨胀约 2~3 倍（中文 + 英文 + key），加上 47 个 HID 传感器、
 * 11 个 P-state 通道、SMC 键读数与 pmgr 表池，6 KiB 会在中途截断，末尾留下
 * 一个缺 \x1e 的半标记 —— Swift 侧正则匹配不上就会显示成乱码 + 中文。 */
#define CPERF_DIAG_CAP 32768
static char g_diag[CPERF_DIAG_CAP];
static pthread_mutex_t g_diag_lock = PTHREAD_MUTEX_INITIALIZER;

static void diag_reset(void)
{
    g_diag[0] = '\0';
}

/* 双语追加：格式串命中文案表时生成中/英两版，输出
 *     \x1eL:<key>\x1f<中文>\x1f<English>
 * 格式串未命中（纯 ASCII 数据行）则原样追加。
 * en 里残留的中文短词（作为 %s 参数传入的「可用 / 不可用」等）由
 * cproc_l10n_inline_en 精确替换。 */
static void diag_append_bilingual_v(char *dst, size_t cap,
                                    const char *fmt, va_list ap)
{
    size_t used = strlen(dst);
    if (used >= cap - 1) return;
    char zh[2048], en[2048], marked[8192];
    const char *ef;
    va_list cp;
    va_copy(cp, ap);
    vsnprintf(zh, sizeof(zh), fmt, cp);
    va_end(cp);

    /* 整段精确译文优先，其次英文格式串，最后才做短词内联替换兜底 */
    const char *whole = cproc_l10n_en_field(zh);
    if (whole) {
        snprintf(en, sizeof(en), "%s", whole);
    } else if ((ef = cproc_l10n_en_fmt(fmt)) != NULL) {
        va_copy(cp, ap);
        vsnprintf(en, sizeof(en), ef, cp);
        va_end(cp);
        cproc_l10n_inline_en(en, sizeof(en));
    } else {
        snprintf(en, sizeof(en), "%s", zh);
    }
    const char *text = zh;
    if (strcmp(zh, en) != 0) {
        const char *key = cproc_l10n_key_fmt(fmt);
        int n = snprintf(marked, sizeof(marked), "\x1eL:%s\x1f%s\x1f%s\x1e",
                         key ? key : "", zh, en);
        /* 只写完整标记。剩余空间不足就整行丢弃：一个缺结尾 \x1e 的半标记
         * Swift 侧正则匹配不上，会把控制字符和中文原样显示出来。 */
        if (n <= 0 || (size_t)n >= sizeof(marked) ||
            (size_t)n + 1 >= cap - used)
            return;
        text = marked;
    }
    snprintf(dst + used, cap - used, "%s", text);
}

static void diag_append_bilingual(char *dst, size_t cap,
                                  const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    diag_append_bilingual_v(dst, cap, fmt, ap);
    va_end(ap);
}

static void diag_add(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    diag_append_bilingual_v(g_diag, CPERF_DIAG_CAP, fmt, ap);
    va_end(ap);
}

/* 采样线程内调用；Swift 侧拷贝时加锁 */
const char *cproc_perf_diagnostics(void)
{
    static char out[CPERF_DIAG_CAP];
    pthread_mutex_lock(&g_diag_lock);
    snprintf(out, sizeof(out), "%s", g_diag);
    pthread_mutex_unlock(&g_diag_lock);
    return out;
}

static double energy_to_watts(int64_t v, const char *unit, double seconds)
{
    if (seconds <= 0.0001 || v <= 0) return 0.0;
    double d = (double)v / seconds;
    if (strcmp(unit, "mJ") == 0)        return d / 1e3;
    if (strcmp(unit, "uJ") == 0 ||
        strcmp(unit, "µJ") == 0)        return d / 1e6;
    if (strcmp(unit, "nJ") == 0)        return d / 1e9;
    if (strcmp(unit, "J") == 0)         return d;
    /* unit label 缺失时按 Energy Model 的 mJ 处理 */
    if (unit[0] == '\0')                return d / 1e3;
    return 0.0;
}

/* residency 数组的前导状态名，用精确相等判断，不用子串，
 * 否则 "IDLE-2" 之类会被误判。 */
static int state_is_leading(const char *n)
{
    char b[64];
    snprintf(b, sizeof(b), "%s", n);
    trim_space(b);
    return strcmp(b, "IDLE") == 0 || strcmp(b, "DOWN") == 0 ||
           strcmp(b, "OFF")  == 0 || strcmp(b, "SLEEP") == 0 ||
           strcmp(b, "PARKED") == 0;
}

/* 从 state 名里抓第一个整数当 MHz（老款通道名直接带 "2064MHz" 时用） */
static double state_mhz(const char *n)
{
    const char *p = n;
    while (*p && !(*p >= '0' && *p <= '9')) p++;
    if (*p == '\0') return 0.0;
    double v = strtod(p, NULL);
    return (v > 50.0 && v < 10000.0) ? v : 0.0;
}

/* 按同一口径实现的 P-state residency 加权频率计算：
 *   residency = [IDLE/DOWN/OFF..., f0, f1, ..., fn]
 *   offset    = 第一个非前导状态的索引
 *   usage     = Σ residency[offset .. offset+len(freqs)]   ← take(freqs.len())
 *   avg_freq  = Σ (residency[offset+i] / usage) * freqs[i]  ← 索引直接对应
 *   active    = usage / Σ全部 residency
 * 前提是 items.len() > freqs.len()，即频率态数不少于频率表档数。
 *
 * 「第一个 active state 对应最低频表项」是 Apple IOReport 的约定
 * （V0P7/V1P6…、P1/P2… 这类编号态都是降序/升序索引，不看名字）。
 * 若改成 used=cnt-offset + 索引拉伸，GPU 频率会偏高（338 → 486 MHz）；
 * 按 take(freqs.len()) 才能与参考口径一致。 */
static int calc_freq(CFDictionaryRef item,
                     const uint32_t *freqs, int nfreq,
                     double *avg_mhz, double *active_ratio, double *usage_out,
                     const char *label)
{
    *avg_mhz = 0.0; *active_ratio = 0.0; *usage_out = 0.0;
    int cnt = ior.state_count(item);
    if (cnt <= 0 || cnt > 4096) return 0;

    int offset = 0;
    while (offset < cnt) {
        char st[128];
        cfstr_copy(ior.state_name(item, offset), st, sizeof(st));
        if (!state_is_leading(st)) break;
        offset++;
    }
    if (offset >= cnt) return 0;

    int nstates = cnt - offset;
    if (nstates <= 0) return 0;

    double total = 0.0;
    for (int j = 0; j < cnt; j++) {
        int64_t r = ior.state_res(item, j);
        if (r > 0) total += (double)r;
    }
    if (total <= 0) return 0;

    /* 有表时按表档数取前 nfreq 个频率态；无表时取全部，靠 state 名解析 */
    int used = (nfreq > 0 && nfreq < nstates) ? nfreq : nstates;
    double usage = 0.0;
    for (int i = 0; i < used; i++) {
        int64_t r = ior.state_res(item, offset + i);
        if (r > 0) usage += (double)r;
    }

    if (usage > 0 && nfreq > 0) {
        double avg = 0.0;
        for (int i = 0; i < used && i < nfreq; i++) {
            int64_t r = ior.state_res(item, offset + i);
            if (r > 0) avg += ((double)r / usage) * (double)freqs[i];
        }
        *avg_mhz = avg;
    } else if (usage > 0) {
        /* 兜底：pmgr 表完全缺失时，试从 state 名解析 MHz */
        double sum = 0.0, wsum = 0.0;
        for (int i = 0; i < used; i++) {
            char st[128];
            cfstr_copy(ior.state_name(item, offset + i), st, sizeof(st));
            double f = state_mhz(st);
            int64_t r = ior.state_res(item, offset + i);
            if (f > 0 && r > 0) { sum += f * (double)r; wsum += (double)r; }
        }
        if (wsum > 0) *avg_mhz = sum / wsum;
    }

    *active_ratio = usage / total;
    *usage_out = usage;

    if (label) {
        char names[256] = { 0 };
        size_t u = 0;
        for (int i = 0; i < nstates && i < 4 && u < sizeof(names) - 1; i++) {
            char st[128];
            cfstr_copy(ior.state_name(item, offset + i), st, sizeof(st));
            int k = snprintf(names + u, sizeof(names) - u, "%s%s",
                             i ? "," : "", st);
            if (k > 0) u += (size_t)k;
        }
        diag_add("  %-22s states=%d off=%d states_used=%d table=%d f0=%u fN=%u [%s] → %.0fMHz act=%.1f%%\n",
                 label, cnt, offset, nstates, nfreq,
                 nfreq > 0 ? freqs[0] : 0,
                 nfreq > 0 ? freqs[used - 1] : 0,
                 names, *avg_mhz, *active_ratio * 100.0);
    }
    return 1;
}

/* CPU tier 索引：0=ECPU, 1=MCPU/SCPU（中间簇）, 2=PCPU */
static int cpu_tier_of(const char *channel)
{
    if (strstr(channel, "ECPU") || strstr(channel, "E-CPU")) return 0;
    if (strstr(channel, "MCPU") || strstr(channel, "SCPU") ||
        strstr(channel, "S-CPU")) return 1;
    if (strstr(channel, "PCPU") || strstr(channel, "P-CPU")) return 2;
    return -1;
}

/* Energy Model / P-state 通道的精确过滤规则（与参考口径一致）：
 *   Energy Model: GPU Energy / *CPU Energy / ANE* / DRAM* / GPU SRAM*
 *   CPU Stats   : subgroup == "CPU Core Performance States"
 *   GPU Stats   : subgroup == "GPU Performance States"
 * 订阅阶段按组拉全量，解析阶段用这里逐条过滤。若用
 * strstr(group,"Energy") / strstr(name,"CPU") 之类的宽泛匹配，
 * 会把上百个无关通道也算成能量，功耗虚高 2~3 倍。 */
static int ior_channel_allowed(const ch_meta_t *m)
{
    if (strcmp(m->group, "Energy Model") == 0) {
        return strcmp(m->name, "GPU Energy") == 0 ||
               str_ends(m->name, "CPU Energy")   ||
               str_starts(m->name, "ANE")        ||
               str_starts(m->name, "DRAM")       ||
               str_starts(m->name, "GPU SRAM");
    }
    if (strcmp(m->group, "CPU Stats") == 0)
        return strcmp(m->sub, "CPU Core Performance States") == 0;
    if (strcmp(m->group, "GPU Stats") == 0)
        return strcmp(m->sub, "GPU Performance States") == 0;
    return 0;
}

typedef struct {
    double power[4];                  /* 0=CPU 1=GPU 2=ANE 3=DRAM */
    int    energy_n, energy_diag_n;

    /* 每个通道先算自己的频率与活跃占比，再等权平均。
     * usage 跨通道累加、gpu_freq 直接 += avg 都会让多通道时频率成倍放大
     * （例如 GPU 972 MHz vs 真实 338 MHz），必须逐通道先算再等权平均。 */
    double tier_freq_sum[3], tier_act_sum[3];
    int    tier_n[3];

    double cpu_freq_sum, cpu_act_sum;
    double gpu_freq_sum, gpu_act_sum;
    int    cpu_state_n, gpu_state_n, state_diag_n;
} ior_accum_t;

/* 与 calc_freq 里的 offset 逻辑一致，用于选表 */
static int count_freq_states(CFDictionaryRef item)
{
    int cnt = ior.state_count(item);
    if (cnt <= 0 || cnt > 4096) return 0;
    int off = 0;
    while (off < cnt) {
        char st[128];
        cfstr_copy(ior.state_name(item, off), st, sizeof(st));
        if (!state_is_leading(st)) break;
        off++;
    }
    return cnt - off;
}

static void ior_accum_item(ior_accum_t *a, const ch_meta_t *m,
                           CFDictionaryRef item, double seconds)
{
    if (!ior_channel_allowed(m)) return;
    int fmt = ior.get_format(item);

    /* ---- 能量通道（只认 Energy Model） ---- */
    if (fmt == IOR_FORMAT_SIMPLE) {
        double w = energy_to_watts(ior.simple_int(item, 0), m->unit, seconds);
        if (w <= 0) return;
        a->energy_n++;
        if (strcmp(m->name, "GPU Energy") == 0 ||
            str_starts(m->name, "GPU SRAM"))       a->power[1] += w;
        else if (str_ends(m->name, "CPU Energy"))   a->power[0] += w;
        else if (str_starts(m->name, "ANE"))        a->power[2] += w;
        else if (str_starts(m->name, "DRAM"))       a->power[3] += w;

        if (a->energy_diag_n < 16) {
            diag_add("  EM %-38s unit=%-4s → %.3f W\n",
                     m->name, m->unit[0] ? m->unit : "?", w);
            a->energy_diag_n++;
        }
        return;
    }

    /* ---- P-state residency ---- */
    if (fmt != IOR_FORMAT_STATE) return;
    int is_cpu = strcmp(m->group, "CPU Stats") == 0;
    int is_gpu = strcmp(m->group, "GPU Stats") == 0;
    if (!is_cpu && !is_gpu) return;

    if (a->state_diag_n >= 14) return;   /* 诊断上限，不影响聚合 */

    if (is_gpu) {
        /* GPU 频率表去掉最低一档（macmon 用 gpu_freqs[1..]） */
        const uint32_t *f = g_soc.gpu_freqs;
        int nf = g_soc.gpu_freq_n;
        if (nf > 1) { f += 1; nf -= 1; }
        double avg = 0, act = 0, usage = 0;
        if (calc_freq(item, f, nf, &avg, &act, &usage, m->name)) {
            a->gpu_freq_sum += avg;
            a->gpu_act_sum  += act;
            a->gpu_state_n++;
            a->state_diag_n++;
        }
        return;
    }

    /* CPU：按通道名前缀分到 E / M / P 三个 tier，再按「频率态数量」
     * 从 pmgr 表池挑表。M5 起编号不再固定（acc-clusters 动态指定），
     * 但 ECPU 恰好 8 个频率态、PCPU 19 个，与表档数一一对应。 */
    int tier = cpu_tier_of(m->name);
    const uint32_t *freqs = NULL;
    int nf = 0;
    int nstates = count_freq_states(item);
    const dvfs_table_t *tbl = NULL;
    if (tier == 0)      tbl = dvfs_pick_cpu_table(&g_soc, nstates, 0);  /* E 偏低频 */
    else if (tier == 2) tbl = dvfs_pick_cpu_table(&g_soc, nstates, 1);  /* P 偏高频 */
    else if (tier == 1) tbl = dvfs_pick_cpu_table(&g_soc, nstates, 0);
    else                tbl = dvfs_pick_cpu_table(&g_soc, nstates, 0);
    if (tbl) { freqs = tbl->freqs; nf = tbl->n; }

    double avg = 0, act = 0, usage = 0;
    if (!calc_freq(item, freqs, nf, &avg, &act, &usage, m->name)) return;

    a->cpu_freq_sum += avg;
    a->cpu_act_sum  += act;
    a->cpu_state_n++;
    a->state_diag_n++;

    if (tier >= 0 && tier < 3) {
        a->tier_freq_sum[tier] += avg;
        a->tier_act_sum[tier]  += act;
        a->tier_n[tier]++;
    }
}

static void ior_parse_delta(CFDictionaryRef delta, double seconds,
                            cproc_perf_values_t *out)
{
    CFArrayRef arr = channels_array(delta);
    if (!arr) return;
    CFIndex n = CFArrayGetCount(arr);
    if (n > g_meta_n) n = g_meta_n;

    ior_accum_t a;
    memset(&a, 0, sizeof(a));

    diag_add("[IOReport] delta 通道 %ld，精确过滤后：\n", (long)n);
    diag_add("[pmgr] %d 张表，CPU 表单位=%s，GPU 表 %d 档(%u..%u)：\n",
             g_soc.table_n,
             g_soc.cpu_table_unit_khz ? "kHz(M4+)" : "Hz",
             g_soc.gpu_freq_n,
             g_soc.gpu_freq_n ? g_soc.gpu_freqs[0] : 0,
             g_soc.gpu_freq_n ? g_soc.gpu_freqs[g_soc.gpu_freq_n - 1] : 0);
    for (int i = 0; i < g_soc.table_n && i < 20; i++) {
        const dvfs_table_t *t = &g_soc.tables[i];
        diag_add("  table%-3d %-5s %2d 档 %u..%u MHz\n",
                 t->id, t->is_sram ? "sram" : "core", t->n,
                 t->n ? t->freqs[0] : 0,
                 t->n ? t->freqs[t->n - 1] : 0);
    }

    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef raw = CFArrayGetValueAtIndex(arr, i);
        if (!raw || CFGetTypeID(raw) != CFDictionaryGetTypeID()) continue;
        ior_accum_item(&a, &g_meta[i], (CFDictionaryRef)raw, seconds);
    }

    out->matched_energy_channels = (uint32_t)a.energy_n;
    out->matched_state_channels  = (uint32_t)(a.cpu_state_n + a.gpu_state_n);

    if (a.energy_n > 0) {
        out->cpu_power_w  = a.power[0];
        out->gpu_power_w  = a.power[1];
        out->ane_power_w  = a.power[2];
        out->dram_power_w = a.power[3];
        out->soc_power_w  = a.power[0] + a.power[1] + a.power[2] + a.power[3];
        out->power_source = 2;                 /* Energy Model（不再用 CLPC 整组） */
        out->valid |= CPERF_VALID_POWER;
    }

    if (a.cpu_state_n > 0) {
        out->cpu_active_ratio = a.cpu_act_sum / a.cpu_state_n;
        out->cpu_freq_mhz     = a.cpu_freq_sum / a.cpu_state_n;
        out->valid |= CPERF_VALID_RESIDENCY;
        if (out->cpu_freq_mhz > 0) out->valid |= CPERF_VALID_FREQ;
    }
    if (a.gpu_state_n > 0) {
        out->gpu_active_ratio = a.gpu_act_sum / a.gpu_state_n;
        out->gpu_freq_mhz     = a.gpu_freq_sum / a.gpu_state_n;
        if (out->gpu_freq_mhz > 0) out->valid |= CPERF_VALID_FREQ;
    }

    int tiers = 0;
    for (int t = 0; t < 3; t++) {
        if (a.tier_n[t] <= 0) continue;
        tiers++;
        double f = a.tier_freq_sum[t] / a.tier_n[t];
        double r = a.tier_act_sum[t]  / a.tier_n[t];
        if (t == 0) { out->e_freq_mhz = f; out->e_active_ratio = r; }
        if (t == 1) { out->m_freq_mhz = f; out->m_active_ratio = r; }
        if (t == 2) { out->p_freq_mhz = f; out->p_active_ratio = r; }
    }
    if (tiers > 0) {
        out->tier_count = (uint32_t)tiers;
        out->valid |= CPERF_VALID_TIERS;
    }
}

/* ------------------------------------------------------------------ */
/* AppleSMC：温度 / 系统功率 / 风扇                                     */
/* ------------------------------------------------------------------ */

static io_connect_t g_smc_conn = IO_OBJECT_NULL;
static int g_smc_ok = 0;
static int g_notify_token = -1;

static int smc_open(void)
{
    CFMutableDictionaryRef m = IOServiceMatching("AppleSMC");
    if (!m) return -1;
    io_service_t svc = IOServiceGetMatchingService(CPERF_MAIN_PORT, m);
    if (svc == IO_OBJECT_NULL) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_smc_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) return -1;
    g_smc_ok = 1;
    return 0;
}

static void smc_close(void)
{
    if (g_smc_ok && g_smc_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_smc_conn);
        g_smc_conn = IO_OBJECT_NULL;
    }
    g_smc_ok = 0;
}

static int smc_call(const uint8_t in[CPERF_SMC_STRUCT_SZ],
                    uint8_t out[CPERF_SMC_STRUCT_SZ])
{
    size_t outsz = CPERF_SMC_STRUCT_SZ;
    kern_return_t kr = IOConnectCallStructMethod(g_smc_conn, 2, in,
                                                 CPERF_SMC_STRUCT_SZ,
                                                 out, &outsz);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static int smc_decode(const uint8_t bytes[32], uint32_t type, uint32_t size,
                      double *out)
{
    if (size == 0 || size > 32) return -1;
    uint16_t be16 = (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
    uint32_t be32 = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
                    ((uint32_t)bytes[2] << 8)  | (uint32_t)bytes[3];

    if (type == fourcc("flt ")) {
        float f = 0.0f;
        memcpy(&f, bytes, sizeof(f));
        *out = (double)f;
        return 0;
    }
    if (type == fourcc("ui8 ")) { *out = bytes[0]; return 0; }
    if (type == fourcc("si8 ")) { *out = (double)(int8_t)bytes[0]; return 0; }
    if (type == fourcc("ui16")) { *out = be16; return 0; }
    if (type == fourcc("ui32")) { *out = be32; return 0; }
    if (type == fourcc("sp78")) { *out = (double)(int16_t)be16 / 256.0; return 0; }
    if (type == fourcc("fpe2")) { *out = (double)(be16 >> 2); return 0; }
    return -1;
}

static int smc_read(const char *key4, double *value, uint32_t *type_out)
{
    if (!g_smc_ok || !key4 || strlen(key4) < 4) return -1;
    uint8_t in[CPERF_SMC_STRUCT_SZ]  = { 0 };
    uint8_t out[CPERF_SMC_STRUCT_SZ] = { 0 };

    put_u32(in + SMC_OFF_KEY, fourcc(key4));
    in[SMC_OFF_DATA8] = CPERF_SMC_GET_INFO;
    if (smc_call(in, out) != 0) return -1;
    uint32_t size = get_u32(out + SMC_OFF_DATASIZE);
    uint32_t type = get_u32(out + SMC_OFF_DATATYPE);
    if (size == 0 || size > 32) return -1;

    memset(in, 0, sizeof(in));
    put_u32(in + SMC_OFF_KEY, fourcc(key4));
    memcpy(in + SMC_OFF_DATASIZE, out + SMC_OFF_DATASIZE, 12);  /* keyInfo */
    in[SMC_OFF_DATA8] = CPERF_SMC_READ;
    memset(out, 0, sizeof(out));
    if (smc_call(in, out) != 0) return -1;
    if (out[SMC_OFF_RESULT] != 0) return -1;

    if (smc_decode(out + SMC_OFF_BYTES, type, size, value) != 0) return -1;
    if (type_out) *type_out = type;
    return 0;
}

static int smc_key_at_index(uint32_t idx, char key[5])
{
    if (!g_smc_ok) return -1;
    uint8_t in[CPERF_SMC_STRUCT_SZ]  = { 0 };
    uint8_t out[CPERF_SMC_STRUCT_SZ] = { 0 };
    in[SMC_OFF_DATA8] = CPERF_SMC_FROM_IDX;
    put_u32(in + SMC_OFF_DATA32, idx);
    if (smc_call(in, out) != 0) return -1;
    fourcc_str(get_u32(out + SMC_OFF_KEY), key);
    return 0;
}

/* #KEY 的 data_type 在不同机型上不统一（未必是 ui32），通用 decode 会失败，
 * 因此直接读 bytes[0..4] 的大端 u32。 */
static int smc_num_keys(uint32_t *out)
{
    if (!g_smc_ok) return -1;
    uint8_t in[CPERF_SMC_STRUCT_SZ]  = { 0 };
    uint8_t info[CPERF_SMC_STRUCT_SZ] = { 0 };
    put_u32(in + SMC_OFF_KEY, fourcc("#KEY"));
    in[SMC_OFF_DATA8] = CPERF_SMC_GET_INFO;
    if (smc_call(in, info) != 0) return -1;
    uint32_t size = get_u32(info + SMC_OFF_DATASIZE);
    if (size == 0 || size > 32) return -1;

    uint8_t rd[CPERF_SMC_STRUCT_SZ]  = { 0 };
    uint8_t val[CPERF_SMC_STRUCT_SZ] = { 0 };
    put_u32(rd + SMC_OFF_KEY, fourcc("#KEY"));
    memcpy(rd + SMC_OFF_DATASIZE, info + SMC_OFF_DATASIZE, 12);
    rd[SMC_OFF_DATA8] = CPERF_SMC_READ;
    if (smc_call(rd, val) != 0 || val[SMC_OFF_RESULT] != 0) return -1;

    const uint8_t *b = val + SMC_OFF_BYTES;
    uint32_t n = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                 ((uint32_t)b[2] << 8)  | (uint32_t)b[3];
    /* 兜底：也试一次通用解码，取两者里合理的那个 */
    double v = 0;
    if ((n == 0 || n > CPERF_SMC_MAX_KEYS()) &&
        smc_read("#KEY", &v, NULL) == 0 && v > 0 && v <= CPERF_SMC_MAX_KEYS())
        n = (uint32_t)v;
    /* 上限不能写成 1024：Apple Silicon 的 SMC 普遍有 3000+ 个键
     * （M4/M5 约 3246，其中约 320 个温度键），#KEY 返回 3246 会被判为失败，
     * 导致 T/F 开头的键枚举出 0 个、温度回退到 IOHID；而 M5 上没有
     * pACC MTR Temp Sensor，温度就会整栏显示「—」。 */
    if (n == 0 || n > CPERF_SMC_MAX_KEYS()) return -1;
    *out = n;
    return 0;
}

/* ------------------------------------------------------------------ */
/* IOHIDEventSystem 温度兜底（SMC 键受限的机型走这条路径）  */
/* ------------------------------------------------------------------ */

#define CPERF_HID_TEMP_TYPE   15
#define CPERF_HID_TEMP_FIELD  (15LL << 16)

typedef struct {
    void *(*client_create)(CFAllocatorRef);
    int   (*set_matching)(void *, CFDictionaryRef);
    CFArrayRef (*copy_services)(void *);
    CFStringRef (*copy_property)(void *, CFStringRef);
    void *(*copy_event)(void *, int64_t, int32_t, int64_t);
    double (*event_float)(void *, int64_t);
} hid_api_t;

static hid_api_t hid;
static void *g_hid_client = NULL;   /* 私有不透明对象，只创建一次，不 release */

static void hid_load(void)
{
    memset(&hid, 0, sizeof(hid));
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                     RTLD_LAZY | RTLD_LOCAL);
    if (!h) h = RTLD_DEFAULT;
#define HID_LOAD(field, sym) do {                                   \
        void *p_ = dlsym(h, sym);                                   \
        if (p_) memcpy(&(hid.field), &p_, sizeof(p_));              \
    } while (0)
    HID_LOAD(client_create, "IOHIDEventSystemClientCreate");
    HID_LOAD(set_matching,  "IOHIDEventSystemClientSetMatching");
    HID_LOAD(copy_services, "IOHIDEventSystemClientCopyServices");
    HID_LOAD(copy_property, "IOHIDServiceClientCopyProperty");
    HID_LOAD(copy_event,    "IOHIDServiceClientCopyEvent");
    HID_LOAD(event_float,   "IOHIDEventGetFloatValue");
#undef HID_LOAD
    /* 刻意不 dlclose：已解析的函数指针仍指向该映像，卸载反而危险 */
}

typedef struct {
    double cpu_sum, gpu_sum, all_max;
    int    cpu_n, gpu_n;
    double pmu_sum;          /* M4/M5 的 PMU tdie 传感器单独累计 */
    int    pmu_n;
    int    pmu_used;         /* 最终是否用了 PMU 值（UI 需要标注口径） */
} temp_accum_t;

static void hid_sample_temps(temp_accum_t *t)
{
    if (!hid.client_create || !hid.copy_services ||
        !hid.copy_property || !hid.copy_event || !hid.event_float) return;

    if (!g_hid_client) {
        g_hid_client = hid.client_create(kCFAllocatorDefault);
        if (!g_hid_client) return;

        /* 只设置一次匹配字典：PrimaryUsagePage=0xff00 / PrimaryUsage=0x05
         * 是 Apple 私有 HID 温度传感器的 usage 对。 */
        if (hid.set_matching) {
            CFStringRef k1 = CFStringCreateWithCString(NULL, "PrimaryUsagePage",
                                                        kCFStringEncodingUTF8);
            CFStringRef k2 = CFStringCreateWithCString(NULL, "PrimaryUsage",
                                                        kCFStringEncodingUTF8);
            if (k1 && k2) {
                int page = 0xff00, usage = 0x05;
                CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberIntType, &page);
                CFNumberRef n2 = CFNumberCreate(NULL, kCFNumberIntType, &usage);
                if (n1 && n2) {
                    CFMutableDictionaryRef match =
                        CFDictionaryCreateMutable(NULL, 0,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
                    if (match) {
                        CFDictionarySetValue(match, k1, n1);
                        CFDictionarySetValue(match, k2, n2);
                        (void)hid.set_matching(g_hid_client, match);
                        CFRelease(match);
                    }
                }
                if (n1) CFRelease(n1);
                if (n2) CFRelease(n2);
            }
            if (k1) CFRelease(k1);
            if (k2) CFRelease(k2);
        }
    }

    CFArrayRef services = hid.copy_services(g_hid_client);
    if (!services || CFGetTypeID(services) != CFArrayGetTypeID()) return;

    CFStringRef pk = CFStringCreateWithCString(NULL, "Product",
                                                kCFStringEncodingUTF8);
    CFIndex cnt = CFArrayGetCount(services);
    if (cnt > 4096) cnt = 4096;
    diag_add("[IOHID] services=%ld\n", (long)cnt);
    int shown = 0;
    for (CFIndex i = 0; i < cnt; i++) {
        const void *raw = CFArrayGetValueAtIndex(services, i);
        if (!raw) continue;
        void *svc = (void *)raw;

        char product[256] = { 0 };
        if (pk) {
            CFStringRef pname = hid.copy_property(svc, pk);
            if (pname) {
                cfstr_copy(pname, product, sizeof(product));
                CFRelease(pname);
            }
        }

        void *ev = hid.copy_event(svc, CPERF_HID_TEMP_TYPE, 0, 0);
        if (!ev) continue;
        double temp = hid.event_float(ev, CPERF_HID_TEMP_FIELD);
        CFRelease((CFTypeRef)ev);
        if (temp <= 0.0 || temp > 150.0) continue;

        if (shown < 16) { diag_add("  HID %-44s %.1f°C\n", product, temp); shown++; }
        if (temp > t->all_max) t->all_max = temp;

        /* 机型代际不同，传感器命名完全不同：
         *   M1/M2 : pACC/eACC MTR Temp Sensor、GPU MTR Temp Sensor（真正核心热点）
         *   M4/M5 : 只有 PMU tdie 系列（供电 IC 自身 die 温度），
         *           PMU tcal 是校正参考值（实测 51.8°C 常被误当 CPU 温度），
         *           tdev 系列、NAND、battery 是周边，一律排除。
         * macOS 14+ 主用 SMC 的 Tp/Te 系列键，IOHID 只是兜底；
         * M5 上走 SMC，PMU 仅在真正拿不到 SMC 时启用，
         * 并单独标记 CPERF_TEMP_PMU 让 UI 说明「非核心热点、绝对值偏低」。 */
        if (str_starts(product, "GPU MTR Temp Sensor")) {
            t->gpu_sum += temp; t->gpu_n++;
        } else if (str_starts(product, "pACC MTR Temp Sensor") ||
                   str_starts(product, "eACC MTR Temp Sensor") ||
                   str_starts(product, "mACC MTR Temp Sensor")) {
            t->cpu_sum += temp; t->cpu_n++;
        } else if (str_starts(product, "PMU tdie") ||
                   str_starts(product, "PMU2 tdie")) {
            t->pmu_sum += temp; t->pmu_n++;
        }
        /* 其余传感器只写进诊断，不参与 CPU/GPU 平均 */
    }
    if (pk) CFRelease(pk);
    CFRelease(services);
    /* g_hid_client 是私有不透明对象，刻意不 release，避免误判类型导致崩溃 */
}

static void smc_sample(cproc_perf_values_t *p)
{
    if (g_smc_ok) {
        double sysp = 0;
        if (smc_read("PSTR", &sysp, NULL) == 0 && sysp > 0 && sysp < 1000) {
            p->sys_power_w = sysp;
            p->valid |= CPERF_VALID_SYS_POWER;
        }
    }

    temp_accum_t t;
    memset(&t, 0, sizeof(t));

    /* SMC 键列表只枚举一次并缓存：#KEY 有 3000+ 个，每帧全量枚举
     * 会产生上千次 IOConnectCallStructMethod，1 秒采样下开销不可接受。
     * 数组要能容纳约 320 个 T* 键，#KEY 上限也不能设成 1024。 */
    static char g_temp_keys[CPERF_SMC_TEMP_KEYS][5];
    static char g_fan_keys[CPERF_SMC_FAN_KEYS][5];
    static int  g_temp_key_n = -1;   /* -1 = 尚未枚举 */
    static int  g_fan_key_n = 0;
    static uint32_t g_smc_key_count = 0;

    if (g_smc_ok && g_temp_key_n < 0) {
        g_temp_key_n = 0;
        g_fan_key_n = 0;
        uint32_t num = 0;
        if (smc_num_keys(&num) == 0) {
            g_smc_key_count = num;
            for (uint32_t i = 0; i < num; i++) {
                char key[5];
                if (smc_key_at_index(i, key) != 0) continue;
                if (key[0] == 'T' && g_temp_key_n < CPERF_SMC_TEMP_KEYS) {
                    memcpy(g_temp_keys[g_temp_key_n++], key, 5);
                } else if (key[0] == 'F' && g_fan_key_n < CPERF_SMC_FAN_KEYS) {
                    memcpy(g_fan_keys[g_fan_key_n++], key, 5);
                }
            }
        }
    }

    /* 路径 1：AppleSMC 键，按前缀分 CPU / GPU。
     *   Tp* / Te* / Ts* → CPU，Tg* → GPU，F* → 风扇 */
    int smc_temp_ok = 0;
    int smc_valid_reads = 0, diag_classified = 0, diag_other = 0;
    diag_add("[SMC] open=%d #KEY=%u 枚举到 T* 键=%d F* 键=%d\n",
             g_smc_ok, g_smc_key_count,
             g_temp_key_n > 0 ? g_temp_key_n : 0, g_fan_key_n);
    if (g_smc_ok && g_temp_key_n > 0) {
        for (int i = 0; i < g_temp_key_n; i++) {
            const char *key = g_temp_keys[i];
            double v = 0;
            if (smc_read(key, &v, NULL) != 0) continue;
            if (v <= 0 || v > 150) continue;

            int is_gpu = (strncmp(key, "Tg", 2) == 0);
            int is_cpu = (strncmp(key, "Tp", 2) == 0 ||
                          strncmp(key, "Te", 2) == 0 ||
                          strncmp(key, "Ts", 2) == 0);
            int classified = is_gpu || is_cpu;

            /* 优先打印真正参与 CPU/GPU 平均的键并打标记，其余只补 4 个样本。
             * 若按枚举顺序只打前 16 个，通常全是 TCHP/TCMb 之类，
             * 看不到 Tp/Tg 键，无法核对温度读数来自哪几个传感器。 */
            if ((classified && diag_classified < 12) ||
                (!classified && diag_other < 4)) {
                diag_add("  SMC %s = %.1f°C%s\n", key, v,
                         is_gpu ? " [GPU]" : is_cpu ? " [CPU]" : "");
                if (classified) diag_classified++; else diag_other++;
            }
            smc_valid_reads++;
            if (v > t.all_max) t.all_max = v;

            /* smc_temp_ok 只在真的归类到 CPU/GPU 时才置位。
             * 只有真正归类到 CPU/GPU 才置位：若某机型全是 TCHP/TCMb
             * 这类非归类键，对任何有效读数都置位会「不显示 SMC 温度」又
             * 「阻止 IOHID 回退」，温度永远显示「不可用」。 */
            if (is_gpu)      { t.gpu_sum += v; t.gpu_n++; smc_temp_ok = 1; }
            else if (is_cpu) { t.cpu_sum += v; t.cpu_n++; smc_temp_ok = 1; }
        }

        double fan_max = 0;
        int fan_n = 0;
        for (int i = 0; i < g_fan_key_n; i++) {
            double v = 0;
            if (smc_read(g_fan_keys[i], &v, NULL) != 0) continue;
            if (v > 0 && v < 20000) { if (v > fan_max) fan_max = v; fan_n++; }
        }
        if (fan_n > 0) {
            p->fan_rpm = fan_max;
            p->valid |= CPERF_VALID_FAN;
        }
    }
    diag_add("[SMC] 有效温度读数=%d 归类 CPU=%d GPU=%d\n",
             smc_valid_reads, t.cpu_n, t.gpu_n);

    /* 路径 2：SMC 没给温度时走 IOHID。M1/M2 有真正的核心传感器，
     * M4/M5 只剩 PMU tdie，后者单独累计，只有核心传感器一个都没有时才启用，
     * 并置 CPERF_TEMP_PMU 让 UI 明确标注「非核心热点、绝对值偏低」。 */
    if (!smc_temp_ok) {
        int before_cpu = t.cpu_n, before_gpu = t.gpu_n;
        hid_sample_temps(&t);
        diag_add("[IOHID] 核心 CPU=%d GPU=%d PMU=%d（其余只记录不参与平均）\n",
                 t.cpu_n - before_cpu, t.gpu_n - before_gpu, t.pmu_n);
        if (t.cpu_n == 0 && t.pmu_n > 0) {
            t.cpu_sum = t.pmu_sum;
            t.cpu_n   = t.pmu_n;
            t.pmu_used = 1;
            diag_add("[IOHID] 无核心传感器，改用 PMU tdie 平均（非核心热点）\n");
        }
    }

    /* 只用明确归类的传感器。在 cpu_n==0 时把「所有传感器最大值」当成
     * CPU 温度，会读到 51.8°C 这类 PMU tcal 值。 */
    int any = t.cpu_n + t.gpu_n > 0;
    if (any) {
        if (t.cpu_n > 0) p->cpu_temp_c = t.cpu_sum / t.cpu_n;
        if (t.gpu_n > 0) p->gpu_temp_c = t.gpu_sum / t.gpu_n;
        p->max_temp_c = t.all_max;
        p->temp_source = smc_temp_ok ? CPERF_TEMP_SMC :
                         t.pmu_used  ? CPERF_TEMP_PMU : CPERF_TEMP_HID;
        p->valid |= CPERF_VALID_TEMP;
    }
}

/* ------------------------------------------------------------------ */
/* 公开层计数器                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    uint64_t cpu_user, cpu_sys, cpu_idle, cpu_nice;
    uint64_t core_busy[CPERF_MAX_CORES];
    uint64_t core_total[CPERF_MAX_CORES];
    int      core_n;
    uint64_t disk_read, disk_write, disk_ops;
    uint64_t net_in, net_out;
    uint64_t mem_used, mem_total, mem_wired, mem_compressed;
    uint64_t swap_used, swap_total;
} counters_t;

static counters_t g_prev;
static int g_prev_valid = 0;

static void read_cpu_ticks(counters_t *c)
{
    host_cpu_load_info_data_t l;
    memset(&l, 0, sizeof(l));
    mach_msg_type_number_t cnt = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                        (host_info_t)&l, &cnt) == KERN_SUCCESS) {
        c->cpu_user = l.cpu_ticks[CPU_STATE_USER];
        c->cpu_sys  = l.cpu_ticks[CPU_STATE_SYSTEM];
        c->cpu_idle = l.cpu_ticks[CPU_STATE_IDLE];
        c->cpu_nice = l.cpu_ticks[CPU_STATE_NICE];
    }
}

static void read_core_ticks(counters_t *c)
{
    processor_info_array_t arr = NULL;
    mach_msg_type_number_t cnt = 0;
    natural_t npu = 0;
    c->core_n = 0;
    kern_return_t kr = host_processor_info(mach_host_self(),
                                           PROCESSOR_CPU_LOAD_INFO,
                                           &npu, &arr, &cnt);
    if (kr != KERN_SUCCESS || !arr) return;
    int n = (int)npu;
    if (n > CPERF_MAX_CORES) n = CPERF_MAX_CORES;
    for (int i = 0; i < n; i++) {
        integer_t *p = arr + (i * CPU_STATE_MAX);
        uint64_t u  = (uint64_t)(unsigned)p[CPU_STATE_USER];
        uint64_t s  = (uint64_t)(unsigned)p[CPU_STATE_SYSTEM];
        uint64_t id = (uint64_t)(unsigned)p[CPU_STATE_IDLE];
        uint64_t ni = (uint64_t)(unsigned)p[CPU_STATE_NICE];
        c->core_total[i] = u + s + id + ni;
        c->core_busy[i]  = u + s + ni;
    }
    c->core_n = n;
    vm_deallocate(mach_task_self(), (vm_address_t)arr,
                  (vm_size_t)cnt * sizeof(integer_t));
}

static void read_disk_counters(counters_t *c)
{
    io_iterator_t it = IO_OBJECT_NULL;
    CFMutableDictionaryRef m = IOServiceMatching("IOBlockStorageDriver");
    if (!m) return;
    if (IOServiceGetMatchingServices(CPERF_MAIN_PORT, m, &it) != KERN_SUCCESS) return;

    io_object_t obj;
    while ((obj = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(obj, &props,
                                              kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFStringRef sk = CFStringCreateWithCString(NULL, "Statistics",
                                                        kCFStringEncodingUTF8);
            if (sk) {
                CFTypeRef st = CFDictionaryGetValue(props, sk);
                CFRelease(sk);
                if (st && CFGetTypeID(st) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef d = (CFDictionaryRef)st;
                    c->disk_read  += cfnum_u64(d, "Bytes (Read)");
                    c->disk_write += cfnum_u64(d, "Bytes (Write)");
                    c->disk_ops   += cfnum_u64(d, "Operations (Read)");
                    c->disk_ops   += cfnum_u64(d, "Operations (Write)");
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);
}

static void read_net_counters(counters_t *c)
{
    struct ifaddrs *list = NULL, *p;
    if (getifaddrs(&list) != 0) return;
    for (p = list; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        if (p->ifa_flags & IFF_LOOPBACK) continue;
        const struct if_data *d = (const struct if_data *)p->ifa_data;
        if (!d) continue;
        c->net_in  += d->ifi_ibytes;
        c->net_out += d->ifi_obytes;
    }
    freeifaddrs(list);
}

static void read_mem_counters(counters_t *c)
{
    vm_statistics64_data_t vm;
    memset(&vm, 0, sizeof(vm));
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    if (page == 0) page = (vm_size_t)getpagesize();

    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        /* inactive 是可回收的文件缓存，不计入「已用」。
         * 把它计入会在 16 GiB 机器上算出 94% 已用；macmon /
         * Activity Monitor 的口径是 active + wired + compressed（约 81%）。 */
        c->mem_used = (uint64_t)(vm.active_count + vm.wire_count +
                                 vm.compressor_page_count) * page;
        c->mem_wired      = (uint64_t)vm.wire_count * page;
        c->mem_compressed = (uint64_t)vm.compressor_page_count * page;
    }
    int64_t total = 0;
    if (sysctl_int("hw.memsize", &total) == 0 && total > 0)
        c->mem_total = (uint64_t)total;

    /* 与 <sys/vmmeter.h> 的 struct xsw_usage 布局一致；本地定义可避免
     * 不同 SDK 里字段名 / 加密标志位差异导致编译失败。 */
    typedef struct {
        uint64_t xsu_total;
        uint64_t xsu_avail;
        uint64_t xsu_used;
        uint32_t xsu_pagesize;
        uint32_t xsu_encrypted;
    } cperf_xsw_t;
    cperf_xsw_t sw;
    memset(&sw, 0, sizeof(sw));
    size_t len = sizeof(sw);
    if (sysctlbyname("vm.swapusage", &sw, &len, NULL, 0) == 0) {
        c->swap_used  = sw.xsu_used;
        c->swap_total = sw.xsu_total;
    }
}

static void read_all_counters(counters_t *c)
{
    memset(c, 0, sizeof(*c));
    read_cpu_ticks(c);
    read_core_ticks(c);
    read_disk_counters(c);
    read_net_counters(c);
    read_mem_counters(c);
}

static double diff_u64(uint64_t now_v, uint64_t prev_v)
{
    /* getifaddrs 的 ifi_*bytes 是 32 位，可能回绕一次 */
    if (now_v >= prev_v) return (double)(now_v - prev_v);
    return (double)(0x100000000ULL - prev_v + now_v);
}

static double rate(uint64_t now_v, uint64_t prev_v, double seconds)
{
    if (seconds <= 0.0001) return 0.0;
    double d = diff_u64(now_v, prev_v);
    return d > 0 ? d / seconds : 0.0;
}

static void fill_public_metrics(cproc_perf_values_t *p, const counters_t *now,
                                const counters_t *prev, double seconds)
{
    uint64_t du = diff_u64(now->cpu_user, prev->cpu_user);
    uint64_t ds = diff_u64(now->cpu_sys,  prev->cpu_sys);
    uint64_t di = diff_u64(now->cpu_idle, prev->cpu_idle);
    uint64_t dn = diff_u64(now->cpu_nice, prev->cpu_nice);
    uint64_t total = du + ds + di + dn;
    if (total > 0) {
        p->cpu_user_pct = 100.0 * (double)du / (double)total;
        p->cpu_sys_pct  = 100.0 * (double)ds / (double)total;
        p->cpu_idle_pct = 100.0 * (double)di / (double)total;
        p->cpu_total_pct = 100.0 * (double)(du + ds + dn) / (double)total;
        p->valid |= CPERF_VALID_CPU;
    }

    /* 分簇利用率：按核心序号启发式（E 核在前，P 核在后）。
     * macOS 不公开 core-id → perflevel 映射，UI 会明确标注这是启发式。 */
    int n = now->core_n < prev->core_n ? now->core_n : prev->core_n;
    if (n > 0 && g_soc.nperflevels >= 2 && g_soc.e_cores > 0 && g_soc.p_cores > 0) {
        double busy_e = 0, total_e = 0, busy_p = 0, total_p = 0;
        int ec = g_soc.e_cores, pc = g_soc.p_cores;
        if (ec + pc > n) { ec = n / 2; pc = n - ec; }
        for (int i = 0; i < ec; i++) {
            busy_e  += diff_u64(now->core_busy[i],  prev->core_busy[i]);
            total_e += diff_u64(now->core_total[i], prev->core_total[i]);
        }
        for (int i = 0; i < pc && (n - 1 - i) >= 0; i++) {
            int k = n - 1 - i;
            busy_p  += diff_u64(now->core_busy[k],  prev->core_busy[k]);
            total_p += diff_u64(now->core_total[k], prev->core_total[k]);
        }
        if (total_e > 0) p->e_core_pct = 100.0 * busy_e / total_e;
        if (total_p > 0) p->p_core_pct = 100.0 * busy_p / total_p;
        p->valid |= CPERF_VALID_CORES;
    }

    p->disk_read_bps  = rate(now->disk_read,  prev->disk_read,  seconds);
    p->disk_write_bps = rate(now->disk_write, prev->disk_write, seconds);
    p->disk_iops      = rate(now->disk_ops,   prev->disk_ops,   seconds);
    /* 只有确实枚举到块设备计数器才算可用；否则显示「—」而不是 0 MB/s */
    if (now->disk_read > 0 || now->disk_write > 0 || now->disk_ops > 0)
        p->valid |= CPERF_VALID_DISK;

    p->net_rx_bps = rate(now->net_in,  prev->net_in,  seconds);
    p->net_tx_bps = rate(now->net_out, prev->net_out, seconds);
    if (now->net_in > 0 || now->net_out > 0)
        p->valid |= CPERF_VALID_NET;

    p->mem_used       = now->mem_used;
    p->mem_total      = now->mem_total;
    p->mem_wired      = now->mem_wired;
    p->mem_compressed = now->mem_compressed;
    p->swap_used      = now->swap_used;
    p->swap_total     = now->swap_total;
    if (now->mem_total > 0) p->valid |= CPERF_VALID_MEM;

    if (g_notify_token >= 0) {
        uint64_t state = 0;
        if (notify_get_state(g_notify_token, &state) == 0) {
            p->thermal_pressure = (uint32_t)(state & 0xff);
            p->valid |= CPERF_VALID_THERMAL;
        }
    }
}

/* ------------------------------------------------------------------ */
/* 采样线程                                                           */
/* ------------------------------------------------------------------ */

static pthread_t g_thread;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_running = 0;
static volatile int g_thread_started = 0;
static uint32_t g_interval_ms = 1000;
static cproc_perf_values_t g_latest;
static int g_have_frame = 0;

static void fill_static_fields(cproc_perf_values_t *p)
{
    p->p_cores = g_soc.p_cores;
    p->e_cores = g_soc.e_cores;
    p->gpu_cores = g_soc.gpu_cores;
    p->nperflevels = g_soc.nperflevels;
    p->p_freq_max_mhz   = g_soc.p_freq_max_mhz;
    p->e_freq_max_mhz   = g_soc.e_freq_max_mhz;
    p->m_freq_max_mhz   = g_soc.m_freq_max_mhz;
    p->gpu_freq_max_mhz = g_soc.gpu_freq_max_mhz;
    if (g_soc.p_freq_max_mhz || g_soc.e_freq_max_mhz ||
        g_soc.m_freq_max_mhz || g_soc.gpu_freq_max_mhz)
        p->valid |= CPERF_VALID_DVFS;
    p->valid |= CPERF_VALID_SOC;
}

static void sample_once(uint32_t window_ms, cproc_perf_values_t *out)
{
    memset(out, 0, sizeof(*out));
    fill_static_fields(out);

    uint64_t t0 = cproc_perf_now_ns();

    /* 第一次 IOReport 样本（同时建立 channel 元数据） */
    CFDictionaryRef s1 = NULL, s2 = NULL, delta = NULL;
    int meta_ok = 0;
    if (g_ior_ok) {
        s1 = ior.samples(g_ior_subscription, g_ior_subscribed, NULL);
        if (s1) meta_ok = (ior_build_metadata(s1) == 0);
    }

    if (window_ms > 0) usleep((useconds_t)window_ms * 1000U);

    counters_t now;
    read_all_counters(&now);
    uint64_t t1 = cproc_perf_now_ns();

    double seconds = (double)(t1 - t0) / 1e9;
    if (seconds <= 0.0001) seconds = (double)window_ms / 1000.0;

    if (g_prev_valid)
        fill_public_metrics(out, &now, &g_prev, seconds);
    g_prev = now;
    g_prev_valid = 1;

    /* 诊断只在解析阶段持锁，usleep 窗口内不占用（Swift 侧读取不会卡 1 秒） */
    pthread_mutex_lock(&g_diag_lock);
    diag_reset();

    if (g_ior_ok && s1 && meta_ok) {
        s2 = ior.samples(g_ior_subscription, g_ior_subscribed, NULL);
        if (s2) {
            delta = ior.delta(s1, s2, NULL);
            if (delta) {
                ior_parse_delta(delta, seconds, out);
                CFRelease(delta);
            }
            CFRelease(s2);
        }
    }
    if (s1) CFRelease(s1);

    smc_sample(out);
    out->timestamp_ns = cproc_perf_now_ns();
    pthread_mutex_unlock(&g_diag_lock);
}

static void build_status_string(void)
{
    char buf[CPERF_STATUS_MAX];
    buf[0] = '\0';
#define APPEND(...) diag_append_bilingual(buf, sizeof(buf), __VA_ARGS__)

    APPEND("%s", g_soc.soc_name);
    if (g_soc.nperflevels >= 2)
        APPEND(" · P%u/E%u 核", g_soc.p_cores, g_soc.e_cores);
    if (g_soc.gpu_cores > 0) APPEND(" · GPU %u 核", g_soc.gpu_cores);
    APPEND("\n");
    APPEND("IOReport %s · SMC %s · DVFS %s · 热压 %s",
           g_ior_ok ? "可用" : "不可用",
           g_smc_ok ? "可用" : "不可用",
           (g_soc.p_freq_max_mhz || g_soc.e_freq_max_mhz || g_soc.gpu_freq_max_mhz)
               ? "可用" : "不可用",
           g_notify_token >= 0 ? "可用" : "不可用");
    APPEND("\n");
    APPEND("pmgr %u 张频率表（CPU 单位 %s）· E≤%uMHz / P≤%uMHz / GPU≤%uMHz · 温度走 SMC，读不到回退 IOHID",
           (unsigned)g_soc.table_n,
           g_soc.cpu_table_unit_khz ? "kHz(M4+)" : "Hz",
           g_soc.e_freq_max_mhz, g_soc.p_freq_max_mhz, g_soc.gpu_freq_max_mhz);
    APPEND("\n");
    APPEND("公开层：CPU / 内存 / Swap / 磁盘(IOBlockStorageDriver) / 网络(getifaddrs) 始终可用");
    if (!g_ior_ok)
        APPEND("\n提示：功耗与实时频率需要 libIOReport.dylib；VM / Intel Mac / 未来系统版本可能不提供");
    if (!g_smc_ok)
        APPEND("\n提示：整机功率(PSTR)需要 AppleSMC user client；温度仍可能由 IOHID 提供");
    APPEND("\n功耗只取 Energy Model 组的精确通道（macmon 口径）；SoC 分项与 SMC PSTR 整机功率不可相加");
    APPEND("\n实时频率由 P-state residency 按 pmgr 频率表索引反查（macmon 的 take(freqs.len()) 口径）");
    APPEND("\n下方「逐通道诊断」列出实际计入的能量通道 W 值、P-state 状态名与温度原始传感器");
    APPEND("\n分簇利用率按核心序号启发式分组（E 核在前），不代表 perflevel 的精确映射");
    APPEND("\n网络为 32 位计数器差分（第三方签名下内核按 1KiB 批量化，数值为近似）");
    snprintf(g_soc.status, sizeof(g_soc.status), "%s", buf);
#undef APPEND
}

static void *perf_thread_main(void *arg)
{
    (void)arg;
    read_soc_info(&g_soc);

    g_ior_ok = (ior_init() == 0);
    g_smc_ok = (smc_open() == 0);
    hid_load();

    if (notify_register_check("com.apple.system.thermalpressurelevel",
                              &g_notify_token) != 0)
        g_notify_token = -1;

    build_status_string();

    read_all_counters(&g_prev);
    g_prev_valid = 1;

    while (g_running) {
        uint32_t win = g_interval_ms;
        if (win < 100)  win = 100;
        if (win > 10000) win = 10000;

        uint64_t t0 = cproc_perf_now_ns();
        cproc_perf_values_t snap;
        sample_once(win, &snap);
        uint64_t elapsed_ms = (cproc_perf_now_ns() - t0) / 1000000ULL;

        pthread_mutex_lock(&g_lock);
        g_latest = snap;
        g_have_frame = 1;
        pthread_mutex_unlock(&g_lock);

        if (g_running && elapsed_ms < win)
            usleep((useconds_t)(win - elapsed_ms) * 1000U);
    }

    if (g_notify_token >= 0) { notify_cancel(g_notify_token); g_notify_token = -1; }
    smc_close();
    if (g_ior_ok) ior_shutdown();
    free(g_meta);
    g_meta = NULL;
    g_meta_cap = g_meta_n = 0;
    return NULL;
}

/* ------------------------------------------------------------------ */
/* 公开 API                                                           */
/* ------------------------------------------------------------------ */

int cproc_perf_start(uint32_t interval_ms)
{
    cproc_perf_stop();
    g_interval_ms = (interval_ms < 100) ? 1000 : interval_ms;
    if (g_interval_ms > 10000) g_interval_ms = 10000;

    pthread_mutex_lock(&g_lock);
    g_have_frame = 0;
    memset(&g_latest, 0, sizeof(g_latest));
    pthread_mutex_unlock(&g_lock);

    g_running = 1;
    g_thread_started = 0;
    int rc = pthread_create(&g_thread, NULL, perf_thread_main, NULL);
    if (rc != 0) {
        g_running = 0;
        return -1;
    }
    g_thread_started = 1;
    return 0;
}

void cproc_perf_stop(void)
{
    if (!g_thread_started) { g_running = 0; return; }
    g_running = 0;
    /* join 保证旧线程彻底退出后再允许重新 start；最多阻塞一个采样窗口 */
    pthread_join(g_thread, NULL);
    g_thread_started = 0;
}

void cproc_perf_set_interval(uint32_t interval_ms)
{
    uint32_t v = (interval_ms < 100) ? 1000 : interval_ms;
    if (v > 10000) v = 10000;
    g_interval_ms = v;
}

int cproc_perf_latest(cproc_perf_values_t *out)
{
    if (!out) return -1;
    pthread_mutex_lock(&g_lock);
    int ok = g_have_frame;
    if (ok) *out = g_latest;
    pthread_mutex_unlock(&g_lock);
    return ok ? 0 : -1;
}

const char *cproc_perf_soc_name(void)
{
    return g_soc.soc_name[0] ? g_soc.soc_name : "Unknown Mac";
}

const char *cproc_perf_status(void)
{
    static char fallback[512];
    if (g_soc.status[0]) return g_soc.status;
    const char *zh = "性能采样尚未启动";
    const char *en = cproc_l10n_en_field(zh);
    const char *key = cproc_l10n_key_field(zh);
    snprintf(fallback, sizeof(fallback), "\x1eL:%s\x1f%s\x1f%s\x1e",
             key ? key : "", zh, en ? en : zh);
    return fallback;
}

int cproc_perf_is_apple_silicon(void)
{
    if (g_soc.soc_name[0] == '\0') read_soc_info(&g_soc);
    return g_soc.apple_silicon;
}

uint32_t cproc_perf_interval_ms(void) { return g_interval_ms; }
