# BaoCode 上游待合入功能（2026-10-20）

已刷新上游远端并逐项核对代码。本地实际合入基线为
`7e830e23d12d8f0273cf4a341b11dee1d1058711`，最新上游为
`66028bdd`，版本 `1.5.0+15`；其间有 11 个提交（包括合并、发布和文档提交）。
本轮只评估这些上游差异，完成本地模型选择优化后版本为 `1.4.5+19`，公开显示 `1.4.5c`。

## 尚未合入的桌面更新

| 更新 | 用户可见效果与本地状态 | 上游提交 |
| --- | --- | --- |
| 远程定义跳转修复 | F12 按远程主机自己的路径规则打开目标。本地 LSP 适配器尚未传入工作区的路径规则，与 SSH／WSL 的远程编辑有关。 | [b1d95696](https://github.com/baocode-dev/baocode/commit/b1d95696) |
| 最近聊天标签保活 | IDE 保留最近 5 个聊天页面，切回时减少重建并保留滚动位置。本地尚无这组保活逻辑。 | [9a0b015f](https://github.com/baocode-dev/baocode/commit/9a0b015f) |
| 长文件宽度测量缓存 | 侧面板按内容、字体和缩放缓存测量结果，减少反复构建时扫描长文件。本地仍使用旧测量实现。 | [659954d3](https://github.com/baocode-dev/baocode/commit/659954d3) |
| 侧面板复用 IDE 差异编辑器 | 窄面板内联显示删除内容，宽面板左右对照，并有改动总览。本地仍使用旧差异视图，缺少新增的 `ide_code_diff.dart`。 | [b30c12b5](https://github.com/baocode-dev/baocode/commit/b30c12b5) |
| 图片放大裁切修复 | 图片预览缩放可使用整个窗口，不再被最初的图片尺寸裁切。本地仍是旧的 `InteractiveViewer` 层级。 | [4ab798de](https://github.com/baocode-dev/baocode/commit/4ab798de) |
| 消息中途唤起斜杠命令 | 在任意单词开头输入 `/` 可唤起菜单；普通路径无匹配命令时仍当作文本。本地只识别整条消息开头的 `/`。 | [f4348ae7](https://github.com/baocode-dev/baocode/commit/f4348ae7) |

建议先合入远程跳转、聊天标签保活和长文件测量缓存：前者直接关联远程文件路径正确性，后两项改善日常切换和浏览性能。随后合入差异编辑器、图片缩放和斜杠菜单。合入时需保留 Caocode 的 WSL 文件服务、Codex 子代理和输入工具栏适配。

## 网站与协作文件

- [635ca0a6](https://github.com/baocode-dev/baocode/commit/635ca0a6)：网站嵌入第三方 iframe 时，下载渠道归因可经 `/dl` 传到激活流程。
- [9bb51a15](https://github.com/baocode-dev/baocode/commit/9bb51a15)：iframe 内的站外链接打开独立标签页。
- [098c5955](https://github.com/baocode-dev/baocode/commit/098c5955)：贡献指南、PR 模板及 README 链接。
- `1.5.0` 发布说明、网站更新日志及版本文案。

网站改动需要按 Caocode 的域名、GitHub Releases 下载和发布渠道适配。实际合入上游 `1.5.0` 后，再按工程规则调整主次版本及固定基线。

## 已经具备的能力

上游 `1.5.0` 发布说明覆盖了多个早先提交，不能整份当作缺失清单。
SSH 服务器表单、密码／私钥／跳板机、SSH 设置、首次连接指纹处理、Windows 新版 OpenSSH、
Linux 浏览器扩展、IDE 输入性能优化、运行统计等代码，已在此前的上游合并范围内。
详见[此前合并记录](caocode-upstream-20261020.md)。Codex 的远程执行能力仍取决于本地适配器，不能从 Claude 的上游能力直接推断。

## 本轮模型选择优化

- 移除模型列表中的“CLI 默认”，读取当前 CLI 的配置并显示实际模型；配置未指定时采用 CLI 模型列表的默认标记。
- Windows／WSL 新对话各自跟随所在环境的 CLI 配置，历史对话保留自己的明确选择。旧的 `default` 记录自动解析为实际模型。
- 自定义供应商的模型即使没有出现在 CLI 返回的列表中，仍可按配置选中和显示。
- Codex 模型菜单只选择模型，推理强度保留在外层工具栏；继续读取 CLI 的默认推理强度并保留各模型的手动选择。
