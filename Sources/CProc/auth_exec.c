/* SPDX-License-Identifier: MIT */
/*
 * auth_exec.c —— 以 root 执行工具（macOS 图形界面标准的授权方式）
 *
 * 为什么要包一层 C：`AuthorizationExecuteWithPrivileges` 在 10.7 起被标记
 * deprecated，新版 SDK 直接标成 **unavailable in Swift**，Swift 里根本调不到
 * （编译期报 "APIs deprecated as of macOS 10.9 and earlier are unavailable in Swift"）。
 * 这个 API 仍然是目前「不装 helper、不要求签名证书、不调 sudo」就能弹系统
 * 授权框并拿到真实 uid=0 子进程的唯一公开途径 —— 系统自带的很多工具也这么做。
 * 所以放在 C 层调用，Swift 只看到三个返回 int 的函数。
 *
 * 注意：
 *  · 只通过 AuthorizationExecuteWithPrivileges 执行 **固定路径的系统工具**
 *    （/sbin/ifconfig、/sbin/route、/bin/sh），参数由上层严格校验后拼装；
 *  · 子进程的 stderr 不会进 pipe（这个 API 只接 stdout），需要错误文本时
 *    让上层用 /bin/sh -c '… 2>&1' 包一层；
 *  · 授权凭据由 AuthorizationRef 缓存，5 分钟内重复操作不会再弹框。
 */
#include "CProc.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int cproc_auth_create(void **out)
{
    if (!out) return -1;
    AuthorizationRef ref = NULL;
    OSStatus st = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                      kAuthorizationFlagDefaults, &ref);
    if (st != errAuthorizationSuccess || !ref) return (int)st;
    /* AuthorizationRef 是 const 指针，这里故意转成不透明句柄交给 Swift 保管 */
    *out = (void *)ref;
    return 0;
}

void cproc_auth_free(void *auth)
{
    if (!auth) return;
    AuthorizationFree((AuthorizationRef)auth, kAuthorizationFlagDefaults);
}

/* 预先申请「以 root 执行」的权限：这一步会弹系统授权对话框。 */
int cproc_auth_request_exec(void *auth)
{
    if (!auth) return -1;
    AuthorizationItem item = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    AuthorizationFlags flags = kAuthorizationFlagDefaults
                             | kAuthorizationFlagInteractionAllowed
                             | kAuthorizationFlagExtendRights
                             | kAuthorizationFlagPreAuthorize;
    OSStatus st = AuthorizationCopyRights((AuthorizationRef)auth, &rights,
                                          kAuthorizationEmptyEnvironment,
                                          flags, NULL);
    return (int)st;
}

/* 以 root 执行 tool（argv 必须以 NULL 结尾），把 stdout 全读进 *out。
 * 返回 0 表示成功；负数 / OSStatus 表示失败。*out 由调用方 free()。 */
int cproc_auth_exec(void *auth, const char *tool, const char *const argv[],
                    char **out)
{
    if (!auth || !tool) return -1;
    if (out) *out = NULL;

    FILE *pipe = NULL;
    /* 这个 API 从 10.7 起就被标记 deprecated，但至今仍是「不装 privileged helper、
       不要求签名证书」就能起 root 子进程的唯一公开途径；新版 SDK 连 Swift 都不让调，
       所以只能在这里显式关掉这条告警。 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus st = AuthorizationExecuteWithPrivileges(
        (AuthorizationRef)auth, tool, kAuthorizationFlagDefaults,
        (char *const *)argv, &pipe);
#pragma clang diagnostic pop
    if (st != errAuthorizationSuccess) return (int)st;

    if (!pipe) return 0;

    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) { fclose(pipe); return -2; }
    buf[0] = '\0';

    for (;;) {
        if (len + 1024 + 1 > cap) {
            size_t nc = cap * 2;
            char *nb = realloc(buf, nc);
            if (!nb) break;
            buf = nb;
            cap = nc;
        }
        size_t n = fread(buf + len, 1, cap - len - 1, pipe);
        len += n;
        if (n == 0) break;
    }
    buf[len] = '\0';
    fclose(pipe);           /* 子进程已关闭 stdout（= 已退出） */

    if (out) *out = buf;
    else free(buf);
    return 0;
}
