#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 把 build_app.sh 产出的 .app 打包成可拖拽安装的 DMG。
#
# 用法（在仓库根目录执行）：
#   ./Scripts/build_app.sh                 # 先生成 build/Vantage.app
#   ./Scripts/make_dmg.sh                  # 默认输出 dist/Vantage.dmg
#   ./Scripts/make_dmg.sh dist/Vantage-1.0-arm64.dmg
#
# 只依赖 macOS 自带的 hdiutil / shasum，不需要 create-dmg 等第三方工具。
# 产物是 ad-hoc 签名、未公证的只读压缩镜像（UDZO）；首次打开需手动放行，
# 见 README「Known limitations」与 SECURITY.md。
set -euo pipefail
# 本脚本位于 Scripts/，所有路径都相对仓库根目录解析（从任意 cwd 调用都可用）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$(pwd)/build/Vantage.app"
OUT="${1:-$(pwd)/dist/Vantage.dmg}"

# 允许相对路径，统一转成绝对路径后再 mkdir，避免调用方 cwd 不同造成歧义。
case "$OUT" in
    /*) ;;
    *)  OUT="$(pwd)/$OUT" ;;
esac

if [ ! -d "$APP" ]; then
    echo "✗ 找不到 $APP" >&2
    echo "  请先运行 ./Scripts/build_app.sh" >&2
    exit 1
fi
if ! command -v hdiutil >/dev/null 2>&1; then
    echo "✗ hdiutil 不可用：DMG 只能在 macOS 上生成" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vantage-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# 镜像里只放两样东西：App 本身、指向 /Applications 的快捷方式。
# 不放 README / 隐藏文件，Finder 里拖一下就能装。
cp -R "$APP" "$STAGE/Vantage.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT" "$OUT.sha256"
echo "▸ hdiutil create ..."
hdiutil create \
    -volname "Vantage" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUT" >/dev/null

echo "▸ hdiutil verify ..."
hdiutil verify "$OUT" >/dev/null

# 校验文件里用相对名，下载后 `shasum -a 256 -c *.sha256` 可直接跑。
(
    cd "$(dirname "$OUT")"
    shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)

echo ""
echo "✓ DMG:      $OUT"
echo "  SHA-256:  $(cut -d' ' -f1 < "$OUT.sha256")"
echo "  校验文件: $OUT.sha256"
echo ""
echo "  未做 Apple 公证：首次打开若被 Gatekeeper 拦截，"
echo "  请右键 App → 打开，或在「系统设置 → 隐私与安全性」中允许。"
echo ""
