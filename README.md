# Caocode

Caocode 是基于 [上游桌面 IDE](https://github.com/baocode-dev/baocode) 开发的 **Codex 版本**，使用本机的 `codex app-server` 运行代理，在桌面窗口中查看对话、工具调用、审批和代码差异。

[下载 Windows 安装包](https://github.com/Cxxhh/Caocode/releases/latest) · [版本发布](https://github.com/Cxxhh/Caocode/releases) · [反馈问题](https://github.com/Cxxhh/Caocode/issues)

首个发布版本：**1.1.0c**。当前提供 Windows x64 安装包。

## 功能

- Codex 新建、恢复和归档会话，支持流式消息、工具执行和审批。
- 模型列表来自 Codex CLI，可直接选择模型、推理强度及权限模式。
- 输入栏的闪电按钮控制 Fast；支持 `/fast on`、`/fast off` 和 `/fast` 查询。关闭后按钮仍保留，长模型名称和窄窗口不会把它挤出视口。
- 管理 Codex 供应商，支持从 CC Switch（CCS）的数据库导入，或连接数据库并刷新；连接模式只读，由 CCS 负责添加和修改。
- 内置编辑器、终端、Git、文件浏览及代码差异视图。
- 独立的 Caocode 数据目录、中英文界面和 GitHub Releases 更新渠道。

第三方模型的 Fast 请求由供应商决定是否接受。供应商、数据库连接与 Fast 的详细说明见 [Codex 供应商文档](docs/codex-providers.md)。

## 安装与使用

1. 从 [发布页](https://github.com/Cxxhh/Caocode/releases/latest) 下载并运行 `Caocode-1.1.0c-setup.exe`。支持 Windows 10/11 x64，默认按当前用户安装。
2. 安装并配置 [Codex CLI](https://github.com/openai/codex)，确保终端中可以运行 `codex`；也可在 Caocode 的 Codex 设置中指定 CLI 路径。
3. 打开项目文件夹，在设置中选择或配置 Codex 供应商，然后开始对话。
4. 后续版本可在“设置 → 更新”中检查、下载并重启安装。直接运行构建目录的用户需要手动安装更新。

Caocode 的数据与上游独立：Windows 默认使用 `%APPDATA%\caocode`，WSL/Linux 使用 `~/.config/caocode`；可通过 `CAOCODE_DATA_DIR` 指定其他目录。供应商连接不会修改 CCS 数据库。

## 开发与构建

主源码在 WSL 中维护，Windows 目录是增量同步的构建副本。固定使用 Flutter **3.47.5** / Dart **3.13.4**，并需要 Windows PowerShell 7、Visual Studio C++ 桌面工具链；制作安装包还需要 Inno Setup 6。

```bash
./setup.sh                         # 初始化两端工具链与依赖
./dev.sh                           # Windows 调试窗口；r 热重载，R 热重启
./flutterw analyze lib packages test tool
./flutterw test test/kernel/codex_test.dart test/chat/codex_choices_test.dart
./build.sh                         # 编译 Windows Release 可运行目录
./build.sh --installer             # 编译并制作 Windows 安装包
```

安装包位于 Windows 构建副本的 `build/installers/`。公开版本名称为 `1.1.0c`，Git 标签为 `v1.1.0c`；Flutter 和更新清单使用 `1.1.0+12`，Windows 使用数字文件版本。`c` 表示 Codex 版本，不影响更新时的数字版本比较。

发布步骤见 [发布文档](docs/release.md)，更新协议见 [自动更新](docs/auto-update.md)，开发环境见 [环境说明](docs/caocode-environment.md)。完整测试套件耗时较长，日常按修改范围选择测试。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `lib/kernel/codex/` | Codex CLI 通信、会话与供应商管理 |
| `lib/` | 桌面应用、编辑器、设置和更新 |
| `packages/` | 编辑器、终端、PTY、连接与远程服务基础包 |
| `windows/`、`macos/` | 原生窗口与平台接口 |
| `tool/caocode/` | WSL/Windows 同步及构建脚本 |
| `docs/` | 功能、开发和发布文档 |
| `reference/baocode/` | 本地上游参考副本，不随工程推送 |

当前发布验证覆盖 Windows。SSH 远程 Codex、目标和子代理等迁移范围见 [Codex 迁移说明](docs/caocode-migration.md)；上游 Claude 实现保留用于迁移参考和回归测试。

## 参与贡献

欢迎提交 Issue 和 Pull Request；功能或行为改动请先在 Issue 中讨论，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证与来源

Caocode 保留上游 Git 历史，基于 GPL-3.0-only 发布，见 [LICENSE](LICENSE)。`packages/` 及第三方资源的许可证保留在各自目录中。上游来源与固定版本见 [toolchain.json](tool/caocode/toolchain.json)。

本项目是独立的社区项目，与 OpenAI、Anthropic 及上游维护者不存在官方关联。
