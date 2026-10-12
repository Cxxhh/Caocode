# Caocode 工程约定

- 使用简体中文沟通；WSL 中使用 Linux/Bash 语法。
- 主开发目录为 `/home/noxae/Documents/Caocode`，工程根目录保留上游 Git 历史，开发分支为 `caocode/main`。
- `reference/baocode` 是独立的上游参考仓库，固定版本见 `tool/caocode/toolchain.json`；应用修改在主工程进行。
- 本地读取、检索和定位优先使用 FastCtx；不可用时使用 `rg`。机械替换先预览，语义修改使用 `apply_patch`。
- 使用 `./flutterw` 执行 WSL 的 Dart/Flutter 检查。修改后只运行相关测试，完整测试套件耗时很长。
- 使用 `./dev.sh` 从 WSL 启动 Windows 调试窗口；`r` 增量同步并热重载，`R` 热重启，`q` 退出。原生代码或依赖变动需重新启动脚本。
- 使用 `./build.sh` 在 Windows 本地目录增量同步并编译；`./build.sh --sync-only` 只同步。
- Windows 编译目录为 `C:\Users\11914\Documents\Caocode`，它是构建副本，代码修改在 WSL 完成。依赖、生成文件及编译缓存不参与同步。
- 同步按 SHA-256 比较文件内容。删除只处理此前同步记录中的文件，保留 Windows 自己产生的文件。
- Flutter 固定为 `3.47.5` / Dart `3.13.4`，避免上游自带的 Windows 字体引擎与 SDK 不匹配。
- 应用的代理执行底层目标为 Codex CLI 的 `codex app-server`。遵循初始化、线程、回合、事件和审批协议，模型列表由 CLI 提供。
- 保留上游 GPL-3.0-only 及各子包第三方许可证。
