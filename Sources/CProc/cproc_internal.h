/* SPDX-License-Identifier: MIT */
#ifndef CPROC_INTERNAL_H
#define CPROC_INTERNAL_H

#include "CProc.h"

#include <stdarg.h>
#include <stddef.h>

/*
 * C 采集层内部共享的运行时上限。
 *
 * cproc_config.c 定义并负责 clamp；proc_detail.c / proc_collect.c / perf.c
 * 直接读取。字段都是对齐的 uint32_t，采集线程读、偏好设置线程写，
 * 单次 32 位读写在 Apple Silicon / x86_64 上不会撕裂，允许「下一次采集
 * 生效」的最终一致，不需要每字段加锁（否则每次系统调用都要取锁）。
 */
extern cproc_limits_t g_cproc_limits;

/* auth_exec.c：exec 环境白名单（PATH + LANG），返回内部静态数组，
 * 供 spawn_self.c 构造 envp 时复用。调用方不得修改其内容。 */
char *const *cproc_clean_env_vector(void);

/* ------------------------------------------------------------------ */
/* text_escape.c：Tab 分列传输格式的字段值转义                          */
/* ------------------------------------------------------------------ */

/* 转义后缓冲区的上限需求（单字符 → 3 字节，最坏 3 倍） */
#define CPROC_ESC_MAX        (24 * 1024)
/* 单行最多支持的分隔符个数（= 字段数 - 1） */
#define CPROC_ESC_FIELD_MAX  24

/* 把 src 里的控制字符换成 Control Pictures，保留 fmt 里字面 '\t' 对应的位置。
 * 返回 src（干净行，零拷贝）或 out。ap 必须对应 fmt 的参数表。
 * out 建议给 CPROC_ESC_MAX 字节。 */
const char *cproc_escape_line(const char *fmt, const char *src, va_list ap,
                              char *out, size_t cap);

/* Debug 断言：成品行里不许出现未转义的控制字节（除了 Tab 分隔与双语标记）。
 * Release 下是空函数。 */
void cproc_verify_line(const char *s);

#endif /* CPROC_INTERNAL_H */
