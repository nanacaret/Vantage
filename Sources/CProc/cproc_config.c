/* SPDX-License-Identifier: MIT */
#include "cproc_internal.h"

#include <string.h>

/* 与偏好设置界面「采集上限」页的默认值保持一致。
 * 改动默认值时请同步 Preferences.swift 的 defaults。 */
cproc_limits_t g_cproc_limits = {
    .max_regions    = 20000,              /* 单次 vm_map region 枚举上限 */
    .pipe_cache_ms  = 2000,               /* 全局 pipe 索引缓存 */
    .argv_max_bytes = 1024 * 1024,        /* KERN_PROCARGS2 缓冲区上限 */
    .fd_max_bytes   =  64 * 1024 * 1024,  /* PROC_PIDLISTFDS 缓冲区上限 */
    .smc_max_keys   = 65535,              /* SMC #KEY 枚举上限 */
};

static uint32_t clamp_u32(uint32_t v, uint32_t lo, uint32_t hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void cproc_get_limits(cproc_limits_t *out)
{
    if (!out) return;
    /* 逐字段复制：避免采集线程正在写某个字段时读到半结构体 */
    out->max_regions    = g_cproc_limits.max_regions;
    out->pipe_cache_ms  = g_cproc_limits.pipe_cache_ms;
    out->argv_max_bytes = g_cproc_limits.argv_max_bytes;
    out->fd_max_bytes   = g_cproc_limits.fd_max_bytes;
    out->smc_max_keys   = g_cproc_limits.smc_max_keys;
}

void cproc_set_limits(const cproc_limits_t *in)
{
    if (!in) return;

    /* 每个字段单独 clamp：0 / 超大值都可能让采集变成死循环或 OOM，
     * 界面填错也不能把 App 拖死。上限取一个仍有用但安全的值。 */
    cproc_limits_t v;
    v.max_regions    = clamp_u32(in->max_regions,    100,   200000);
    v.pipe_cache_ms  = clamp_u32(in->pipe_cache_ms,  200,   60000);
    v.argv_max_bytes = clamp_u32(in->argv_max_bytes, 4096,  16u * 1024 * 1024);
    v.fd_max_bytes   = clamp_u32(in->fd_max_bytes,   65536, 256u * 1024 * 1024);
    v.smc_max_keys   = clamp_u32(in->smc_max_keys,   128,   200000);

    /* 逐字段写，保证任一时刻每个字段都是完整值 */
    g_cproc_limits.max_regions    = v.max_regions;
    g_cproc_limits.pipe_cache_ms  = v.pipe_cache_ms;
    g_cproc_limits.argv_max_bytes = v.argv_max_bytes;
    g_cproc_limits.fd_max_bytes   = v.fd_max_bytes;
    g_cproc_limits.smc_max_keys   = v.smc_max_keys;
}
