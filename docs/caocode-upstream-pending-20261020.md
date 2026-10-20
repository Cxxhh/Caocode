# BaoCode 1.5.0 合并记录（2026-10-20）

本次从原固定基线 `7e830e23d12d8f0273cf4a341b11dee1d1058711` 合入至
`9b2d51ac428c00121b458cc65b6fb84c1edf8ee2`，共 13 个上游提交（包括合并、发布和文档提交）。
上游版本为 `1.5.0+15`。首次评估时最新为 `66028bdd`，执行合并时新增了输入框焦点循环修复及其合并提交，也一并采用。
Caocode 从 `1.4.5+19` 更新为 `1.5.6+20`，公开显示 `1.5.6c`：主次版本跟随上游，修订号与 build 在本地各递增一次。
`tool/caocode/toolchain.json` 和 `reference/baocode` 均固定到本次合入提交。

## 已合入的桌面更新

| 更新 | 用户可见效果与本地状态 | 上游提交 |
| --- | --- | --- |
| 远程定义跳转修复 | F12 按远程主机自己的路径规则打开目标，LSP 适配器使用工作区的路径规则。 | [b1d95696](https://github.com/baocode-dev/baocode/commit/b1d95696) |
| 最近聊天标签保活 | IDE 保留最近 5 个聊天页面，切回时减少重建并保留滚动位置；隐藏页不接收键盘焦点。 | [9a0b015f](https://github.com/baocode-dev/baocode/commit/9a0b015f) |
| 长文件宽度测量缓存 | 侧面板按内容、字体和缩放缓存测量结果，减少反复构建时扫描长文件。 | [659954d3](https://github.com/baocode-dev/baocode/commit/659954d3) |
| 侧面板复用 IDE 差异编辑器 | 窄面板内联显示删除内容，宽面板左右对照，并有改动总览。 | [b30c12b5](https://github.com/baocode-dev/baocode/commit/b30c12b5) |
| 图片放大裁切修复 | 图片预览缩放可使用整个窗口，不再被最初的图片尺寸裁切。 | [4ab798de](https://github.com/baocode-dev/baocode/commit/4ab798de) |
| 消息中途唤起斜杠命令 | 在任意单词开头输入 `/` 可唤起菜单；普通路径无匹配命令时仍当作文本。 | [f4348ae7](https://github.com/baocode-dev/baocode/commit/f4348ae7) |
| 输入框焦点循环修复 | 多个已编辑的聊天／Stash 输入框切换时让出焦点，避免互相抢焦点造成界面卡死。 | [8684040c](https://github.com/baocode-dev/baocode/commit/8684040c) |

合并保留 Caocode 的 WSL 原生文件服务、Codex 子代理、模型选择和外层推理强度入口。

## 网站与协作文件

- [635ca0a6](https://github.com/baocode-dev/baocode/commit/635ca0a6)：网站嵌入第三方 iframe 时，下载渠道归因可经 `/dl` 传到激活流程。
- [9bb51a15](https://github.com/baocode-dev/baocode/commit/9bb51a15)：iframe 内的站外链接打开独立标签页。
- [098c5955](https://github.com/baocode-dev/baocode/commit/098c5955)：贡献指南、PR 模板及 README 链接。
- `1.5.0` 发布说明、网站更新日志及版本文案。

网站改动已合入源码：保留 Caocode 存储标识，iframe 下载使用当前站点域名，贡献指南与网站链接指向 Caocode 仓库。
应用继续使用自己的 GitHub Releases 更新渠道。网站与远端发布属于独立部署流程。

## 已经具备的能力

上游 `1.5.0` 发布说明覆盖了多个早先提交，不能整份当作缺失清单。
SSH 服务器表单、密码／私钥／跳板机、SSH 设置、首次连接指纹处理、Windows 新版 OpenSSH、
Linux 浏览器扩展、IDE 输入性能优化、运行统计等代码，已在此前的上游合并范围内。
详见[此前合并记录](caocode-upstream-20261020.md)。Codex 的远程执行能力仍取决于本地适配器，不能从 Claude 的上游能力直接推断。

## 保留此前的模型选择优化

- 移除模型列表中的“CLI 默认”，读取当前 CLI 的配置并显示实际模型；配置未指定时采用 CLI 模型列表的默认标记。
- Windows／WSL 新对话各自跟随所在环境的 CLI 配置，历史对话保留自己的明确选择。旧的 `default` 记录自动解析为实际模型。
- 自定义供应商的模型即使没有出现在 CLI 返回的列表中，仍可按配置选中和显示。
- Codex 模型菜单只选择模型，推理强度保留在外层工具栏；继续读取 CLI 的默认推理强度并保留各模型的手动选择。

## 验证

- 修改模块的严格静态检查通过。
- 相关用例覆盖斜杠菜单、侧面板差异与复制、长文件横向滚动、远程路径跳转、聊天标签复用、输入框焦点及关闭快捷键。
- 回归检查覆盖 Codex 模型选择、子代理导航和事件、WSL 文件服务及环境切换。
- 网站下载 Worker 的标准下载、渠道 Cookie、未知渠道、失效清单和静态资源路由通过 Node 测试；更新日志由源文件重新生成并通过一致性检查。
- 实际渲染检查了窄面板内联差异、宽面板左右对照及图片放大。
- Windows Release 编译通过；全工程静态检查保留原有 2 条警告和 8 条提示，修改模块的严格检查无问题。
- 文件树加载提示依赖原生目录读取，相关 widget 用例先让真实 I/O 完成再检查动画收敛；保留原有焦点、标签和快捷键断言。
