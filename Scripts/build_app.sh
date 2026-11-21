#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 编译 SwiftPM 工程并组装成可双击的 .app bundle
#
#   ./Scripts/build_app.sh [version]      # 省略 version → nightly
set -euo pipefail
# 本脚本位于 Scripts/，所有路径都相对仓库根目录解析（从任意 cwd 调用都可用）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 某些环境（如受限沙箱）里 SwiftPM 跑 manifest 会报
#   sandbox-exec: sandbox_apply: Operation not permitted
# 这时可以用 VANTAGE_SWIFT_FLAGS="--disable-sandbox" 覆盖。
SWIFT_FLAGS="${VANTAGE_SWIFT_FLAGS:-}"

# ---- 版本注入 ----
# 版本只有一个来源：调用参数。CI 在 tag 触发时传 tag（v1.2.5 → 1.2.5），
# PR / 手动触发传 nightly；本地不传就是 nightly：
#   ./Scripts/build_app.sh            → nightly
#   ./Scripts/build_app.sh 1.2.5      → 1.2.5
# 同一个值写进 ① CLI 的编译期常量（`--version` 直接读，运行时不碰文件系统），
# ② 产物里的 Info.plist（About 面板、Touch ID helper 读它），③ DMG 文件名（CI 那边
# 用同一个值）。仓库里不写死任何发布版本号，见 docs/PUBLISHING.md。
#
# 注入逻辑在 Scripts/inject_version.py：正则改 Swift 常量、PlistBuddy 改 plist，
# 幂等（值没变就不写文件），失败即非零退出。
VERSION="${1:-nightly}"

python3 Scripts/inject_version.py "$VERSION" --swift Sources/VantageCLI/BuildVersion.swift

echo "▸ swift build -c release $SWIFT_FLAGS ..."
swift build -c release $SWIFT_FLAGS

# 只解析 manifest 并打印路径，不会触发第二次编译（<1s）。
BIN="$(swift build -c release $SWIFT_FLAGS --show-bin-path)"
APP="$(pwd)/build/Vantage.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS/bin" "$APP/Contents/Resources"

cp "$BIN/Vantage" "$APP/Contents/MacOS/Vantage"
chmod +x "$APP/Contents/MacOS/Vantage"

# 辅助可执行文件放 Contents/MacOS/bin/，理由（都实测过）：
#   * Apple《Bundle Programming Guide》Table 2-5 对 MacOS 的原文是「you may put
#     other standalone executables (such as command-line tools) in this directory
#     as well」；Resources / SharedSupport 的定义是资源文件，不是代码；
#   * codesign 的 nested code 规则只覆盖 Frameworks / SharedFrameworks / PlugIns /
#     XPCServices / Helpers / MacOS / Library/{Automator,Spotlight,LoginItems}。
#     同一个 Mach-O 放 MacOS/bin 会进 CodeResources 的 files2（cdhash requirement，
#     按代码校验），放 Resources/bin 只进 files（文件哈希，按数据封存）——
#     后者签名坏了也发现不了；
#   * 目录分开了，CLI 就能叫回 `vantage`：大小写不敏感只在同一个目录里才会和
#     `Vantage` 撞名。SPM 产物仍叫 vantage-cli，因为 .build/release/ 下两个产物
#     同名会直接撞车。
if [ -x "$BIN/vantage-cli" ]; then
    cp "$BIN/vantage-cli" "$APP/Contents/MacOS/bin/vantage"
fi
# MCP stdio 服务：MCP 客户端可以直接指向
# build/Vantage.app/Contents/MacOS/bin/vantage-mcp，不用另外找 .build 路径。
if [ -x "$BIN/vantage-mcp" ]; then
    cp "$BIN/vantage-mcp" "$APP/Contents/MacOS/bin/vantage-mcp"
fi
# 先拷源 plist（模板，版本号是占位的 nightly），再把这次构建的版本注入产物那份
# ——源文件永远不被改，About 面板与 Touch ID helper 读的都是注入后的值。
cp Packaging/Info.plist "$APP/Contents/Info.plist"
python3 Scripts/inject_version.py "$VERSION" --plist "$APP/Contents/Info.plist"

# 本地化资源：L10n 优先读 Bundle.main 里的 en.lproj/Localizable.strings，
# 读不到时退回编译进二进制的内嵌表，所以 swift run 也能正常显示英文。
# AppleScript 术语表：必须放在 Resources 根目录，并由 Info.plist 的
# OSAScriptingDefinition 指向；缺了它 osascript 只能看到标准套件。
for SDEF in Resources/*.sdef; do
    if [ -f "$SDEF" ]; then cp "$SDEF" "$APP/Contents/Resources/"; fi
done

for LPROJ in Resources/*.lproj; do
    # 用 if 而非 `&&`：set -e 下 glob 无匹配时 `[ -d ]` 失败会直接退出脚本
    if [ -d "$LPROJ" ]; then cp -R "$LPROJ" "$APP/Contents/Resources/"; fi
done

# App Icon：优先用系统 iconutil 从 iconset 现生成（Xcode CLT 自带，最规范）；
# 不可用时退回仓库里预置的 Vantage.icns（PNG 内嵌，跨平台构造，格式等价）。
ICON_DST="$APP/Contents/Resources/Vantage.icns"
if command -v iconutil >/dev/null 2>&1 && [ -d "Assets/Vantage.iconset" ]; then
    iconutil -c icns "Assets/Vantage.iconset" -o "$ICON_DST" 2>/dev/null \
        || cp "Assets/Vantage.icns" "$ICON_DST"
else
    cp "Assets/Vantage.icns" "$ICON_DST"
fi

# 签名顺序：先 MacOS/bin 里的可执行文件，再整个 bundle。外层签名会把 nested code
# 的签名封进去；反过来（先签外层）子组件只会被当成普通资源，之后再单独签它们
# 会让外层签名当场失效。
if command -v codesign >/dev/null 2>&1; then
    for TOOL in "$APP"/Contents/MacOS/bin/*; do
        if [ -f "$TOOL" ]; then
            codesign --force --sign - --entitlements Packaging/Vantage.entitlements "$TOOL" \
                2>/dev/null || codesign --force --sign - "$TOOL" 2>/dev/null || true
        fi
    done
    codesign --force --sign - --entitlements Packaging/Vantage.entitlements "$APP" \
        2>/dev/null || codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo ""
echo "✓ 已生成: $APP"
echo "  版本:   $VERSION"
echo "  运行:   open \"$APP\""
echo "  调试:   swift run"
echo "  命令行: \"$APP/Contents/MacOS/bin/vantage\" list"
echo ""
echo "  无需 root：全部采集走 libproc / sysctl / IOReport / SMC 公开或私有接口。"
echo "  SIP 开启时 root 也拿不到受保护进程的 task_for_pid，详见 README「权限说明」。"
