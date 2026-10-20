# Codex 迁移范围

Caocode 的默认代理内核现为 `Codex CLI`。应用通过 `codex app-server` 的 stdio
协议控制代理执行，不需要安装 Claude Code。

## 已接入

- 正确的 RPC 初始化、通知、响应和错误处理，以及请求超时。
- 从 CLI 发现模型及支持的推理强度，按模型保存强度选择；默认模型与强度来自 CLI 配置。
- 请求批准、帮我批准、完全访问权限、自定义四种权限预设；自定义在发送前重新读取配置。
- 流式文本、思考摘要、命令输出、文件改动、图片输入和回合完成状态。
- 命令、文件、额外权限审批及结构化问题；不支持的交互请求会立即返回错误。
- 会话编号、按工程列出会话、恢复历史、重命名、回退和归档。
- 消息排队、撤回和优先发送；停止、进程退出、空闲释放及重新连接。
- 会话标题和 Git 提交信息使用 Codex 的临时只读会话生成。
- 模型设置页提供 Codex 可执行路径、登录和配置说明；历史搜索读取 Codex。
- Windows 中打开 `\\wsl.localhost\<发行版>\<Linux 路径>` 时，在该 WSL
  发行版内执行 Codex，并将 Linux 文件路径转换给桌面界面。
- Windows 可执行文件为 `caocode.exe`，应用数据和进程实例与 Caocode 分开。
- 历史事件批量恢复、Markdown 解析缓存、会话列表构建复用和鼠标滚轮平滑滚动。
- 思考项使用服务端完成摘要；历史没有真实耗时时不显示虚构时长，空摘要不占行。
- 合入 Caocode 1.1.0 的聊天小地图、回复复制、回合页脚和桌面手机配对服务；
  保留原有会话缓存和平滑滚动，小地图只在内容或折叠状态变化时重新读取历史。
- 历史回复即使没有耗时也可以复制；手机同步保留思考摘要的完成状态和已知用量。

## 使用

在工程所在系统的终端运行 `codex --version`，必要时运行 `codex login`。
已有的自定义服务商配置会由 Codex 沿用。设置 → 模型 中留空可执行路径，
表示在该系统的 PATH 中查找；也可填入完整路径（设置项 `codexCli.path`）。
环境变量 `CAOCODE_CODEX_PATH` 也可指定路径。新会话读取所在环境的 CLI 配置，
直接选中并显示实际默认模型；配置未指定模型时，采用 CLI 模型列表的默认标记。
已有会话保留自己的明确模型选择。

Windows 构建可以直接打开 WSL 源码目录，编译副本只用于编译。
两端使用各自的 Codex 安装及 `~/.codex` 配置；代码同步不复制 CLI 凭据。

应用自身数据目录为 Windows 的 `%APPDATA%\caocode`，Linux 的
`~/.config/caocode`。可使用 `CAOCODE_DATA_DIR` 指定其他目录；迁移指针为
`~/.caocode/config-dir.json`。

## 权限与推理强度

| 权限 | 工程权限 | 工具与审批 |
| --- | --- | --- |
| 请求批准 | `workspaceWrite`，沙箱网络默认关闭 | `on-request`，由用户审批扩大权限的请求 |
| 帮我批准 | 工作区沙箱；兼容配置中的只读限制和工作区沙箱参数 | `on-request`，由 CLI 的 `auto_review` 评估请求 |
| 完全访问权限 | `dangerFullAccess` | `never`，不申请权限审批 |
| 自定义 (config.toml) | 使用 CLI 解析的配置或命名权限配置 | 恢复配置中的审批策略、审批评估者和沙箱参数 |

输入框底部可直接选择推理强度，模型菜单只选择模型；档位来自
`model/list`，默认强度读取 CLI 配置，切换模型会恢复该模型的选择。权限、模型和强度在下一次发送消息
时应用，正在执行的回合沿用开始时的设置。`/review`、`/diff` 使用只读策略。

## 当前边界

SSH 远程代理传输、目标与子代理面板仍需继续
迁移；当前 Codex 内核只启用已支持的界面能力。Skills、MCP 等由 CLI 自身配置
生效。Caocode 已启用自己的 GitHub Releases 更新渠道，遥测默认关闭。
应用日志记录、日志开关与诊断上传功能已移除。
上游 Claude 代码保留作为迁移参考和回归测试，不注册为当前应用内核。
上游手机 App 是独立工程，当前只合入桌面端连接服务。Claude 专有的自定义配置
读取被屏蔽；模型、权限、推理强度按当前内核提供的选项同步。后台任务控制和
撤销操作按会话能力禁用，不支持的远程调用返回 `unsupported`，原有实现保留。
界面、关于页面、安装包和原生通信标识已统一为 Caocode；当前发布验证覆盖 Windows。

会话列表的删除使用 Codex 的 `thread/archive`：从活动列表移除，原记录由
Codex 保留。`./build.sh --installer` 可生成 Windows 安装包；Fast、Codex 供应商管理
及 CCS 数据库导入/只读连接见 [codex-providers.md](codex-providers.md)。

## 验证命令

```bash
./flutterw analyze --no-pub lib/kernel/codex lib/kernel/kernel_registry.dart
./flutterw test --no-pub test/kernel/codex_test.dart --reporter expanded
./flutterw test --no-pub test/kernel/codex_test.dart \
  --dart-define=CAOCODE_REAL_CLI=true
./flutterw test --no-pub test/kernel/codex_live_test.dart \
  --dart-define=CAOCODE_LIVE_KERNEL=true --reporter expanded
./build.sh
```

真实模型测试会发送简短的连接验证请求；默认单元测试跳过这类测试。
协议来自 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)，
并已用本机 CLI 生成的 JSON schema 校验字段。

1.1.0 迁移阶段已完成验证：

| 检查 | 结果 |
| --- | --- |
| WSL / Windows Flutter、Dart | 3.47.5 / 3.13.4，与上游一致 |
| Codex CLI | WSL 0.162.1，Windows 0.156.1 |
| 修改模块严格静态检查 | 通过 |
| 相关回归测试 | 155 个通过；新增历史搜索测试另有 1 个通过 |
| Windows Codex 模块测试及真实协议请求 | 9 个通过，模型请求测试默认跳过 |
| WSL 真实模型与完整会话 | 回复、保存、读取和恢复通过 |
| Windows → WSL 真实模型与完整会话 | 回复、保存、读取和恢复通过 |
| 会话恢复和滚动相关回归测试 | 58 项通过 |
| 思考摘要相关回归测试 | 72 项通过 |
| 推理强度和权限选择相关回归测试 | 40 项通过，包含真实 CLI 接口兼容性检查；未发送新的模型请求 |
| Caocode 1.1.0 合并回归 | 85 项通过，包含聊天小地图、历史复制、折叠页脚、思考同步、Codex 和加密连接；3 项真实 CLI 测试默认跳过 |
| 保留的 Claude 用量回归 | 2 项通过，覆盖回合耗时、用量、生成速度和费用 |
| 消息编辑滚动回归 | 1 项通过，覆盖编辑框独立滚动和历史滚动条 |
| Windows Release 编译 | 通过，产物为 caocode.exe |
| 桌面程序启动 | 成功创建 IDE 窗口 |
| 增量同步 | 新增、无变化、同大小/时间戳内容修改、删除、中文路径、缓存保留均通过 |

上述阶段上游有 6 条已有静态检查提示；修改模块的严格检查没有问题。
2026-10-20 先合入上游 1.4.0 及后续修复，适配边界见
[此前合并评估](caocode-upstream-20261020.md)；随后合入至 1.5.0 及输入框焦点修复，
当前基线与功能见 [1.5.0 合并记录](caocode-upstream-pending-20261020.md)。
参考仓库随固定基线更新，主工程在 `caocode/main` 开发。
查询上游更新时在主仓库获取 `upstream`，对比固定基线与远端分支；合入更新时
另行评估与 Codex 迁移、会话渲染和诊断清理的重叠改动。
