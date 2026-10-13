# Codex 配置与供应商

入口：设置 → 模型。

- 自定义 `config.toml`：填写绝对路径或 `~/` 路径，文件名必须为 `config.toml`；留空时使用会话所在系统的 `CODEX_HOME/config.toml`，未设置 `CODEX_HOME` 则使用 `~/.codex/config.toml`。
- “打开 config.toml”：关闭设置并在 Fast IDE 中打开该文件。文件不存在时创建一个空配置，不覆盖已有内容。编辑保存后，重启现有会话或新建会话读取更新。
- Windows 打开的 WSL 工程：配置路径从对应发行版的登录环境解析；显示和打开使用 UNC 路径，`codex app-server` 使用 Linux 路径。配置与 Windows 本地 Codex 相互独立。
- 自定义配置目录通过 `CODEX_HOME` 传给 CLI。因此同一目录也是 Codex 的登录、skills 和会话存储位置。

供应商支持新增、编辑、复制、删除、导入当前配置、启用、切回 OpenAI 官方，以及手动编辑供应商 TOML 片段。提供 OpenAI / ChatGPT、OpenAI API、Kimi、Kimi For Coding、DeepSeek、智谱 GLM、MiniMax、xAI、OpenRouter 和自定义 Responses 预设。端点预设来自下述 cc-switch 源码快照；模型 ID 由用户填写，运行时模型列表继续由 CLI 的 `model/list` 提供。

供应商名称和配置片段保存在 `settings.json` 的 `codexCli.providers`，API Key 使用应用已有的系统密钥存储。启用第三方供应商时，密钥写入 `[model_providers.custom].experimental_bearer_token`；`requires_openai_auth = false`，避免第三方地址回退使用官方登录。环境变量 `env_key` 和命令认证 `auth` 可通过 TOML 片段设置；填写 API Key 时改用该密钥。官方登录的 `auth.json` 保留。

切换只修改供应商连接、模型、推理和该供应商带入的兼容选项。MCP、项目、插件、审批、注释及其他全局设置保留；当前 profile 的模型覆盖也会移除，使新的顶层供应商配置生效。切换前生成同目录的 `config.toml.caocode.bak`，配置无法解析时拒绝写入。写入使用临时文件及替换，并检测期间发生的其他程序修改。Linux / WSL 下含密钥的配置、临时文件与备份限制为 `0600`。

本次适配 cc-switch 的 **Codex 直连供应商配置管理**。上游单独的本地代理、Chat / Anthropic 协议转换、聚合路由和多账号 OAuth 托管需要独立运行服务，本次未引入。仅支持 Codex 原生的 Responses 接口。

## 连接或导入 CC Switch（CCS）

设置 → 模型 → 第三方供应商 · CC Switch (CCS)。数据库路径留空时，“连接 CCS”读取应用所在系统的 `~/.cc-switch/cc-switch.db`；Windows 应用默认读取 Windows 用户目录，即使当前工程位于 WSL。也可填写其他数据库的绝对路径（包括 WSL UNC 路径）。

- 连接模式：只保存数据库路径，供应商与密钥从 CCS 只读加载到内存。在 CCS 新增、修改、删除后，点击“刷新 CCS”或“刷新配置”更新列表；重新打开设置也会读取最新数据。SQLite 原生读取会包含已经提交但尚未合并到主文件的 WAL 数据。
- “启用”：将选中的最新配置和密钥写入当前工程所在系统的 Codex `config.toml`，沿用现有备份与全局设置保留规则。CCS 修改已启用供应商的连接或密钥后，刷新列表并重新启用；现有 Codex 会话需要重启。
- “导入为本地副本”：打开预填好的供应商编辑器，保存后才将副本与密钥写入本地设置和系统密钥存储。此副本之后独立维护。
- “断开连接”：移除数据库路径与内存列表，保留已经启用的 Codex 配置。
- 只读取 `providers.app_type = 'codex'` 的直连配置，不改写 CCS 数据库或其当前供应商。无效条目、需要协议转换或托管账号的条目会显示提示，不影响其他供应商。读取失败时清除旧列表，避免继续使用过期数据。

## Fast 命令

聊天输入框底部功能栏的“推理强度”右侧提供闪电开关：灰色空心表示关闭，蓝色实心表示开启，点击直接切换。交互参考 Codex VS Code 扩展，图形沿用工程已有的 Lucide 图标及其填充变体。它与下述命令共享状态，不会发送聊天消息或改动输入草稿；切换期间暂时禁用。Codex 会话始终保留闪电，关闭 Fast 后仍可再次点击开启；明确不可用时显示灰色禁用状态及原因。模型等选择项在空间不足时横向滚动，闪电独立于滚动区，保持可见、可点击，避免较长模型名称将其挤出可见区域。

Fast 是 Codex 的服务速度档位，不是独立模型，也不是终端渲染特性。可用性判断：`features.fast_mode = false` 时禁止开启；优先读取 `model/list` 中当前模型的 `serviceTiers`，识别 `fast` / `priority` ID 或相应名称；兼容旧字段 `additionalSpeedTiers`。两个字段均缺失的旧 CLI 允许尝试 `fast`；两个列表均为空、且恢复线程的 `modelProvider` 或当前配置的 `model_provider` 表明使用第三方供应商时，也允许尝试，由服务端校验。官方供应商返回空列表或列表明确提供其他档位但不含 Fast 时禁止开启。服务端返回的错误不会被静默忽略。修改模型时重新判断档位。

2026-10-13 对照本机 Codex VS Code 扩展 `26.1007.21434` 的 `app-initial-7a199c66e670.js`、`app-initial-c014f9ee4429.js` 和对应 CSS：扩展从模型 `serviceTiers` 构建选项并按功能访问条件过滤；具备 Standard 与 Fast 选项时显示空心 / 实心闪电，开启状态采用蓝色。该本机安装带 `__CYBER_CODEX_FAST_PATCHED__` 标记，其功能限制补丁不作为官方规则，也未移植到工程。官方说明另见 Codex Speed 页面（`https://developers.openai.com/codex/speed`）。

在 Codex 聊天输入框单独发送 `/fast on` 开启 Fast，`/fast off` 关闭，`/fast` 查看状态；命令不区分大小写，命令菜单中也显示当前状态。开关作用于当前会话后续回合，不会作为提示词交给模型。已有线程通过 `thread/settings/update` 将当前选择的模型、推理强度和 Fast 档位一并更新，避免只改速度却仍使用旧线程的模型；旧 CLI 不提供该接口时，在下一次 `turn/start` 传入选择。开启使用 CLI 模型目录提供的 Fast 层级，关闭明确使用 `default` 标准速度，避免再次继承配置文件中的 Fast 默认值。模型明确不支持 Fast 或 CLI 配置关闭该功能时给出提示。

连接初始化声明 `capabilities.experimentalApi = true`，以使用当前 CLI 要求协商的 `thread/settings/update` 接口。

Fast 的实际支持与计费取决于模型和供应商。此开关不改写全局 `config.toml`。

## 参考实现

读取了 [cc-switch](https://github.com/farion1231/cc-switch/tree/90fb37ffb76bf06f2d021cd020b7f677216e916c)，固定快照为 `90fb37ffb76bf06f2d021cd020b7f677216e916c`。参考内容：

- `src/config/codexTemplates.ts`、`src/config/codexProviderPresets.ts`：供应商模板及直连端点。
- `src-tauri/src/live/floor.rs`、`src-tauri/src/live/project/codex.rs`：供应商拥有的字段、归一化到 custom 路由、独立认证。
- `src-tauri/src/services/provider/codex_editor.rs`、`codex_direct.rs`：编辑、切换及保留全局配置的规则。
- `src-tauri/src/database/schema.rs`、`database/dao/providers.rs`：CCS 数据库供应商字段和排列顺序。
- `docs/user-manual/zh/2-providers/2.1-add.md`、`2.2-switch.md`：新增与切换流程。

根据 [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)核对 `model_providers` 与 Responses 协议。Dart 实现使用 TOML AST 定位，只改动供应商拥有的表达式，其他源文本原样保留。cc-switch 为 MIT 许可，版权与许可包含在 [cc-switch.txt](../assets/licenses/cc-switch.txt) 中；主工程保留 GPL-3.0-only。
