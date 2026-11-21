#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""把同一个版本号写进两处需要它的地方 —— 由 Scripts/build_app.sh 调用。

    Scripts/inject_version.py 1.2.5 --swift Sources/VantageCLI/BuildVersion.swift
    Scripts/inject_version.py 1.2.5 --plist  build/Vantage.app/Contents/Info.plist

为什么要独立成文件而不是在构建脚本里 heredoc：
  * 版本号要同时改 Swift 源码和 plist，正则 / 校验 / 回读验证放在一起才看得懂；
  * `sed -i` 的语法在 BSD / GNU / toybox 三套实现里都不一样（macOS 上装过
    coreutils 或跑在被裁剪的 PATH 里就会翻车），python 没有这个问题；
  * 可以单独跑、单独测：`Scripts/inject_version.py 1.2.5 --plist /tmp/x.plist`。

两处都是幂等的：值相同就不写文件（不碰 mtime、不产生 git diff），只有真的变了
才打印 `旧 → 新`，CI 日志里一眼能看出这次注入了什么。
plist 用系统的 PlistBuddy 按语义改值，代价是产物那份 plist 里的 XML 注释会丢
（源文件 `Packaging/Info.plist` 不受影响，注释还在）。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# 版本号会进 Info.plist 和 DMG 文件名，只允许安全字符（与 CI 里 tag 的清洗规则一致）。
VERSION_RE = re.compile(r"^[A-Za-z0-9._-]+$")

# Sources/VantageCLI/BuildVersion.swift 里唯一一行带引号的常量。
SWIFT_RE = re.compile(r'^(    static let marketing = ")([^"]*)(")$', re.M)

PLIST_KEYS = ("CFBundleShortVersionString", "CFBundleVersion")
PLIST_BUDDY = "/usr/libexec/PlistBuddy"


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    sys.exit(f"inject_version: {message}")


def plist_get(path: Path, key: str) -> str:
    out = subprocess.run(
        [PLIST_BUDDY, "-c", f"Print :{key}", str(path)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        fail(f"读不到 {path}:{key}（{out.stderr.strip() or out.stdout.strip()}）")
    return out.stdout.strip()


def plist_set(path: Path, key: str, version: str) -> None:
    out = subprocess.run(
        [PLIST_BUDDY, "-c", f"Set :{key} {version}", str(path)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        fail(f"写不进 {path}:{key}（{out.stderr.strip() or out.stdout.strip()}）")


def stamp_swift(path: Path, version: str) -> str | None:
    """改 Swift 里的常量，返回旧值；值没变时返回 None。"""
    src = path.read_text(encoding="utf-8")
    match = SWIFT_RE.search(src)
    if not match:
        fail(f"找不到 `static let marketing` 常量：{path}")
    old = match.group(2)
    if old == version:
        return None
    path.write_text(
        SWIFT_RE.sub(lambda m: m.group(1) + version + m.group(3), src, count=1),
        encoding="utf-8",
    )
    # 回读确认，别让一次失败的正则悄悄留下旧值
    if SWIFT_RE.search(path.read_text(encoding="utf-8")).group(2) != version:
        fail(f"写入后回读不一致：{path}")
    return old


def stamp_plist(path: Path, version: str) -> str | None:
    if not path.is_file():
        fail(f"没有这个 plist：{path}")
    old = plist_get(path, "CFBundleShortVersionString")
    if old == version and plist_get(path, "CFBundleVersion") == version:
        return None
    for key in PLIST_KEYS:
        plist_set(path, key, version)
    for key in PLIST_KEYS:
        if plist_get(path, key) != version:
            fail(f"写入后回读不一致：{path}:{key}")
    return old


def main() -> int:
    parser = argparse.ArgumentParser(
        description="把版本号注入 Swift 常量与 Info.plist（幂等）",
    )
    parser.add_argument("version", help="要注入的版本号，例如 1.2.5 或 nightly")
    parser.add_argument("--swift", metavar="PATH", action="append", default=[],
                        help="改这里的 static let marketing（可重复）")
    parser.add_argument("--plist", metavar="PATH", action="append", default=[],
                        help="改这里的 CFBundleShortVersionString / CFBundleVersion（可重复）")
    args = parser.parse_args()

    if not args.swift and not args.plist:
        parser.error("至少要给一个 --swift 或 --plist")
    if not VERSION_RE.match(args.version):
        parser.error(
            f"版本号只能包含 A-Z a-z 0-9 . _ -（会进 plist 与文件名）：{args.version!r}"
        )

    # 只在真的改动时打一行：例行构建（nightly → nightly）不该刷日志，
    # 要确认版本看 build_app.sh 结尾那行「版本: …」。
    for raw in args.swift:
        old = stamp_swift(Path(raw), args.version)
        if old is not None:
            print(f"▸ swift  {raw}: {old} → {args.version}")
    for raw in args.plist:
        old = stamp_plist(Path(raw), args.version)
        if old is not None:
            print(f"▸ plist  {raw}: {old} → {args.version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
