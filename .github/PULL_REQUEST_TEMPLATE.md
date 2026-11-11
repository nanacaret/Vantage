<!--
请按项填写。中文或英文均可。贡献规范见 CONTRIBUTING.md。
-->

## 改动内容

<!-- 一句话说明改了什么、为什么改 -->

## 关联 Issue

<!-- Closes #123 / 无 -->

## 验证方式

- [ ] `swift build -c release` 零 error、零 warning
- [ ] `./Scripts/build_app.sh` 能生成 `build/Vantage.app` 并成功启动
- [ ] 若改了文案：`python3 Tools/build_l10n.py` 后 `git diff --exit-code` 为空
- [ ] 若新增 C 接口：声明在 `include/` 下，实现一致，Swift 侧有 `import CProc`
- [ ] 实机验证过相关界面（macOS 版本 / 芯片：`________`）

## 检查清单

- [ ] 新文件带 `SPDX-License-Identifier: MIT`
- [ ] 没有手工编辑生成文件（`L10n*.swift` / `.lproj` / `cproc_l10n_data.*` / `.iconset`）
- [ ] 没有提交 `build/`、`.build/`、`*.app`、私钥、`.DS_Store`
- [ ] 没有字典字面量重复 key、重复 switch case、`Selector("…")` 字面量构造
- [ ] 读不到的数据显示 `—`，没有用 0 冒充「不可用」
- [ ] 如引入新的私有 API：运行时 `dlsym` 解析、可降级、已更新免责说明
- [ ] 如新增界面文案：使用语义 key，中英双语齐备

## 备注 / 截图

<!-- 可选 -->
