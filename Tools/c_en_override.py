# SPDX-License-Identifier: MIT
# -*- coding: utf-8 -*-
"""C 层运行时文本的手工英文译文（字段级）。

key = C 源码里字符串字面量的**原始文本**（\t / \n 是两字符转义，不是真制表/换行）。
value = 英文字段，printf 占位符数量与顺序必须与 key 完全一致（生成器会校验）。

其余字段从 l10n_master.py 的 MASTER / PHRASES 精确匹配自动复用。
改文案只改这里 + 跑 Tools/build_l10n.py。
"""

C_EN_OVERRIDE = {
 "pmgr %u 张频率表（CPU 单位 %s）· E≤%uMHz / P≤%uMHz / GPU≤%uMHz · 温度走 SMC，读不到回退 IOHID":
  "pmgr %u DVFS tables (CPU unit %s) · E≤%uMHz / P≤%uMHz / GPU≤%uMHz · temperature via SMC, fallback to IOHID",
 r"\n实时频率由 P-state residency 按 pmgr 频率表索引反查（macmon 的 take(freqs.len()) 口径）":
  r"\nLive frequency from P-state residency indexed into pmgr tables (macmon take(freqs.len()) method)",
 "公开层：CPU / 内存 / Swap / 磁盘(IOBlockStorageDriver) / 网络(getifaddrs) 始终可用":
  "Public layer: CPU / memory / swap / disk (IOBlockStorageDriver) / network (getifaddrs) always available",
 "proc_bsdinfo.e_tdev / kinfo_proc.kp_eproc.e_tdev，BSD 层，不依赖 task port":
  "proc_bsdinfo.e_tdev / kinfo_proc.kp_eproc.e_tdev, BSD layer, no task port needed",
 r"\n功耗只取 Energy Model 组的精确通道（macmon 口径）；SoC 分项与 SMC PSTR 整机功率不可相加":
  r"\nPower uses only exact Energy Model channels (macmon method); SoC breakdown and SMC PSTR system power are not additive",
 r"\n提示：功耗与实时频率需要 libIOReport.dylib；VM / Intel Mac / 未来系统版本可能不提供":
  r"\nNote: power and live frequency require libIOReport.dylib; VM / Intel Mac / future systems may not provide it",
 "macOS 不提供数字 SID；ps -o sess 打印的是内核 session 指针，可用 PGID/TPGID 推断":
  "macOS has no numeric SID; ps -o sess prints a kernel session pointer — infer from PGID/TPGID",
 "FSEVENTS=文件事件监听，NETPOLICY/CHANNEL/NEXUS=网络与 Skywalk 描述符；":
  "FSEVENTS=file event monitor, NETPOLICY/CHANNEL/NEXUS=network and Skywalk descriptors;",
 r"\n提示：整机功率(PSTR)需要 AppleSMC user client；温度仍可能由 IOHID 提供":
  r"\nNote: system power (PSTR) requires the AppleSMC user client; temperature may still come from IOHID",
 "FD=%d (vnode=%d socket=%d pipe=%d kqueue=%d 其他=%d)":
  "FD=%d (vnode=%d socket=%d pipe=%d kqueue=%d other=%d)",
 "共 %d 个内存映射 region（来源：libproc PROC_PIDREGIONINFO）":
  "%d memory-mapped regions (source: libproc PROC_PIDREGIONINFO)",
 "来自 sysctl 风格的 csops(CS_OPS_STATUS)，无需 task port":
  "from sysctl-style csops(CS_OPS_STATUS), no task port needed",
 r"\n下方「逐通道诊断」列出实际计入的能量通道 W 值、P-state 状态名与温度原始传感器":
  r"\nPer-channel diagnostics below list the energy channels actually counted (W), P-state names and raw temperature sensors",
 "PIPE=管道，KQUEUE=事件队列，PSHM/PSEM=POSIX 共享内存/信号量，":
  "PIPE=pipe, KQUEUE=event queue, PSHM/PSEM=POSIX shared memory/semaphore,",
 r"[pmgr] %d 张表，CPU 表单位=%s，GPU 表 %d 档(%u..%u)：\n":
  r"[pmgr] %d tables, CPU table unit=%s, GPU table %d steps (%u..%u):\n",
 r"[IOHID] 核心 CPU=%d GPU=%d PMU=%d（其余只记录不参与平均）\n":
  r"[IOHID] core CPU=%d GPU=%d PMU=%d (others logged only, not averaged)\n",
 r"\n分簇利用率按核心序号启发式分组（E 核在前），不代表 perflevel 的精确映射":
  r"\nPer-cluster usage is a heuristic by core index (E cores first), not an exact perflevel mapping",
 "通常是其他用户的 pty / 权限限制；只读打开且带 O_NOCTTY，不影响目标进程":
  "usually another user's pty / permission limit; opened read-only with O_NOCTTY, does not affect the target process",
 "Darwin dev_t 编码（major 高 12 位 / minor 低 8 位）":
  "Darwin dev_t encoding (major in high 12 bits / minor in low 8 bits)",
 r"[SMC] open=%d #KEY=%u 枚举到 T* 键=%d F* 键=%d\n":
  r"[SMC] open=%d #KEY=%u enumerated T* keys=%d F* keys=%d\n",
 "若同时出现上亿的 FD 号，则是 FD 列表解析异常，请对照「文件监控」页的合计数字":
  "if FD numbers in the hundreds of millions also appear, the FD list was misparsed — compare with the Monitoring tab total",
 r"\n网络为 32 位计数器差分（第三方签名下内核按 1KiB 批量化，数值为近似）":
  r"\nNetwork is a 32-bit counter delta (kernel batches in 1 KiB for third-party signatures; approximate)",
 "对端 PID %d (%s) FD %d — 同一进程（fork 共享 / 自环）":
  "peer PID %d (%s) FD %d — same process (fork-shared / self-loop)",
 "类型列是内核 proc_fdtype：VNODE=磁盘文件，SOCKET=套接字，":
  "Type column is the kernel proc_fdtype: VNODE=disk file, SOCKET=socket,",
 "proc_pidinfo(PROC_PIDREGIONINFO) 失败（%s）":
  "proc_pidinfo(PROC_PIDREGIONINFO) failed (%s)",
 "全局扫描 %d 个进程 / %d 个 pipe 端点，本页解析出 %d 个对端":
  "scanned %d processes / %d pipe endpoints system-wide; %d peers resolved on this tab",
 r"[IOHID] 无核心传感器，改用 PMU tdie 平均（非核心热点）\n":
  r"[IOHID] no core sensors, using PMU tdie average (not a core hotspot)\n",
 "IOReport %s · SMC %s · DVFS %s · 热压 %s":
  "IOReport %s · SMC %s · DVFS %s · thermal pressure %s",
 "region 数达到上限 %d，结果已截断（可在偏好设置「采集上限」中调整）":
  "region cap %d reached, results truncated (adjustable in Preferences → Collection Limits)",
 "pgid == tpgid 即前台（ps 的 STAT 里 + 号同理）":
  "pgid == tpgid means foreground (same as the + in ps STAT)",
 "task_name_for_pid 取得（只读，可 task_info）":
  "from task_name_for_pid (read-only, task_info allowed)",
 "%d 个 socket FD 全部读取失败（errno=%d: %s）":
  "all %d socket FDs failed to read (errno=%d: %s)",
 r"  table%-3d %-5s %2d 档 %u..%u MHz\n":
  r"  table%-3d %-5s %2d steps %u..%u MHz\n",
 r"[SMC] 有效温度读数=%d 归类 CPU=%d GPU=%d\n":
  r"[SMC] valid temperature readings=%d classified CPU=%d GPU=%d\n",
 "输入 / 输出（cfgetispeed / cfgetospeed）":
  "input / output (cfgetispeed / cfgetospeed)",
 "vnode=%d（路径失败 %d）, 其他=%d, FD 总数=%d":
  "vnode=%d (path failures %d), other=%d, FD total=%d",
 "TASK_DYLD_INFO 可用（精确镜像列表见「已加载镜像」页）":
  "TASK_DYLD_INFO available (exact image list on the Images tab)",
 "UNKNOWN(n) 表示内核出现了本版本尚未收录的 FD 类型；":
  "UNKNOWN(n) means the kernel reported an FD type this build does not know; ",
 "PROC_TTY_ONLY 按 e_tdev 过滤（上限 200）":
  "PROC_TTY_ONLY filters by e_tdev (cap 200)",
 "(FSEvents 文件系统事件监听 fd，无 vnode 路径)":
  "(FSEvents file-system event fd, no vnode path)",
 "canonical / echo / 信号 / 扩展 / 后台写停":
  "canonical / echo / signals / extended / background write stop",
 "CS_PLATFORM_BINARY (Apple 平台二进制)":
  "CS_PLATFORM_BINARY (Apple platform binary)",
 r"[IOReport] delta 通道 %ld，精确过滤后：\n":
  r"[IOReport] delta channels %ld, after exact filtering:\n",
 "(网络策略 netpolicy fd，无 vnode 路径)":
  "(netpolicy fd, no vnode path)",
 "(未发现已加载镜像，或目标进程不是 Mach-O 用户进程)":
  "(no loaded images found, or the target is not a Mach-O user process)",
 "(Skywalk nexus 描述符，无 vnode 路径)":
  "(Skywalk nexus descriptor, no vnode path)",
 "无法读取 proc_bsdinfo（%s）；进程可能已退出":
  "cannot read proc_bsdinfo (%s); process may have exited",
 "NODEV / 0 表示无；GUI 应用与守护进程通常没有":
  "NODEV / 0 means none; GUI apps and daemons usually have no controlling terminal",
 "task_name_for_pid 失败 (kr=%d)":
  "task_name_for_pid failed (kr=%d)",
 "sysctl(KERN_PROCARGS) 失败（%s）":
  "sysctl(KERN_PROCARGS) failed (%s)",
 "对端 PID %d (%s) FD %d — 已连接":
  "peer PID %d (%s) FD %d — connected",
 "(AppleTalk 套接字，无 vnode 路径)":
  "(AppleTalk socket, no vnode path)",
 "socket FD=%d，成功解析=%d，失败=%d":
  "socket FD=%d, parsed=%d, failed=%d",
 "TIOCGPGRP（可与上方 e_tpgid 对照）":
  "TIOCGPGRP (compare with e_tpgid above)",
 "pbi_pjobc：该进程组里仍关联此终端的作业数":
  "pbi_pjobc: jobs in this process group still attached to this terminal",
 "扫描 %d 个进程 / %d 个 pipe 端点":
  "scanned %d processes / %d pipe endpoints",
 "(channel 描述符，无 vnode 路径)":
  "(channel descriptor, no vnode path)",
 "来自 csops(CS_OPS_TEAMID)":
  "from csops(CS_OPS_TEAMID)",
 "(内核新增 FD 类型，无 vnode 路径)":
  "(new kernel FD type, no vnode path)",
 "(kqueue，事件监听状态见「文件监控」页)":
  "(kqueue; see the Monitoring tab for event state)",
 "(socket，协议/地址见「网络连接」页)":
  "(socket; see the Network tab for protocol/address)",
 "无终端显示为 ??（ps 的 TT 列同理）":
  "no terminal shows as ?? (same as the ps TT column)",
 "(vnode 文件，见上方 VNODE 行)":
  "(vnode file, see the VNODE rows above)",
 "无控制终端（守护进程 / GUI 应用常见）":
  "no controlling terminal (common for daemons / GUI apps)",
 "补充 (kind / type / PCB)":
  "Extra (kind / type / PCB)",
 "像素 %u × %u（TIOCGWINSZ）":
  "pixels %u × %u (TIOCGWINSZ)",
 "无法读取 proc_bsdinfo（%s）":
  "cannot read proc_bsdinfo (%s)",
 "devname_r 或 /dev 扫描反查":
  "devname_r or /dev scan reverse lookup",
 "普通文件 / 目录（完整路径见「文件」页）":
  "regular file / directory (full path on the File tab)",
 "(该进程当前没有 socket 描述符)":
  "(this process currently has no socket descriptors)",
 "pipe=%d 已解析=%d 自环=%d":
  "pipe=%d resolved=%d self-loops=%d",
 "对端已关闭 / 内核持有 / 无权限枚举":
  "peer closed / held by kernel / not permitted to enumerate",
 "(无环境变量，可能是内核任务或守护进程)":
  "(no environment variables; may be a kernel task or daemon)",
 "(POSIX 共享内存对象，无文件路径)":
  "(POSIX shared memory object, no file path)",
 "这些对象没有 vnode 路径，属正常":
  "these objects have no vnode path — this is normal",
 "(没有 vnode 类型的已打开文件)":
  "(no open files of vnode type)",
 "同一进程（fork 共享 / 自环）":
  "same process (fork-shared / self-loop)",
 "%s（非 vnode 或读取失败）":
  "%s (not a vnode or read failed)",
 "(POSIX 信号量，无文件路径)":
  "(POSIX semaphore, no file path)",
 "(管道，对端进程见「文件监控」页)":
  "(pipe; see the Monitoring tab for the peer process)",
 "TIOCGWINSZ 失败（%s）":
  "TIOCGWINSZ failed (%s)",
 "TIOCGPGRP 失败（%s）":
  "TIOCGPGRP failed (%s)",
 "tcgetattr 失败（%s）":
  "tcgetattr failed (%s)",
 "kqueue 状态（事件监听）":
  "kqueue state (event monitoring)",
 "%d 个前台 / %d 个列出":
  "%d foreground / %d listed",
 "数据异常（%zu bytes）":
  "malformed data (%zu bytes)",
 "说明（含 pipe 对端进程）":
  "Description (incl. pipe peer process)",
 "读取 PIPEINFO 失败":
  "failed to read PIPEINFO",
 "无法读取 FD 列表（%s）":
  "cannot read FD list (%s)",
 "KQUEUEINFO 不可用":
  "KQUEUEINFO unavailable",
 "终端前台进程组 TPGID":
  "Terminal foreground PGID (TPGID)",
 "termios 本地模式":
  "termios local mode",
 "PIPEINFO 不可用":
  "PIPEINFO unavailable",
 " · P%u/E%u 核":
  " · P%u/E%u cores",
 "%u 行 × %u 列":
  "%u rows × %u columns",
 " · GPU %u 核":
  " · GPU %u cores",
 "(路径读取失败：%s)":
  "(path read failed: %s)",
 "会话 ID (SID)":
  "Session ID (SID)",
 "termios 波特率":
  "termios baud rate",
 "控制终端 e_tdev":
  "Controlling terminal e_tdev",
 "共 %d 个镜像条目":
  "%d image entries",
 "共 %d 个环境变量":
  "%d environment variables",
 "大小 (bytes)":
  "Size (bytes)",
 " · 与控制终端一致":
  " · same as controlling terminal",
 "终端未设置前台进程组":
  "terminal has no foreground process group",
 "标准输出 FD 1":
  "Standard output FD 1",
 "标准输入 FD 0":
  "Standard input FD 0",
 "PGID / 会话":
  "PGID / session",
 "标准错误 FD 2":
  "Standard error FD 2",
 "是否进程组首进程":
  "Process group leader",
 "调用失败（%s）":
  "call failed (%s)",
 " · 已被重定向":
  " · redirected",
 "读取失败（%s）":
  "read failed (%s)",
 "主 / 次设备号":
  "Major / minor device number",
 "性能采样尚未启动":
  "performance sampling has not started",
 "CS 标志位明细":
  "CS flag details",
 "设备前台进程组":
  "Device foreground PGID",
 "不可读（%s）":
  "unreadable (%s)",
 "短名 %.*s":
  "short name %.*s",
 "终端窗口大小":
  "Terminal window size",
 "有无控制终端":
  "Controlling terminal",
 "(未知路径)":
  "(unknown path)",
 "(全部关闭)":
  "(all closed)",
 "(匿名映射)":
  "(anonymous mapping)",
 " ← 当前":
  " ← current",
 "同终端进程":
  "Processes on same terminal",
 "同终端合计":
  "Same-terminal total",
 "内存不足":
  "out of memory",
 "设备路径":
  "Device path",
 "(空值)":
  "(empty value)",
 "设备属性":
  "Device attributes",
 "不可读":
  "Unreadable",
 "已连接":
  "Connected",
 "索引":
  "Index",
 "合计":
  "Total",
 "可用":
  "Available",
 "错误":
  "Error",
 "结果":
  "Result",
 "有":
  "Yes",
 "无":
  "No",
 "否":
  "No",
}
