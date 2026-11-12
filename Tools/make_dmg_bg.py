#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# -*- coding: utf-8 -*-
"""生成 DMG 的「拖到 Applications 安装」背景图。

仅用 Pillow，产出 Packaging/dmg-background.png（660×420，与 make_dmg.sh 里
Finder 窗口的 bounds 一致）。构建时直接拷贝这张图，不要求 CI 装 Pillow；
想改文案/配色改这里重跑一次即可。

位置约定（与 make_dmg.sh 的 osascript 一致）：
    Vantage.app    (160, 205)      Applications  (500, 205)
    README.txt     (160, 330)      Install.command (500, 330)
图标会盖住背景图对应位置，所以那里只画一个淡色定位环。
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packaging" / "dmg-background.png"
W, H = 660, 420

TOP = (11, 27, 51)      # #0B1B33
BOT = (14, 110, 122)    # #0E6E7A
ACCENT = (126, 231, 232)
TEXT = (238, 247, 250)
DIM = (168, 196, 204)


def font(size, bold=False):
    candidates = [
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold
        else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ]
    for p in candidates:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    # 对角渐变
    base = Image.new("RGB", (W, H))
    px = base.load()
    for y in range(H):
        for x in range(W):
            t = min(1.0, max(0.0, (x / W * 0.55 + y / H * 0.45)))
            px[x, y] = lerp(TOP, BOT, t)

    # 细网格，呼应 App Icon
    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    for x in range(0, W, 30):
        gd.line([(x, 0), (x, H)], fill=(255, 255, 255, 9), width=1)
    for y in range(0, H, 30):
        gd.line([(0, y), (W, y)], fill=(255, 255, 255, 9), width=1)
    base = Image.alpha_composite(base.convert("RGBA"), grid)

    d = ImageDraw.Draw(base)

    # 顶部标题
    f_title = font(27, bold=True)
    f_sub = font(14)
    f_small = font(12)
    f_tag = font(13, bold=True)

    def center(text, y, fnt, fill):
        b = d.textbbox((0, 0), text, font=fnt)
        d.text(((W - (b[2] - b[0])) / 2 - b[0], y), text, font=fnt, fill=fill)

    center("Vantage", 26, f_title, TEXT)
    center("Drag to install · 拖到右侧即可安装", 66, f_sub, DIM)

    # 两个图标位置的定位环（图标本身会盖住中间）
    for cx, cy in ((160, 205), (500, 205)):
        d.ellipse([cx - 62, cy - 62, cx + 62, cy + 62],
                  outline=(255, 255, 255, 46), width=2)
        d.ellipse([cx - 68, cy - 68, cx - 68 + 4, cy - 68 + 4],
                  fill=ACCENT + (170,))

    # 发光箭头：左图标 → 右图标
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    x0, x1, ay = 238, 418, 205
    g.line([(x0, ay), (x1 - 16, ay)], fill=ACCENT + (235,), width=9)
    g.polygon([(x1 - 18, ay - 13), (x1, ay), (x1 - 18, ay + 13)],
              fill=ACCENT + (235,))
    glow = glow.filter(ImageFilter.GaussianBlur(7))
    base = Image.alpha_composite(base, glow)
    d = ImageDraw.Draw(base)
    d.line([(x0, ay), (x1 - 16, ay)], fill=ACCENT + (255,), width=6)
    d.polygon([(x1 - 18, ay - 13), (x1, ay), (x1 - 18, ay + 13)],
              fill=ACCENT + (255,))

    center("DROP HERE", 148, f_tag, TEXT)
    center("Applications", 262, f_tag, TEXT)

    # 底部两个辅助文件的定位框
    for cx, cy, label in ((160, 330, "README"), (500, 330, "Install.command")):
        b = d.textbbox((0, 0), label, font=f_small)
        tw = b[2] - b[0]
        d.rounded_rectangle([cx - tw / 2 - 12, cy - 13, cx + tw / 2 + 12, cy + 13],
                            radius=8, outline=(255, 255, 255, 40), width=1)
        d.text((cx - tw / 2 - b[0], cy - 7), label, font=f_small, fill=DIM)

    center("Or double-click Install.command · 或双击 Install.command 一键安装",
           374, f_small, DIM)
    center("Unsigned build — right-click → Open if Gatekeeper blocks it · 未公证，被拦截时右键→打开",
           394, f_small, (140, 170, 180))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    base.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"✓ {OUT.relative_to(ROOT)}  {base.size[0]}×{base.size[1]}")


if __name__ == "__main__":
    main()
