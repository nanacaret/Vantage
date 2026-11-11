# 新建仓库初始化清单

这份清单用于把当前源码推到一个**全新的 GitHub 仓库**。逐项确认后再 `git push`。
工程本身已经是可直接 `swift build -c release` 的完整仓库，不需要额外转换。

## 1. 确认发布身份

仓库已按 **nanacaret** 组织身份设定，推送前核对一遍：

| 位置 | 已设定值 |
|---|---|
| GitHub 仓库地址 | `github.com/nanacaret/Vantage`（中英文 README 的 clone URL、本文件末尾 `git remote` 示例） |
| `LICENSE` 版权行 | `Copyright (c) 2026 nanacaret` |
| `Packaging/Info.plist` → `NSHumanReadableCopyright` | `Copyright © 2026 nanacaret. Licensed under MIT.` |
| README 版权行 | `© 2026 nanacaret` |
| `Packaging/Info.plist` → `CFBundleIdentifier` | `io.github.nanacaret.Vantage`（按 GitHub 组织的反向域名惯例） |
| `Packaging/Info.plist` → `CFBundleShortVersionString` / `CFBundleVersion` | `1.0` / `1` |

全仓库已无仓库地址占位符（原先的 OWNER 占位符已替换为 nanacaret）。若组织使用自有域名，
可把 Bundle ID 换成对应反向域名；**改 ID 会让已保存的偏好与窗口位置失效**，
本项目尚未分发，无存量数据需要考虑。`Packaging/Info.plist` 的
`NSAccessibilityUsageDescription` 为中英双语文案，可按需本地化到 `InfoPlist.strings`。

## 2. 截图（已就位）

`docs/screenshots/` 下已有 5 张实机截图，两份 README 都引用了它们：

| 文件 | 用途 | README 位置 |
|---|---|---|
| `main.png` | 主窗口：进程树、14 列、检查器概览页 | 标题下方主视觉 |
| `performance.png` | 性能监控（⌘P） | 「界面预览 / Screenshots」 |
| `devices.png` | 设备树（⌘⌥B）选中节点 + 属性表 | 「界面预览 / Screenshots」 |
| `global-search.png` | 全局搜索（⌘⇧F） | 「界面预览 / Screenshots」 |
| `window-list.png` | 窗口列表 | 「界面预览 / Screenshots」 |

替换或补图时的要求：PNG、Retina 尺寸可直接用（建议宽度 ≥ 1200px）；**不要**带上
真实用户名、`/Users/...` 路径、正在运行的敏感进程名或未授权弹窗。中英文 README
共用同一套图片，图内文字跟随截图时的界面语言即可（当前这套为英文）。

可选补充：`inspector.png`（独立检查器窗口、展示 13 个页签）、`preferences.png`
（⌘, 偏好设置，展示可配置项与配色）、`window-picker.png`（准星选取 / 窗口列表）。
加图后记得同步更新两份 README 与上表。

## 3. 隐私与权限文案

- `Packaging/Info.plist` 的 `NSAccessibilityUsageDescription` 说明辅助功能用途；
- 窗口标题依赖「屏幕录制」授权，但没有对应的 Info.plist key（该 API 由系统级
  TCC 控制，弹窗由系统显示），界面里已给出「授权窗口标题…」入口；
- 若改成自己签名分发，请复核 `Packaging/Vantage.entitlements` 里的
  `com.apple.security.cs.debugger` 是否仍符合你的签名方式。

## 4. 生成资源与可复现性

生成文件已入库，因此 `swift build` 不需要 Python。推送前跑一次确认没有漂移：

```bash
python3 Tools/build_l10n.py
git diff --exit-code        # 应无任何输出
swift build -c release      # 应零 error、零 warning
./Scripts/build_app.sh      # 应能生成 build/Vantage.app
open build/Vantage.app
```

若 `git diff` 有内容，说明有人手工改了生成文件，先查
[`CONTRIBUTING.md`](../CONTRIBUTING.md) 的「不要手工编辑」清单。

## 5. 确认没有误提交的文件

```bash
git status --ignored | head -50
```

确认以下都**没有**进入版本库：

- `build/`、`*.app`、`.build/`、`.swiftpm/`
- `Tools/c_l10n_generated.json`、`__pycache__/`
- `.DS_Store`、`*.p12` / `*.cer` / `*.provisionprofile`、`.env*`
- 私钥、证书、本地生成的 `dist/*.dmg`、本地崩溃报告

`.gitignore` 已覆盖上述条目，但首次 `git add -A` 前值得再看一眼。

反过来，`Scripts/`（构建与打包脚本）与 `Packaging/`（`Info.plist`、entitlements）**是要入库的源文件**，
不要当成生成物清掉；被忽略的只是它们运行后产生的 `build/` 与 `dist/`。根目录只保留
文档、`LICENSE`、`.gitignore`、`.github/` 与 SwiftPM 必需的 `Package.swift`。

## 6. 仓库设置建议

- Description：`A native macOS process manager and system monitor in C + Swift/AppKit`
- Topics：`macos` `swift` `appkit` `process-manager` `system-monitor` `ioregistry` `apple-silicon` `devtools`
- 开启 Issues；可选开启 Discussions
- **Settings → Actions → General → Workflow permissions 选
  `Read and write permissions`** —— `nightly` / tag Release 需要 `contents: write`，
  默认的只读权限会让发布步骤失败
- 在 Settings → Security 里启用 **Private vulnerability reporting**，让 `SECURITY.md` 里的
  私有报告通道可用
- About 里指向 `README.zh-Hans.md` 的中文说明（可选）
- 默认分支 `main`

## 7. CI：自动编译与 DMG 发行

`.github/workflows/build.yml` 已就绪，push 即触发，无需额外配置：

| 事件 | 行为 |
|---|---|
| 任意 push / PR | `macos-26` + Xcode 26.5 SDK：`swift build -c release` → `.app` → `dist/*.dmg` + SHA-256，上传为 Actions artifact（保留 14 天） |
| push 到 `main` | 额外更新 `nightly` **滚动预发布**：asset 名固定（`Vantage-nightly-<arch>.dmg`），`--clobber` 覆盖，并让该 tag 跟随最新 commit |
| push `v*` tag | 创建该 tag 的正式 Release，附 `Vantage-<version>-<arch>.dmg` |
| `workflow_dispatch` | 等同手动触发一次 main 构建 |

流程先跑 `python3 Tools/build_l10n.py` 并 `git diff --exit-code` 校验生成资源没有漂移，
再依次调用 `./Scripts/build_app.sh`、`./Scripts/make_dmg.sh`。DMG 只依赖 macOS 自带的
`hdiutil` / `shasum` / `gh`，不使用 `create-dmg` 之类第三方工具；除官方
`checkout` / `*-artifact` 外没有第三方 action。

**Runner 与 SDK**：build job 跑在 `macos-26`，并显式把 `DEVELOPER_DIR` 指向
`/Applications/Xcode_26.5.app/Contents/Developer` —— 与开发机（macOS 26.4 +
26.5 SDK）保持一致。镜像轮换若不再提供 26.5，会退回默认 Xcode 并告警，不会让构建
直接失败；Toolchain 步骤会打印 `xcrun --show-sdk-version` 便于核对。

不要用 `macos-15`：它默认 Xcode 16.4 / macOS 15 SDK，比 26.5 老两代。虽然代码里的
兼容处理大多是 SDK 无关的，但 CI 验证的产物就与实机跑的不是同一套编译结果；
且该镜像上的 Xcode 26.x 最高只到 26.3，没有 26.5。`macos-14` 已于
2026-11-02 退役，更不能选。

注意 **SDK ≠ 部署目标**：`Package.swift` 里是 `.macOS(.v12)`，用 26 SDK 编译出的
`.app` 仍可在 macOS 12+ 运行。`macos-26` 也提供 `macos-26-intel` 标签，若要
universal 二进制，可在 matrix 里加一个 Intel runner 再用 `lipo -create` 合并；
当前文件名里的 `<arch>` 来自 `uname -m`（arm64 runner 上是 `arm64`）。

**签名与公证**：CI 没有 Developer ID 证书，产物是 ad-hoc 签名、**未公证**的 DMG。
首次打开被 Gatekeeper 拦截时，右键 `Vantage.app` → 打开，或在「系统设置 →
隐私与安全性」中允许。正式分发需自行用 Apple Developer 账号签名 + 公证，并自行承担
私有 API 带来的审核风险；`SECURITY.md` 的免责说明不变。

Fork 上的 push 会在**该 fork 自己**的仓库里发 `nightly`，不会写到上游；PR 只构建、
不发布（fork 的 token 是只读的）。

本地复现同一份产物：

```bash
./Scripts/build_app.sh
./Scripts/make_dmg.sh dist/Vantage-local.dmg
```

## 8. 仓库说明里必须保留的免责说明

- 使用未公开的 macOS 私有接口，可能随系统更新失效；
- 不适用于 Mac App Store，未做公证；CI 产出的 DMG 需用户手动放行 Gatekeeper
  （见 README「预构建 DMG / Prebuilt DMG」）；
- 功耗 / 频率 / 分簇利用率为诊断参考值，不是标定测量结果；
- 不需要 root，SIP 下也无法读取其他进程内存；
- 见 `README.md` 的 Known limitations & disclaimer、`SECURITY.md`。

## 9. 最后一遍

```bash
grep -rn 'SPDX-License-Identifier' Sources Tools | wc -l   # 应与源码文件数一致
grep -rn '/Users/\|/tmp/' --include='*.swift' --include='*.c' --include='*.h' . | head
```

第二条应无输出：源码里不应出现个人路径。确认无误后：

```bash
git init && git add -A && git commit -m "Initial commit: Vantage"
git remote add origin git@github.com:nanacaret/Vantage.git
git push -u origin main
```
