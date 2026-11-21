/* SPDX-License-Identifier: MIT */
/* ---------------------------------------------------------------------
 * 以「自我负责（self-responsible）」方式重新拉起本 App
 *
 * 背景：TCC 把权限判给 **responsible process**，而不是发起访问的进程本身。
 * 经 `launchctl asuser` 拉起的进程，responsible 一路继承到调用方 —— 也就是
 * 我们的特权助手（LaunchDaemon）。助手是一份没有 Info.plist bundle 的裸
 * 可执行文件，TCC 按它的身份评估，用户在「完全磁盘访问」里授给
 * Vantage.app 的授权就全部失效（root 实例读 TCC.db / 其他用户目录全被拒）。
 *
 * open(1)、LaunchServices、launchd 让 App「为自己负责」用的是同一个机制：
 * posix_spawn 属性里加 responsibility_spawnattrs_setdisclaim(attrs, 1)。
 * 实测语义：
 *   · 不 disclaim：子进程 responsible = 父进程的 responsible（继承链）；
 *   · disclaim 后：子进程 responsible = 子进程自身，TCC 按它自己的代码
 *     签名 / bundle 判权 —— 用户授给 App 的 FDA 恢复生效。
 *
 * 用法（助手只能经 launchctl 进入用户会话，没法直接 disclaim 拉 App）：
 * 助手 spawn `launchctl asuser <uid> <app> --respawn-disclaimed`，
 * 第一级实例（已在用户 GUI 会话里）立刻调用本函数 spawn 真正的 App 后
 * 退出；第二级实例 responsible = 自己 → GUI 正常（会话从第一级继承）+ FDA。
 * ------------------------------------------------------------------ */
#include "CProc.h"
#include "cproc_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* 私有 API：spawn_private.h 不随 SDK 发布，但符号在 libSystem 里稳定导出
 * （open(1) / LaunchServices / launchd 都在用）。自声明即可链接。 */
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs,
                                                 int disclaim);

/* 私有 flag：spawn 时默认关闭所有 fd，只保留 file_actions 显式落位的
 * 那几个。比「逐个 fcntl(FD_CLOEXEC)」更不容易漏（新增 fd 自动免疫）。
 * 值来自 spawn_private.h，长期稳定（Chromium 等跨代系统一直用这个值）。 */
#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

int cproc_spawn_disclaimed(const char *exe, uint32_t drop_uid)
{
    if (!exe || !exe[0]) return EINVAL;

    char uidbuf[16];
    snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)drop_uid);

    /* 子进程就是「完全的 App」：只带 --drop-uid（供它提供「降权为用户」）。
     * 不传 --respawn-disclaimed —— 否则会无限自我重新 spawn。 */
    char *argv[] = { (char *)exe, "--drop-uid", uidbuf, NULL };

    char *const *envp = cproc_clean_env_vector();
    if (!envp) return EINVAL;

    posix_spawn_file_actions_t fa;
    if (posix_spawn_file_actions_init(&fa) != 0) return EAGAIN;
    /* stdio 全部指向 /dev/null（O_RDWR：0/1/2 语义都成立）。
     * 配合 CLOEXEC_DEFAULT，子进程不会继承 launchctl 的 socketpair
     * stderr/stdout、日志文件 fd 等任何多余东西。 */
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDWR, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_RDWR, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_RDWR, 0);

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&fa);
        return EAGAIN;
    }
    /* 注意**不要**加 POSIX_SPAWN_SETSID：必须留在目标用户的 GUI 会话里，
     * 否则窗口画不出来。session / bootstrap 由第一级（launchctl asuser
     * 拉起）继承过来。 */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    /* 关键一步：让子进程成为自己的 responsible process。 */
    if (responsibility_spawnattrs_setdisclaim(&attr, 1) != 0) {
        posix_spawnattr_destroy(&attr);
        posix_spawn_file_actions_destroy(&fa);
        return ENOTSUP;
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &fa, &attr, argv, (char *const *)envp);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);
    return rc;              /* 0 = 成功；其余为 posix_spawn 错误码（E 系列） */
}
