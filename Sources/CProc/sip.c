/* SPDX-License-Identifier: MIT */
/*
 * sip.c —— 读取 SIP 活动配置，不调用 csrutil
 *
 * csrutil status 的核心是私有的 CSRSecurityConfig 类；它最终读的就是内核里的
 * 活动配置位图（csr-active-config）。libSystem 导出了这个查询函数：
 *
 *     int csr_get_active_config(csr_config_t *config);   // 0 = 成功
 *
 * 只是没有公开头文件。这里用 dlsym 取符号（不写死地址、不依赖私有框架），
 * 拿得到就直接问内核，拿到的是**逐项**配置，比 csrutil 的文本输出更细：
 *   bit 0x0001 允许不受信任的 kext        bit 0x0002 允许无限制文件系统访问
 *   bit 0x0004 允许 task_for_pid          bit 0x0008 允许内核调试
 *   bit 0x0010 Apple Internal             bit 0x0020 允许无限制 dtrace
 *   bit 0x0040 允许改 NVRAM               bit 0x0800 允许未签名的系统卷
 * 位为 1 = **放开**该项保护；全 0 = SIP 完全开启。
 *
 * 符号不可用时退回探测：SIP 开启时 /System/Library 这类路径带 UF_RESTRICTED
 * 文件标志，关闭后标志消失。探测只能回答「文件系统保护是否生效」，因此把结果
 * 近似成全 0 / 全 1，并用 *out_from_api = 0 标记这是近似值。
 */
#include "CProc.h"

#include <dlfcn.h>
#include <stdint.h>
#include <sys/stat.h>

/* xnu bsd/sys/stat.h 里的 UF_RESTRICTED；没有导出到公开头文件 */
#define CPROC_UF_RESTRICTED 0x00080000u

/* 已知位全部置 1，用于判断「SIP 整体关闭」 */
#define CPROC_CSR_KNOWN_MASK 0x00000FFFu

int cproc_sip_config(uint32_t *out_active, int *out_from_api)
{
    if (!out_active) return -1;
    if (out_from_api) *out_from_api = 0;

    typedef int (*csr_get_active_config_fn)(uint32_t *);
    void *sym = dlsym(RTLD_DEFAULT, "csr_get_active_config");
    if (sym) {
        uint32_t cfg = 0;
        csr_get_active_config_fn fn = (csr_get_active_config_fn)sym;
        if (fn(&cfg) == 0) {
            *out_active = cfg;
            if (out_from_api) *out_from_api = 1;
            return 0;
        }
    }

    static const char *const probe[] = { "/System/Library", "/usr/bin", "/bin" };
    for (size_t i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
        struct stat st;
        if (stat(probe[i], &st) != 0) continue;
        int restricted = (st.st_flags & CPROC_UF_RESTRICTED) != 0;
        *out_active = restricted ? 0u : CPROC_CSR_KNOWN_MASK;
        return 0;
    }
    return -1;
}
