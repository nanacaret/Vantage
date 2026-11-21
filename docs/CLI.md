# 命令行（`vantage`）

Vantage 有三个前端，共用同一套 C 采集层：

| 前端 | 形态 | 用途 |
|---|---|---|
| `Vantage.app` | AppKit GUI | 平时用：列表、检查器、性能监控、IORegistry、启动项、网络… |
| `vantage` | 命令行 | 脚本 / 远程 shell / 管道：一次调用换一份输出，或 `--json` 给程序读 |
| `vantage-mcp` | MCP stdio 服务 | 给 Claude Desktop / Cursor 这类客户端当工具用 |

三者都不依赖 GUI 是否在运行，也都不需要 root（需要 root 才能读的字段会明确标出来）。

## 安装 / 调用

`Scripts/build_app.sh` 会把两个命令行工具放进 bundle 的 `Contents/MacOS/bin/`：

```bash
build/Vantage.app/Contents/MacOS/bin/vantage list
```

目录分开了，CLI 就能叫回 `vantage` —— 大小写不敏感只在同一个目录里才会和 GUI 的
`Vantage` 撞名。选 `MacOS/bin/` 而不是 `Helpers/` 或 `Resources/bin/` 的依据：

| 位置 | Apple 文档 | codesign 怎么封存 |
|---|---|---|
| `Contents/MacOS/`（含 `bin/` 子目录） | 「you may put other standalone executables (such as command-line tools) in this directory as well」 | nested code：`files2` 里是 `cdhash` requirement |
| `Contents/Helpers/` | 文档里没有这个目录（Xcode 时代的老用法，Doubao 这类 app 仍在用） | nested code：同样按 `cdhash` 校验 |
| `Contents/Resources/**` | 定义为资源文件 | 普通资源：`files` 里是文件哈希，**不校验代码签名** |

也就是说 `Resources/app/bin/code`（VS Code）、`SharedSupport/bin/subl`（Sublime）
这类放法在工程上能跑，但可执行文件被当数据封存 —— 签名坏了 `--verify --deep` 也
发现不了。`Helpers/` 签名上是合格的，只是不在 Apple 的 bundle 文档里。所以取文档
明确允许、且按代码校验的 `MacOS/bin/`。

做一次符号链接就能直接敲 `vantage`：

```bash
sudo ln -sf "$PWD/build/Vantage.app/Contents/MacOS/bin/vantage" /usr/local/bin/vantage
```

> SPM 产物仍然叫 `vantage-cli`（`swift run vantage-cli`），因为
> `.build/release/` 下 `vantage` 会和 GUI 的 `Vantage` 撞名 —— 那是构建目录的
> 限制，跟 bundle 布局无关。
>
> `--version` 打印 argv[0] + **编译期注入**的版本（`BuildVersion.marketing`，
> 由 `build_app.sh <version>` 经 `Scripts/inject_version.py` 写入；不传参数就是
> `nightly`，发布版是 tag 去掉 `v`）。
> 它是二进制里的一段字符串，不读 Info.plist、不解析路径，所以软链到
> `/usr/local/bin` 或直接拷到别处都报对版本；`swift run` 用的是仓库里最后一次
> 注入的值。

## 命令

```
vantage [list] [options]           列出进程（默认命令）
vantage info <pid> [--json]        单个进程：身份 / 内存 / CPU / 命令行
vantage detail <pid> <kind> [-n N] 某个检查器页（与 GUI 同源采集器）
vantage tree [options]             进程树（自动带上命中行的祖先）
vantage stats [--json]             系统总览：CPU、内存、Swap、负载、进程/线程数
vantage net [ifaces|addrs|routes]  网卡 / 地址 / 路由
vantage signal <pid> <SIG>         发信号（TERM / KILL / HUP / 15 / 9 …）
vantage help | --version
```

### 全局开关

| 开关 | 说明 |
|---|---|
| `--json` | 机器可读输出（字段名与文本模式一致） |
| `--lang zh\|en` | 覆盖语言；默认跟随 `VANTAGE_LANG` → `LC_ALL` → `LANG`，都没有则英文 |
| `-h`, `--help` | 用法 |

### `list` / `tree`

| 开关 | 说明 |
|---|---|
| `-f, --filter PATTERN` | 子串匹配进程名、长名称、命令行、PID |
| `-u, --user USER` | 只看某个用户（用户名或 uid） |
| `-s, --sort KEY` | `pid`（默认）/ `cpu` / `mem` / `threads` / `name`；`cpu` 是**累计** CPU 时间（一次采样拿不到瞬时占用率，与 `ps` 一致） |
| `-n, --limit N` | 只显示前 N 行（默认：stdout 是终端时 40 行，管道/重定向时全部） |
| `-r, --reverse` | 反序 |
| `--wide` | 不截断命令行（默认按 96 列截断） |

### `detail` 的 kind

`files`、`env`、`images`、`sockets`、`monitoring`、`regions`、`pipes`、`tty`、
`threads`、`mach`、`audit`。

对 GUI 页签的叫法做了别名：`dylibs` → `images`、`pipePeers` → `pipes`。

`-n N` 限制行数（`regions` 这种动辄上万行的页很有用），超出部分在末尾提示；
`--json` 里对应 `truncated` / `total` 两个字段。

## 示例

```bash
# 内存占用前 10
vantage -s mem -n 10

# Chrome 相关进程的树
vantage tree -f Chrome

# 某个进程的全部线程
vantage detail 501 threads

# 找出监听中的 socket（配合 shell 过滤）
vantage detail 501 sockets | grep -i listen

# 脚本里取 RSS（字节）
vantage info 1234 --json | jq '.rss'

# 结束一个进程
vantage signal 1234 TERM
```

## 输出约定

**文本模式**是给人看的等宽表：中文按两格宽对齐，数值列右对齐，最后一列（命令行 /
路径 / 映射文件）默认截断到 96–100 列，`--wide` 关掉截断。

`list` 在终端里默认只显示 40 行（`# 731 more processes (use -n N or --json)` 提示走
stderr，不污染 stdout）；管道或重定向时输出全部 —— `vantage | wc -l` 拿到的是真实进程数。

**`--json`** 与文本同字段：

```json
{ "pid": 1, "ppid": 0, "uid": 0, "user": "root", "name": "launchd",
  "comm": "launchd", "state": "RUNNING", "readable": false,
  "rss": null, "vss": null, "threads": null, "cpuTimeNS": null,
  "started": 1794455506, "tty": "??", "pgid": 0, "nice": 0,
  "exe": "/sbin/launchd", "cmdline": "" }
```

- `readable` = `PROC_PIDTASKINFO` 是否读成功。失败时 `rss` / `vss` / `threads` /
  `cpuTimeNS` 是 `null` 而不是 `0` —— 非 root 读别的用户的进程（包括 `launchd`、
  `kernel_task`）就是这种情况，`0 B / 0 线程`是假的。
- 文本模式对同样的字段显示 `—`。
- 时间：`started` 是 Unix 秒；`cpuTimeNS` 是累计 CPU 时间的纳秒值。

`detail --json` 的形状：

```json
{ "pid": 501, "kind": "threads", "error": false,
  "headers": ["TID", "Thread Name", "..."],
  "rows": [["0x1f23b19a0", "(unnamed)", "..."]],
  "hints": ["Thread list comes from PROC_PIDLISTTHREADS …"],
  "total": 12, "truncated": 0 }
```

采集失败时 `error: true`、`headers` 为空，`rows` 里是 C 层给的错误行。
有些页（例如 `audit`）会先给表头再给错误行，这时 `error` 是 `false`、错误行在
`rows` 里 —— **退出码仍然是 2**，脚本看退出码即可。

## 双语

C 层把每个含中文的字段输出成 `\x1eL:<key>\x1f<中文>\x1f<English>\x1e`，GUI 按当前
语言取一份。CLI 用同一份标记解码（`VantageKit.Bilingual`），所以两种语言的输出都
是**完整句子**，不会出现中英混排。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 用法错误（未知命令 / 参数 / 信号名，或 `signal` 收到非正 PID） |
| 2 | 运行期失败（采集失败、找不到进程、`kill` 出错） |

`signal` 会拒绝 `pid <= 0`：`kill(0, sig)` 发给**整个进程组**，`kill(-1, …)` 发给
所有进程，这两件事都不该由一个「点错了」的命令行触发。
