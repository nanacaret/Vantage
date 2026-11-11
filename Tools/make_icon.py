#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""从 Assets/Vantage.png 重新生成 Vantage.iconset/ 与 Vantage.icns。

用途：换了 1024×1024 主图后，用它一键重建 macOS 图标资源。
依赖：Pillow（pip3 install pillow）；只用标准库 + Pillow，不需要 macOS。

    python3 Tools/make_icon.py
"""
from pathlib import Path
from PIL import Image, ImageFilter
import io
import struct

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Assets"
SRC = ASSETS / "Vantage.png"
ICONSET = ASSETS / "Vantage.iconset"

icon = Image.open(SRC).convert("RGBA")
if icon.size != (1024, 1024):
    raise SystemExit(f"主图必须是 1024×1024，当前 {icon.size}")
ICONSET.mkdir(exist_ok=True)

SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}

def resized(px):
    r = icon.resize((px, px), Image.LANCZOS)
    if px <= 64:
        r = r.filter(ImageFilter.UnsharpMask(radius=0.8, percent=90, threshold=2))
    return r

for name, px in SIZES.items():
    resized(px).save(ICONSET / name)

# ICNS = 'icns' + 总长 + 若干 (4 字符 type, 长度, 数据)
# PNG 内嵌类型，macOS 10.7+ 全支持，不依赖 iconutil。
ENTRIES = [
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
    (b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]
chunks = []
for typ, px in ENTRIES:
    buf = io.BytesIO()
    resized(px).save(buf, format="PNG", optimize=True)
    data = buf.getvalue()
    chunks.append(typ + struct.pack(">I", 8 + len(data)) + data)
body = b"".join(chunks)
(ASSETS / "Vantage.icns").write_bytes(
    b"icns" + struct.pack(">I", 8 + len(body)) + body)

print(f"✓ {ICONSET}  ({len(SIZES)} 个 PNG)")
print(f"✓ {ASSETS / 'Vantage.icns'}  ({len(ENTRIES)} 个 ICNS 条目)")
