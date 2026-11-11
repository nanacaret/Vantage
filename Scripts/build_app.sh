#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 编译 SwiftPM 工程并组装成可双击的 .app bundle
set -euo pipefail
# 本脚本位于 Scripts/，所有路径都相对仓库根目录解析（从任意 cwd 调用都可用）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▸ swift build -c release ..."
swift build -c release

# 只解析 manifest 并打印路径，不会触发第二次编译（<1s）。
BIN="$(swift build -c release --show-bin-path)"
APP="$(pwd)/build/Vantage.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Vantage" "$APP/Contents/MacOS/Vantage"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Vantage"

# 本地化资源：L10n 优先读 Bundle.main 里的 en.lproj/Localizable.strings，
# 读不到时退回编译进二进制的内嵌表，所以 swift run 也能正常显示英文。
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

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --entitlements Packaging/Vantage.entitlements "$APP" \
        2>/dev/null || codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo ""
echo "✓ 已生成: $APP"
echo "  运行:   open \"$APP\""
echo "  调试:   swift run"
echo ""
echo "  无需 root：全部采集走 libproc / sysctl / IOReport / SMC 公开或私有接口。"
echo "  SIP 开启时 root 也拿不到受保护进程的 task_for_pid，详见 README「权限说明」。"
