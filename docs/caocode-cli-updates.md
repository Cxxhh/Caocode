# 在设置中更新 Codex CLI

打开 **设置 → 更新 → Codex CLI**，查看当前版本、运行环境及可执行文件路径。
点击 **检查更新** 获取最新稳定版；有更新时，点击 **更新 Codex CLI**。
升级成功后会重新读取当前路径的版本，新会话使用新版本。已有会话可在重启应用后继续。

Windows 桌面版按界面选中的运行环境检查 Windows 或对应 WSL2 发行版的 CLI，
遵循该环境的可执行文件路径设置及 `CAOCODE_CODEX_PATH`。
环境选择和独立配置见[切换 Windows 与 WSL2 Codex](caocode-codex-environments.md)。
npm 全局安装保留原安装前缀；独立安装使用 CLI 的内置更新命令。
无法识别为可自动更新的安装仍可检查版本，升级使用原安装方式。
网络或命令失败会显示错误，可以重试。Caocode 自身的更新模式不控制 CLI 的手动更新。

本次验证：55 项相关回归通过，新增代码静态检查无问题，宽屏与窄屏渲染已检查。
WSL、Windows 以及 Windows 调用 WSL 均实测通过当前版本和线上稳定版的只读检查；
升级命令通过模拟进程验证，未升级本机已有 CLI。

Codex CLI 原生终端可以输入 `/subagents`，选择子线程查看或继续其工作。
Caocode 已接入子代理卡片、切换列表及只读详情；操作和能力见
[查看与切换 Codex 子代理](caocode-subagents.md)。

协议依据：[OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server)、
[CLI 子线程切换命令](https://learn.chatgpt.com/docs/developer-commands)。
