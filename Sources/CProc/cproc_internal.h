/* SPDX-License-Identifier: MIT */
#ifndef CPROC_INTERNAL_H
#define CPROC_INTERNAL_H

#include "CProc.h"

/*
 * C 采集层内部共享的运行时上限。
 *
 * cproc_config.c 定义并负责 clamp；proc_detail.c / proc_collect.c / perf.c
 * 直接读取。字段都是对齐的 uint32_t，采集线程读、偏好设置线程写，
 * 单次 32 位读写在 Apple Silicon / x86_64 上不会撕裂，允许「下一次采集
 * 生效」的最终一致，不需要每字段加锁（否则每次系统调用都要取锁）。
 */
extern cproc_limits_t g_cproc_limits;

#endif /* CPROC_INTERNAL_H */
