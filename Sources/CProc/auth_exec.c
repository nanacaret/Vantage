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
 *    （/sbin/ifconfig、/sbin/route、/bin/launchctl），参数由上层严格校验后
 *    以 argv 数组传入 —— 全程不经 shell，也就不存在 shell 注入 / 转义问题；
 *  · 子进程的 stderr 不在通信管道里（这个 API 只接 stdin/stdout），
 *    cproc_auth_exec 会临时把本进程的 fd 2 指到一根管道上让子进程继承，
 *    把 stderr 一并收进返回的输出 —— 以前要靠 /bin/sh -c '… 2>&1' 中转，
 *    现在不再依赖任何 shell；
 *  · 授权凭据由 AuthorizationRef 缓存，5 分钟内重复操作不会再弹框。
 */
#include "CProc.h"

#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

extern char **environ;

/* ---------------------------------------------------------------------
 * audit_token 字段提取（薄封装 libbsm）
 *
 * audit_token_t 是「不透明」结构（unsigned int val[8]），BSM 明确要求用
 * libbsm 的 audit_token_to_* 来解析，内部布局随时可能变。这几个函数在
 * libbsm 里，Swift 直接调会缺链接（本项目没链 -lbsm），所以在 C 层包一层。
 *
 * 签名故意用「指向 val 数组的指针」而不是 audit_token_t 本体：audit_token_t
 * 在系统头里定义，SwiftPM 的 clang 导入在某些构建配置下不会把它导出成可
 * 桥接的类型，导致 Swift 侧「找不到符号」。传指针则与类型无关，最稳。
 * ------------------------------------------------------------------ */
pid_t cproc_audit_pid(const unsigned int token[8])
{ audit_token_t t; memcpy(t.val, token, sizeof(t.val)); return audit_token_to_pid(t); }
uid_t cproc_audit_euid(const unsigned int token[8])
{ audit_token_t t; memcpy(t.val, token, sizeof(t.val)); return audit_token_to_euid(t); }
uid_t cproc_audit_ruid(const unsigned int token[8])
{ audit_token_t t; memcpy(t.val, token, sizeof(t.val)); return audit_token_to_ruid(t); }

/* ---------------------------------------------------------------------
 * 环境变量注入防护 —— 白名单重建 environ
 *
 * 1) 为什么必须做「进程级」处理
 *    AuthorizationExecuteWithPrivileges 的签名（Authorization.h:427）只有
 *    authorization / pathToTool / options / argv / pipe，**没有 envp 参数**。
 *    它内部 fork + exec 一个 setuid-root 的 security_authtrampoline，子进程
 *    继承的是调用方此刻的 environ。所以「给 posix_spawn 显式传最小 envp」
 *    在这条路上做不到：能提权的正是这个 API 本身，我们手上并没有一个
 *    已经是 root 的进程可供 spawn。（LaunchDaemon 那条路才用得上显式 envp，
 *    TouchIDHelperServer.selfDestruct 已经这么做了。）
 *
 * 2) 为什么是白名单而不是黑名单
 *    黑名单永远追不上新变量：新的 DYLD_* 变体、新的 shell 启动变量、
 *    BASH_FUNC_<name>%% 之类。白名单天然免疫，也不需要匹配 %% 后缀或
 *    从 "KEY=VALUE" 里提取 key（于是没有 key[256] 截断删错键的风险）。
 *
 * 3) 为什么是「重建」而不是「遍历 + unsetenv」
 *    unsetenv 会就地重排 environ（把后面的指针前移）。边遍历边删会跳过
 *    紧邻的下一项 —— 实测 4 个连续 BASH_FUNC_* 只删掉 2 个，等于每两个
 *    漏一个注入函数。这里单趟构造新数组、最后一次原子换指针，全程不调
 *    setenv/unsetenv，也就没有「遍历中指针失效 / 越界」的可能。
 *
 * 4) 值全部写死
 *    · PATH 收紧到系统目录，挡住 PATH 劫持；
 *    · LANG=C 让工具输出稳定为 ASCII 英文，便于上层回显 / 解析；
 *    · **不设 HOME / TMPDIR**：
 *      - HOME：Vantage 用 NSHomeDirectory() 定位用户级 TCC.db / LaunchAgents，
 *        写死 /var/root 会把普通用户实例带偏；root 子进程自己按 getpwuid(0)
 *        就会得到 /var/root；
 *      - TMPDIR：macOS 的临时目录**不看这个变量** —— 实测
 *        NSTemporaryDirectory() / confstr(_CS_DARWIN_USER_TEMP_DIR) 永远返回
 *        euid 自己的 /var/folders/.../T（0700、私有）。写死 /private/var/tmp
 *        不但几乎不起作用，还会把子进程引到一个 0777 的**共享**目录
 *        （别的用户可读）——语义也不对。不设它，子进程拿到的就是
 *        euid 对应的正确私有目录；
 *    · macOS 上真正的动态链接器注入向量是 DYLD_*；LD_PRELOAD /
 *      LD_LIBRARY_PATH 是 Linux 特有的，白名单已一并排除，无需列举。
 *
 * 5) 单一清单：cproc_clean_environ() 把这份白名单导出给 Swift，
 *    Process 路径（runDirect / 助手守护进程的 exec 与 relaunch）据此构造
 *    同样的 environment —— 三条 spawn 路径共用一份清单，改一处即全局生效。
 *
 * 6) 线程安全
 *    · 干净数组只构造一次（pthread_once），之后只是换一个指针；
 *    · 旧数组**不 free**：里面的字符串仍被引用，也可能正被别的线程
 *      遍历。换指针是一次指针写，新旧数组都始终是完整、NULL 结尾的，
 *      并发 getenv 只会看到其中一个，不会读到半成品或悬垂指针；
 *    · 互斥锁包住「换 → exec → 读输出 → 还原」，避免两次并发调用把
 *      各自的 saved 交错还原（否则可能把全局 environ 永久留在干净数组）。
 * ------------------------------------------------------------------ */

static char kEnvPath[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";
static char kEnvLang[] = "LANG=C";

static char *const kCleanEnv[] = { kEnvPath, kEnvLang, NULL };

/* 把白名单导出给 Swift：条目按 "KEY=VALUE" 以 '\n' 连接写进 buf。
 * Swift 的 Process 路径（runDirect / 助手守护进程）据此构造 environment，
 * 与 cproc_auth_exec 的 environ 替换共用同一份清单。
 * 返回 0 成功；buf 放不下返回 -1（内容不完整，调用方应视为失败）。 */
int cproc_clean_environ(char *buf, size_t cap)
{
    if (!buf || cap == 0) return -1;
    size_t used = 0;
    for (size_t i = 0; kCleanEnv[i] != NULL; i++) {
        size_t n = strlen(kCleanEnv[i]);
        if (used + n + 2 > cap) return -1;    /* n + '\n' + 终止符 */
        memcpy(buf + used, kCleanEnv[i], n);
        used += n;
        buf[used++] = '\n';
    }
    buf[used > 0 ? used - 1 : 0] = '\0';      /* 去掉末尾换行 / 空串终止 */
    return 0;
}

static char **g_clean_env;                        /* calloc 出的 environ 数组 */
static pthread_once_t   g_clean_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t  g_env_lock   = PTHREAD_MUTEX_INITIALIZER;

static void cproc_build_clean_env(void)
{
    size_t n = sizeof(kCleanEnv) / sizeof(kCleanEnv[0]) - 1;
    char **fresh = calloc(n + 1, sizeof(char *));
    if (!fresh) return;              /* 极端情况：保持原 environ，不硬塞半截 */
    for (size_t i = 0; i < n; i++) fresh[i] = kCleanEnv[i];
    fresh[n] = NULL;
    g_clean_env = fresh;
}

/* 调用方须持有 g_env_lock，并在同一线程配对调用 cproc_restore_env()。 */
static char **cproc_swap_clean_env(void)
{
    char **saved = environ;
    pthread_once(&g_clean_once, cproc_build_clean_env);
    if (g_clean_env) environ = g_clean_env;
    return saved;
}

static void cproc_restore_env(char **saved)
{
    environ = saved;
}

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

/* 并发读两路 fd 直到双方 EOF，把内容按到达顺序追加进 *buf。
 * 容量在 *cap 上随需倍增，长度写回 *len。
 *
 * 为什么必须并发（而不是先读完一路再读另一路）：管道缓冲默认只有 64K，
 * 子进程往 stderr 写满缓冲会堵在 write 上、永远走不到「退出 / 关闭
 * stdout」，只盯 stdout 的读者就死锁了。
 *
 * 单独拆成函数是为了能用 harness 直接做回归测试（fork + 劫持 fd 后调它）。
 * fd 传 -1 表示这一路不存在。读不动（ realloc 失败）就保留已收到的部分。 */
static void cproc_pump_outputs(int out_fd, int err_fd,
                               char **buf, size_t *cap, size_t *len)
{
    while (out_fd >= 0 || err_fd >= 0) {
        struct pollfd pf[2];
        int n = 0;
        if (out_fd >= 0) { pf[n].fd = out_fd; pf[n].events = POLLIN; n++; }
        if (err_fd >= 0) { pf[n].fd = err_fd; pf[n].events = POLLIN; n++; }
        int rc = poll(pf, (nfds_t)n, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int k = 0; k < n; k++) {
            if (!(pf[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            if (*len + 1024 + 1 > *cap) {
                size_t nc = *cap * 2;
                char *nb = realloc(*buf, nc);
                if (!nb) return;          /* 留住已有内容，放弃后续 */
                *buf = nb;
                *cap = nc;
            }
            ssize_t r = read(pf[k].fd, *buf + *len, *cap - *len - 1);
            if (r > 0) {
                *len += (size_t)r;
                (*buf)[*len] = '\0';
            } else if (r < 0 && errno == EINTR) {
                continue;
            } else {
                if (pf[k].fd == out_fd) out_fd = -1;
                else                    err_fd = -1;
            }
        }
    }
}

/* 以 root 执行 tool（argv 必须以 NULL 结尾），把 stdout（以及接管到的
 * stderr）读进 *out。返回 0 表示成功；负数 / OSStatus 表示失败。
 * *out 由调用方 free()。
 *
 * 1) 环境：执行期间把 environ 临时换成白名单（这个 API 没有 envp 参数，
 *    子进程靠 fork 继承）。旧数组不 free、锁内换指针，见上面的注释块；
 *    还原放在读完输出之后，不赌 trampoline 究竟在哪一刻读环境。
 *
 * 2) stderr：这个 API 只把通信管道接到子进程的 stdin/stdout。为了让调用
 *    方拿到错误文本（以前靠 /bin/sh -c '… 2>&1' 中转，现在彻底不用 shell），
 *    调用前把本进程的 fd 2 dup 到一根管道上，子进程经 fork 继承它，stderr
 *    全进管道；AEXP 返回（fork 已完成）后**立刻**还原 fd 2 —— 我们这份写端
 *    留着只会让 stderr 永远等不到 EOF。
 *    仅在调用方要输出（out != NULL）时启用：relaunch 那类调用（out == NULL）
 *    的子进程是常驻 GUI App，等它关 stderr 会永远挂住，保持原来的行为。
 */
int cproc_auth_exec(void *auth, const char *tool, const char *const argv[],
                    char **out)
{
    if (!auth || !tool) return -1;
    if (out) *out = NULL;

    int result = 0;
    FILE *comm = NULL;
    char *buf = NULL;
    size_t cap = 4096, len = 0;
    char **saved = NULL;
    OSStatus st;
    int errfd = -1, saved_stderr = -1;

    if (out) {
        int fds[2];
        if (pipe(fds) == 0) {
            /* macOS 的 pipe() 不自动设 CLOEXEC：不打标的话，AEXP 内部 fork
             * 出来的 trampoline（以及它 exec 的工具进程）会继承
             *   · fds[0] —— stderr 管道的**读端**（本进程的收信邮箱！）
             *   · saved_stderr —— 原 fd 2 的一个 dup
             * fcntl 打标不影响子进程拿到 stderr：下面 dup2(fds[1], 2)
             * 生成的新 fd 照例不带 CLOEXEC，exec 之后仍然指着管道写端。 */
            fcntl(fds[0], F_SETFD, FD_CLOEXEC);
            fcntl(fds[1], F_SETFD, FD_CLOEXEC);
            saved_stderr = dup(2);
            if (saved_stderr >= 0) {
                fcntl(saved_stderr, F_SETFD, FD_CLOEXEC);
                dup2(fds[1], 2);      /* dup2 会清掉新 fd 的 CLOEXEC —— 正合适 */
                close(fds[1]);        /* 写端从此只活在 fd 2 上，由子进程经 fork 继承 */
                errfd = fds[0];
            } else {
                close(fds[0]);
            }
        }
    }

    buf = malloc(cap);
    if (!buf) {
        if (saved_stderr >= 0) { dup2(saved_stderr, 2); close(saved_stderr); }
        if (errfd >= 0) close(errfd);
        return -2;
    }
    buf[0] = '\0';

    pthread_mutex_lock(&g_env_lock);
    saved = cproc_swap_clean_env();

    /* 这个 API 从 10.7 起就被标记 deprecated，但至今仍是「不装 privileged helper、
       不要求签名证书」就能起 root 子进程的唯一公开途径；新版 SDK 连 Swift 都不让调，
       所以只能在这里显式关掉这条告警。 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    st = AuthorizationExecuteWithPrivileges(
        (AuthorizationRef)auth, tool, kAuthorizationFlagDefaults,
        (char *const *)argv, &comm);
#pragma clang diagnostic pop

    /* fork 已经发生，子进程握着它自己那份「fd 2 = 管道写端」；现在还原
     * 我们的 fd 2，否则 stderr 管道的写端永远关不干净、读不到 EOF。 */
    if (saved_stderr >= 0) {
        dup2(saved_stderr, 2);
        close(saved_stderr);
        saved_stderr = -1;
    }

    if (st != errAuthorizationSuccess) {
        result = (int)st;
        if (comm) { fclose(comm); comm = NULL; }
    }

    /* 并发收 stdout + stderr（都用裸 fd 读，别混 FILE 缓冲） */
    cproc_pump_outputs(comm ? fileno(comm) : -1, errfd, &buf, &cap, &len);
    if (comm) fclose(comm);
    if (errfd >= 0) close(errfd);

    cproc_restore_env(saved);
    pthread_mutex_unlock(&g_env_lock);

    if (out) *out = buf;
    else free(buf);
    return result;
}
