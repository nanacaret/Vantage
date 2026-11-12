/* SPDX-License-Identifier: MIT */
#include "CProc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

/*
 * 可执行文件架构识别：读 Mach-O 文件头的 cputype / cpusubtype。
 *
 * 为什么不用 pbi_flags：公开头 <sys/proc_info.h> 只导出到 PROC_FLAG_EXEC，
 * Rosetta 相关的 PROC_FLAG_TRANSLATED 在 #ifdef PRIVATE 的 proc_info_private.h
 * 里，SDK 不导出；曾经用 0x00002000 兜底，而 0x2000 其实是
 * PROC_FLAG_PSUGID（进程自 exec 后提过权）—— sudo / login / 各种 setuid
 * helper 因此被整批误标成「Intel (Rosetta 2)」。详见 docs/COMPATIBILITY.md。
 *
 * 这里只回答「这个二进制里有哪些 slice」，是静态事实，不猜运行时状态。
 * 常量自己定义，不依赖 <mach-o/loader.h> / <mach-o/fat.h>（交叉编译与旧
 * SDK 下未必可见）；FAT 头字段一律大端，thin Mach-O 头按 magic 判字节序。
 */

/* FAT / Mach-O magic（按磁盘字节序列比较，避开端序歧义） */
#define CPROC_CPU_TYPE_X86        7
#define CPROC_CPU_TYPE_X86_64     0x01000007
#define CPROC_CPU_TYPE_ARM        12
#define CPROC_CPU_TYPE_ARM64      0x0100000c
#define CPROC_CPU_TYPE_ARM64_32   0x0200000c
#define CPROC_CPU_TYPE_POWERPC    18
#define CPROC_CPU_TYPE_POWERPC64  0x01000012

#define CPROC_SUBTYPE_ARM64E      2       /* CPU_SUBTYPE_ARM64E */
#define CPROC_SUBTYPE_MASK        0xff000000u  /* capability / LIB64 高位 */

#define ARCH_READ_BYTES          16384u  /* 足够 512 个 fat_arch_64；实际二进制最多 2~3 个 slice */
#define ARCH_CACHE_CAP           4096
#define ARCH_CACHE_TTL_NS        (60ull * 1000ull * 1000ull * 1000ull)
#define ARCH_MAX_FAT             4096u   /* 防御损坏文件里的超大 nfat_arch */

struct arch_ent {
    char     *path;
    uint64_t  path_hash;
    uint64_t  stat_key;
    uint64_t  checked_ns;
    uint32_t  archs;
    uint8_t   used;
};

static struct arch_ent  g_cache[ARCH_CACHE_CAP];
static pthread_mutex_t  g_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

static uint32_t le32(const unsigned char *p)
{
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[1] << 8)  | (uint32_t)p[0];
}

/* 单调时间复用 proc_collect.c 的 cproc_now_ns()（CProc.h 已声明），
 * 不在这里再引 <time.h> / clock_gettime，避免严格 C11 下的特性宏依赖。 */
static uint64_t now_ns(void) { return cproc_now_ns(); }

static uint64_t fnv1a(const char *s)
{
    uint64_t h = 14695981039346656037ull;
    for (; *s; s++) {
        h ^= (unsigned char)*s;
        h *= 1099511628211ull;
    }
    return h;
}

static uint64_t stat_key(const struct stat *st)
{
    uint64_t h = 14695981039346656037ull;
    uint64_t v[4];
    v[0] = (uint64_t)st->st_dev;
    v[1] = (uint64_t)st->st_ino;
    v[2] = (uint64_t)st->st_size;
    /* st_mtime 在 Darwin 与 glibc 上都可用（前者是宏，后者是字段/宏），
     * 不用 st_mtimespec / st_mtim，避免严格 C11 下的可移植性问题。 */
    v[3] = (uint64_t)st->st_mtime;
    for (int i = 0; i < 4; i++) {
        h ^= v[i];
        h *= 1099511628211ull;
    }
    return h;
}

static uint32_t bits_for_cpu(int32_t cputype, int32_t cpusubtype)
{
    switch ((uint32_t)cputype) {
    case CPROC_CPU_TYPE_X86:      return CPROC_ARCH_X86;
    case CPROC_CPU_TYPE_X86_64:   return CPROC_ARCH_X86_64;
    case CPROC_CPU_TYPE_ARM:      return CPROC_ARCH_ARM;
    case CPROC_CPU_TYPE_ARM64:
        /* arm64e 仍属于 arm64 家族，两个位都置上，便于「是否有 arm slice」判断 */
        if (((uint32_t)cpusubtype & ~CPROC_SUBTYPE_MASK) == CPROC_SUBTYPE_ARM64E)
            return CPROC_ARCH_ARM64 | CPROC_ARCH_ARM64E;
        return CPROC_ARCH_ARM64;
    case CPROC_CPU_TYPE_ARM64_32: return CPROC_ARCH_ARM64_32;
    case CPROC_CPU_TYPE_POWERPC:  return CPROC_ARCH_PPC;
    case CPROC_CPU_TYPE_POWERPC64:return CPROC_ARCH_PPC64;
    default:                      return CPROC_ARCH_OTHER;
    }
}

/* 从文件头字节流解析架构位掩码。len 是实际读到的字节数。 */
static uint32_t parse_header(const unsigned char *b, size_t len)
{
    if (len < 4) return 0;

    /* ---- FAT / FAT64：magic + nfat_arch 都是大端，fat_arch 字段也是大端 ---- */
    if (b[0] == 0xca && b[1] == 0xfe && b[2] == 0xba &&
        (b[3] == 0xbe || b[3] == 0xbf)) {
        if (len < 8) return 0;
        uint32_t nfat = be32(b + 4);
        if (nfat == 0) return 0;               /* 损坏 / 空容器不等于「未知」，返回 0 */
        if (nfat > ARCH_MAX_FAT) nfat = ARCH_MAX_FAT;
        size_t stride = (b[3] == 0xbf) ? 32u : 20u;  /* fat_arch_64 / fat_arch */
        uint32_t mask = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            size_t off = 8u + (size_t)i * stride;
            if (off + 8u > len) break;          /* 头部被截断，用已读到的部分 */
            int32_t cputype    = (int32_t)be32(b + off);
            int32_t cpusubtype = (int32_t)be32(b + off + 4);
            mask |= bits_for_cpu(cputype, cpusubtype);
        }
        return mask;
    }

    /* 字节序反的 FAT（FAT_CIGAM / FAT_CIGAM_64），极少见但按同一结构处理 */
    if ((b[0] == 0xbe || b[0] == 0xbf) && b[1] == 0xba &&
        b[2] == 0xfe && b[3] == 0xca) {
        if (len < 8) return 0;
        uint32_t nfat = le32(b + 4);
        if (nfat == 0) return 0;
        if (nfat > ARCH_MAX_FAT) nfat = ARCH_MAX_FAT;
        size_t stride = (b[0] == 0xbf) ? 32u : 20u;
        uint32_t mask = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            size_t off = 8u + (size_t)i * stride;
            if (off + 8u > len) break;
            mask |= bits_for_cpu((int32_t)le32(b + off),
                                 (int32_t)le32(b + off + 4));
        }
        return mask;
    }

    /* ---- thin Mach-O：后续字段的字节序由 magic 决定 ---- */
    int little;
    if ((b[0] == 0xcf || b[0] == 0xce) && b[1] == 0xfa &&
        b[2] == 0xed && b[3] == 0xfe) {
        little = 1;                            /* MH_CIGAM_64 / MH_CIGAM */
    } else if (b[0] == 0xfe && b[1] == 0xed && b[2] == 0xfa &&
               (b[3] == 0xce || b[3] == 0xcf)) {
        little = 0;                            /* MH_MAGIC / MH_MAGIC_64（大端） */
    } else {
        return 0;                              /* shell 脚本 / 非 Mach-O */
    }
    if (len < 12) return 0;
    int32_t cputype    = (int32_t)(little ? le32(b + 4) : be32(b + 4));
    int32_t cpusubtype = (int32_t)(little ? le32(b + 8) : be32(b + 8));
    return bits_for_cpu(cputype, cpusubtype);
}

static struct arch_ent *cache_slot(const char *path, uint64_t ph)
{
    size_t start = (size_t)(ph % ARCH_CACHE_CAP);
    for (size_t i = 0; i < ARCH_CACHE_CAP; i++) {
        struct arch_ent *e = &g_cache[(start + i) % ARCH_CACHE_CAP];
        if (!e->used) return e;                     /* 空槽：可插入 */
        if (e->path && e->path_hash == ph && strcmp(e->path, path) == 0)
            return e;                               /* 命中 */
    }
    /* 表满：覆盖起点槽（老条目自然淘汰） */
    return &g_cache[start];
}

static char *dup_str(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static void cache_store(struct arch_ent *e, const char *path, uint64_t ph,
                        uint32_t archs, uint64_t key, uint64_t now)
{
    if (!e->path || strcmp(e->path, path) != 0) {
        free(e->path);
        e->path = dup_str(path);
    }
    e->path_hash = ph;
    e->archs     = archs;
    e->stat_key  = key;
    e->checked_ns = now;
    e->used      = 1;
}

uint32_t cproc_exec_archs(const char *path)
{
    if (!path || !*path) return 0;

    uint64_t ph  = fnv1a(path);
    uint64_t now = now_ns();

    /* 快路径：TTL 内直接返回，每帧不为 800+ 个进程做 stat / open */
    pthread_mutex_lock(&g_lock);
    struct arch_ent *e = cache_slot(path, ph);
    uint32_t hit = 0;
    uint32_t cached_archs = 0;
    uint64_t old_key = 0;
    int hit_valid = 0;
    int path_matches = (e->used && e->path &&
                        strcmp(e->path, path) == 0);
    if (path_matches) {
        cached_archs = e->archs;
        old_key = e->stat_key;
        if (now >= e->checked_ns &&
            (now - e->checked_ns) < ARCH_CACHE_TTL_NS) {
            hit = e->archs;
            hit_valid = 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (hit_valid) return hit;

    /* 慢路径：不持锁做 I/O。TTL 过期时先 stat 复核，文件没变就只刷新时间戳。 */
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        pthread_mutex_lock(&g_lock);
        e = cache_slot(path, ph);
        cache_store(e, path, ph, 0, 0, now_ns());
        pthread_mutex_unlock(&g_lock);
        return 0;                              /* 路径不可读：SIP / 已删除 / 脚本 */
    }

    struct stat st;
    int have_st = (fstat(fd, &st) == 0);
    uint64_t key = have_st ? stat_key(&st) : 0;

    uint32_t archs = 0;
    if (!have_st || key == 0 || !old_key || key != old_key) {
        unsigned char *buf = (unsigned char *)malloc(ARCH_READ_BYTES);
        if (buf && lseek(fd, 0, SEEK_SET) == 0) {
            size_t total = 0;
            while (total < ARCH_READ_BYTES) {
                ssize_t n = read(fd, buf + total, ARCH_READ_BYTES - total);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                if (n == 0) break;
                total += (size_t)n;
            }
            if (total > 0) archs = parse_header(buf, total);
        }
        free(buf);
    } else {
        /* stat 未变 → 直接复用快路径保存的确定值，不再重查 slot，
         * 避免并发插入时把别的路径的 archs 拿过来。 */
        archs = cached_archs;
    }
    close(fd);

    pthread_mutex_lock(&g_lock);
    e = cache_slot(path, ph);
    cache_store(e, path, ph, archs, key, now_ns());
    pthread_mutex_unlock(&g_lock);
    return archs;
}

void cproc_exec_archs_flush(void)
{
    pthread_mutex_lock(&g_lock);
    for (size_t i = 0; i < ARCH_CACHE_CAP; i++) {
        free(g_cache[i].path);
        g_cache[i].path = NULL;
        g_cache[i].used = 0;
        g_cache[i].archs = 0;
        g_cache[i].stat_key = 0;
        g_cache[i].checked_ns = 0;
        g_cache[i].path_hash = 0;
    }
    pthread_mutex_unlock(&g_lock);
}
