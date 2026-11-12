#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 把 build_app.sh 产出的 .app 打包成「拖到 Applications 安装」的 UDZO 镜像。
#
# 用法（在仓库根目录执行）：
#   ./Scripts/build_app.sh                 # 先生成 build/Vantage.app
#   ./Scripts/make_dmg.sh                  # 默认输出 dist/Vantage.dmg
#   ./Scripts/make_dmg.sh dist/Vantage-1.0-arm64.dmg
#
# 主路径用 macOS 26 Tahoe 引入的 `diskutil image`（macOS 27 起 Apple 用它
# 取代 hdiutil）；只依赖系统自带的 diskutil / shasum / osascript / python3，
# 不需要 create-dmg 等第三方工具，也不需要 CI 装 Pillow（背景图已入库）。
# 旧系统没有 `diskutil image`、或该路径任一步失败时，自动回退到 hdiutil。
#
# 两种视图都可用：
#   · 有 GUI 会话（本地）：Finder 窗口显示背景图、箭头、四个图标的定位，
#     直接把 Vantage.app 拖到 Applications 即可。
#   · 无 GUI 会话（GitHub Actions）：Finder 自动化会超时/被拒，脚本自动降级，
#     DMG 内仍保留 README.txt（拖拽说明）与 Install.command（双击一键安装）。
# 产物是 ad-hoc 签名、未公证的只读压缩镜像（UDZO），见 README / SECURITY.md。
set -euo pipefail
# 本脚本位于 Scripts/，所有路径都相对仓库根目录解析（从任意 cwd 调用都可用）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$(pwd)/build/Vantage.app"
BG="$(pwd)/Packaging/dmg-background.png"
OUT="${1:-$(pwd)/dist/Vantage.dmg}"
VOLNAME="Vantage"

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
if [ ! -f "$BG" ]; then
    echo "✗ 找不到背景图 $BG" >&2
    echo "  运行 python3 Tools/make_dmg_bg.py 重新生成" >&2
    exit 1
fi
command -v shasum >/dev/null 2>&1 || {
    echo "✗ shasum 不可用：DMG 只能在 macOS 上生成" >&2
    exit 1
}

mkdir -p "$(dirname "$OUT")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vantage-dmg.XXXXXX")"  # 镜像内容
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vantage-work.XXXXXX")"   # 可写镜像 / AppleScript
MNT_HDI="$(mktemp -d "${TMPDIR:-/tmp}/vantage-mnt.XXXXXX")" # hdiutil 自定义挂载点
RW="$WORK/rw.dmg"
AS="$WORK/view.applescript"
ACTIVE_DEV=""      # diskutil 路径：attach 得到的顶层 /dev/diskN
ACTIVE_MNT=""      # diskutil 路径：实际挂载点
HDI_ATTACHED=0     # hdiutil 路径：是否已 attach
VIEW="plain"
BG_OK=0            # Finder 是否真的接受了背景图（osascript 读回结果）
TOOL=""

cleanup() {
    if [ -n "$ACTIVE_DEV" ] && command -v diskutil >/dev/null 2>&1; then
        diskutil eject "$ACTIVE_DEV" -quiet >/dev/null 2>&1 || true
    elif [ -n "$ACTIVE_MNT" ] && [ -d "$ACTIVE_MNT" ] && command -v diskutil >/dev/null 2>&1; then
        diskutil eject "$ACTIVE_MNT" -quiet >/dev/null 2>&1 || true
    fi
    if [ "$HDI_ATTACHED" -eq 0 ] && [ -d "$MNT_HDI" ] && command -v hdiutil >/dev/null 2>&1; then
        hdiutil detach "$MNT_HDI" -force -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE" "$WORK" "$MNT_HDI"
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# 1. 镜像内容（两条路径共用）
# ---------------------------------------------------------------------
cp -R "$APP" "$STAGE/Vantage.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/dmg-background.png"

cat > "$STAGE/README.txt" <<'EOF'
Vantage — 安装 / Install
========================

1) 把 Vantage.app 拖到 Applications 图标上（背景图里的箭头）。
   Drag Vantage.app onto the Applications icon (see the arrow on the background).

2) 如果打开 DMG 后没有出现引导背景，也可以手动拖：
   If the guided background does not appear, drag it manually.

3) 或者双击 Install.command，在终端里一键拷贝：
   Or double-click Install.command to copy it into /Applications.

提示 / Note
----------
这是 ad-hoc 签名、未公证的构建。首次打开若被 Gatekeeper 拦截，
右键 App → 打开，或在「系统设置 → 隐私与安全性」中允许。
This build is ad-hoc signed and not notarized. If Gatekeeper blocks it,
right-click the app → Open, or allow it in System Settings → Privacy & Security.
EOF

cat > "$STAGE/Install.command" <<'EOF'
#!/bin/bash
# SPDX-License-Identifier: MIT
# 双击即可把同目录下的 Vantage.app 安装到 /Applications。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/Vantage.app"
DST="/Applications/Vantage.app"
if [ ! -d "$SRC" ]; then
    echo "✗ 找不到 $SRC" >&2
    read -r -p "按回车关闭… " _
    exit 1
fi
if [ -d "$DST" ]; then
    BACKUP="$HOME/.Trash/Vantage-$(date +%Y%m%d%H%M%S).app"
    echo "▸ 已有旧版本，移到废纸篓：$BACKUP"
    mv "$DST" "$BACKUP" 2>/dev/null || { echo "  无法移走，尝试直接替换"; rm -rf "$DST"; }
fi
echo "▸ 正在安装到 $DST …"
cp -R "$SRC" "$DST"
echo "✓ 完成。首次打开若被 Gatekeeper 拦截，请右键 App → 打开。"
open -R "$DST" >/dev/null 2>&1 || true
EOF
chmod 755 "$STAGE/Install.command"

# ---------------------------------------------------------------------
# 2. Finder 拖拽引导（两条路径共用；无 GUI 会话时降级而不算失败）
# ---------------------------------------------------------------------
cat > "$AS" <<'APPLESCRIPT'
-- 背景图必须用卷内文件的 POSIX 绝对路径 alias。写成 HFS 相对路径
-- (file ".background:dmg-background.png") 时，在 `tell disk` 上下文里经常
-- 解析不到真实文件，Finder 会静默忽略 —— 表现就是图标位置对了、背景仍是
-- 纯色。另外每个可选设置单独一个 try：以前三句挤在一个 try 里，只要
-- `arrangement` 或 `icon size` 抛错，背景图那句就被一起跳过。
on run argv
    set volName to item 1 of argv
    set mntPath to item 2 of argv
    set bgPath to mntPath & "/.background/dmg-background.png"
    set bgOK to false
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set bounds of container window to {100, 100, 760, 520}
            try
                set toolbar visible of container window to false
            end try
            try
                set statusbar visible of container window to false
            end try
            try
                set arrangement of icon view options of container window to not arranged
            end try
            try
                set icon size of icon view options of container window to 96
            end try
            try
                set bgAlias to (POSIX file bgPath) as alias
                set background picture of icon view options of container window to bgAlias
                set bgOK to true
            end try
            -- 少数系统版本只接受相对 disk 的 HFS file specifier，再试一次。
            if not bgOK then
                try
                    set background picture of icon view options of container window to file ".background:dmg-background.png"
                    set bgOK to true
                end try
            end if
            set position of item "Vantage.app" of container window to {160, 205}
            set position of item "Applications" of container window to {500, 205}
            try
                set position of item "README.txt" of container window to {160, 330}
                set position of item "Install.command" of container window to {500, 330}
            end try
            close
            open
            try
                update without registering applications
            end try
            delay 2
        end tell
    end tell
    -- 让 shell 端能区分「视图设置成功但背景图被拒」与「全都成功」
    if bgOK then
        return "BG_OK=1"
    else
        return "BG_OK=0"
    end if
end run
APPLESCRIPT

# 挂载卷上由系统/Finder 生成的辅助项：加 UF_HIDDEN，并抑制 fseventsd 记录。
# 必须在 eject / convert 之前做，这样 flags 会随块级复制进最终 UDZO。
hide_aux_files() {
    local mnt="$1"
    [ -d "$mnt" ] || return 0
    # .fseventsd 是可写卷挂载后由 fseventsd 自动建的；no_log 让它不再写日志，
    # 但目录本身仍在，所以还要 hidden（删了会被立刻重建，隐藏更稳）。
    if [ -d "$mnt/.fseventsd" ]; then
        : > "$mnt/.fseventsd/no_log" 2>/dev/null || true
    fi
    # 逐个调用：某一项不存在（例如降级时没有 .DS_Store）不该让整批失效。
    for aux in .background .fseventsd .DS_Store; do
        [ -e "$mnt/$aux" ] || continue
        chflags hidden "$mnt/$aux" 2>/dev/null || true
        # Xcode CLT 装了 SetFile 时再补一层 Finder invisible 位（可选，不依赖）。
        if command -v SetFile >/dev/null 2>&1; then
            SetFile -a V "$mnt/$aux" >/dev/null 2>&1 || true
        fi
    done
}

apply_finder_view() {
    local mnt="$1"
    VIEW="plain"
    BG_OK=0
    if ! command -v osascript >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    local res=""
    if res="$(python3 - "$AS" "$VOLNAME" "$mnt" <<'PY'
import subprocess, sys
script, vol, mnt = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    r = subprocess.run(["osascript", script, vol, mnt], timeout=30,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(r.returncode)
    print(r.stdout.strip())
except (subprocess.TimeoutExpired, OSError):
    sys.exit(124)
PY
)"; then
        VIEW="guided"
        if [[ "$res" == *"BG_OK=1"* ]]; then
            BG_OK=1
        fi
    fi
}

# ---------------------------------------------------------------------
# 3. 主路径：diskutil image（macOS 26+）
#
#    create from <folder> --format UDRW   → 可写镜像
#    attach                                → 挂载（无 -mountpoint 选项）
#    Finder AppleScript                    → 写 .DS_Store
#    eject                                 → 卸载
#    create from <rw.dmg> --format UDZO    → 只读压缩镜像
#    info                                  → 校验 Image Format
#
#    diskutil image 没有 verify 子命令，也不支持自定义挂载点；前者用
#    image info 校验格式 + shasum 兜底，后者在 /Volumes/Vantage 冲突时
#    直接让本路径失败并回退到 hdiutil 的 -mountpoint。
# ---------------------------------------------------------------------
has_diskutil_image() {
    command -v diskutil >/dev/null 2>&1 || return 1
    # 不用 `diskutil image | grep -q`：grep 命中即退出会让上游收到 SIGPIPE，
    # 在 `set -o pipefail` 下整个管道返回非 0，把可用系统误判成不可用。
    local usage
    usage="$(diskutil image 2>&1)" || true
    [[ "$usage" == *create* ]]
}

build_with_diskutil() {
    if [ -d "/Volumes/$VOLNAME" ]; then
        echo "  ⚠ /Volumes/$VOLNAME 已被占用，diskutil 无法指定挂载点" >&2
        return 1
    fi

    echo "▸ diskutil image create from (UDRW) …"
    if ! diskutil image create from "$STAGE" \
            --format UDRW --volumeName "$VOLNAME" "$RW" >/dev/null 2>&1; then
        # 某些版本不接受 --volumeName 与 from 组合，再试一次不带该选项
        diskutil image create from "$STAGE" \
            --format UDRW "$RW" >/dev/null 2>&1 || return 1
    fi
    [ -f "$RW" ] || return 1

    echo "▸ diskutil image attach …"
    local attach_out
    attach_out="$(diskutil image attach "$RW" 2>&1)" || return 1
    ACTIVE_DEV="$(printf '%s\n' "$attach_out" \
        | awk '/^\/dev\/disk[0-9]+([^0-9]|$)/{print $1; exit}')"
    ACTIVE_MNT="$(printf '%s\n' "$attach_out" \
        | awk '/^\/Volumes\//{print; exit}')"
    if [ -z "$ACTIVE_DEV" ]; then
        ACTIVE_DEV="$(printf '%s\n' "$attach_out" \
            | awk '/^\/dev\//{print $1; exit}')"
    fi
    # 部分版本只打印设备节点不打印挂载点；此时退回卷名对应的默认路径。
    # 前面已检测 /Volumes/Vantage 未被占用，所以不会误指向别人的卷。
    if [ -z "$ACTIVE_MNT" ]; then
        ACTIVE_MNT="/Volumes/$VOLNAME"
    fi
    [ -d "$ACTIVE_MNT" ] || return 1

    apply_finder_view "$ACTIVE_MNT"
    # 必须等 Finder 把 .DS_Store 写完，再隐藏辅助项并卸载；
    # 顺序反了会让背景图引用丢失、或让 .fseventsd 又冒出来。
    sleep 2
    hide_aux_files "$ACTIVE_MNT"

    echo "▸ diskutil eject …"
    if ! diskutil eject "$ACTIVE_DEV" >/dev/null 2>&1; then
        diskutil eject "$ACTIVE_MNT" >/dev/null 2>&1 || return 1
    fi
    ACTIVE_DEV=""; ACTIVE_MNT=""

    echo "▸ diskutil image create from (UDZO) …"
    # 从已有映像转换格式；部分版本不接受 --volumeName，去掉重试一次
    if ! diskutil image create from "$RW" \
            --format UDZO --volumeName "$VOLNAME" "$OUT" >/dev/null 2>&1; then
        diskutil image create from "$RW" \
            --format UDZO "$OUT" >/dev/null 2>&1 || return 1
    fi
    [ -f "$OUT" ] || return 1

    echo "▸ diskutil image info …"
    local info
    info="$(diskutil image info "$OUT" 2>&1)" || return 1
    printf '%s\n' "$info" | grep -q 'Image Format: UDZO' || return 1
    printf '%s\n' "$info" | grep -E 'Image Format|Format Description' || true
    return 0
}

# ---------------------------------------------------------------------
# 4. 兼容路径：hdiutil（旧系统 / diskutil 主路径失败时）
# ---------------------------------------------------------------------
build_with_hdiutil() {
    command -v hdiutil >/dev/null 2>&1 || return 1

    echo "▸ hdiutil create (UDRW) …"
    hdiutil create \
        -srcfolder "$STAGE" \
        -volname "$VOLNAME" \
        -fs HFS+ \
        -format UDRW \
        -ov \
        "$RW" >/dev/null || return 1

    # 自定义挂载点避免 /Volumes/Vantage 被占用时挂成 "Vantage 1"
    echo "▸ hdiutil attach …"
    hdiutil attach "$RW" \
        -readwrite -noverify -noautoopen \
        -mountpoint "$MNT_HDI" >/dev/null || return 1
    HDI_ATTACHED=1

    apply_finder_view "$MNT_HDI"
    sleep 2
    hide_aux_files "$MNT_HDI"
    hdiutil detach "$MNT_HDI" -force -quiet >/dev/null 2>&1 || return 1
    HDI_ATTACHED=0

    echo "▸ hdiutil convert (UDZO) …"
    hdiutil convert "$RW" \
        -format UDZO \
        -o "$OUT" \
        -ov >/dev/null || return 1
    echo "▸ hdiutil verify …"
    hdiutil verify "$OUT" >/dev/null || return 1
    return 0
}

# ---------------------------------------------------------------------
# 5. 执行：diskutil 优先，任何失败都清掉半成品后回退
# ---------------------------------------------------------------------
rm -f "$OUT" "$OUT.sha256"
if has_diskutil_image && build_with_diskutil; then
    TOOL="diskutil image"
else
    echo "  ⚠ diskutil image 不可用或该路径失败，回退 hdiutil" >&2
    rm -f "$RW" "$OUT"
    if ! build_with_hdiutil; then
        echo "✗ DMG 生成失败：diskutil image 与 hdiutil 两条路径均未成功" >&2
        exit 1
    fi
    TOOL="hdiutil (fallback)"
fi

if [ "$VIEW" = "guided" ]; then
    if [ "$BG_OK" -eq 1 ]; then
        echo "  ✓ Finder 拖拽引导已应用（背景图 + 图标定位）"
    else
        echo "  ⚠ 图标定位已写入，但 Finder 拒绝了背景图（BG_OK=0）：" >&2
        echo "    请确认 .background/dmg-background.png 存在于挂载卷，且系统允许 Finder" >&2
        echo "    自动化；DMG 仍可用（README.txt / Install.command 兜底）。" >&2
    fi
else
    echo "  ⚠ Finder 自动化不可用（无 GUI 会话 / 权限被拒），已降级："
    echo "    DMG 内保留 README.txt 与 Install.command，安装方式不受影响。"
fi

# 校验文件里用相对名，下载后 `shasum -a 256 -c *.sha256` 可直接跑。
(
    cd "$(dirname "$OUT")"
    shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)

echo ""
echo "✓ DMG:      $OUT"
echo "  工具:     $TOOL"
echo "  格式:     UDZO（只读压缩）"
echo "  视图:     $VIEW"
echo "  SHA-256:  $(cut -d' ' -f1 < "$OUT.sha256")"
echo "  校验文件: $OUT.sha256"
echo ""
echo "  未做 Apple 公证：首次打开若被 Gatekeeper 拦截，"
echo "  请右键 App → 打开，或在「系统设置 → 隐私与安全性」中允许。"
echo ""
