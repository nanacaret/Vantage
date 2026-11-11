# App Icon

| 文件 | 用途 |
|---|---|
| `Vantage.png` | 1024×1024 RGBA 主图，macOS 标准圆角（半径 22.37%）+ 透明 alpha |
| `Vantage.icns` | PNG 内嵌的 ICNS，含 `icp4` / `icp5` / `icp6` / `ic07`–`ic14` 共 11 项 |
| `Vantage.iconset/` | `iconutil` 用的 10 个尺寸（16…1024，含 `@2x`） |

设计：深蓝 `#0B1B33` → 青绿 `#0E6E7A` 对角渐变，细网格上一条居中的青白发光脉冲波形，
呼应「进程 / 性能遥测」。四角透明、16px 小尺寸仍可辨认。

`Packaging/Info.plist` 通过 `CFBundleIconFile = Vantage` 引用；`Scripts/build_app.sh` 优先用系统
`iconutil` 从 iconset 现生成 `.icns`，不可用时直接拷贝预置的 `Vantage.icns`，
因此在非 macOS 环境构造的 bundle 也能带上图标。

## 替换图标

把新的 1024×1024 PNG 覆盖 `Vantage.png` 后运行（仅依赖 Pillow）：

```bash
python3 Tools/make_icon.py
```

脚本会重建 `.iconset/` 与 `.icns`。也可以直接替换整个 `.iconset/` 目录。

## 许可

这些图形是本项目的原创素材，随 [MIT](../LICENSE) 许可一同发布。
仓库内不包含第三方图标、字体或品牌标识；详见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
