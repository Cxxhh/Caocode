# Caocode 开发环境

主源码位于 `/home/noxae/Documents/Caocode`；Windows 构建副本位于
`C:\Users\11914\Documents\Caocode`。工程根目录是基于 BaoCode 的本地派生仓库，
保留原始历史，分支为 `caocode/main`，远程 `upstream` 指向原仓库。
`reference/baocode` 为独立参考副本，固定在 `075939cf5a243b46a38d645bc59116c87ba0b13d`。
当前没有创建 GitHub 远程 fork，也没有推送代码。

## 初始化与编译

在 WSL 的工程根目录运行：

```bash
./setup.sh                         # 安装/验证两端 SDK，获取依赖，同步代码
./dev.sh                           # 启动 Windows 开发窗口，支持热重载
./flutterw analyze lib packages test tool  # WSL 静态检查，排除参考副本
./flutterw test test/kernel_test.dart  # 按修改范围选择测试
./build.sh                         # WSL 检查、增量同步、Windows Release 编译
./build.sh --debug                 # Windows Debug 编译
./build.sh --sync-only             # 仅增量同步
./build.sh --doctor                # 检查 Windows 工具链
python3 tool/caocode/sync_windows.py --dry-run --verbose
python3 tool/caocode/check_codex.py            # WSL Codex 协议握手与模型发现
python3 tool/caocode/check_codex.py --windows  # Windows Codex 协议握手与模型发现
```

## 终端开发启动

日常开发运行 `./dev.sh`。它先将 WSL 的改动增量同步到 Windows，再启动
`flutter run -d windows --debug`。首次启动需要构建 Debug；后续启动复用
Windows 的编译缓存。开发窗口会持续运行，终端接收 Flutter 的运行输出。

启动日志带有 UTC 时间和 `[Caocode][启动]` 标记，集中输出到运行 `./dev.sh` 的终端。
主窗口首帧绘制完成后输出“启动成功”及耗时；初始化或首次绘制异常时，输出
“启动失败”、所在阶段和原因。同步或启动命令失败也会在该终端报告。
这些启动日志仅用于 Debug 开发模式。

修改 WSL 源码并保存后，在启动脚本的终端按：

| 按键 | 行为 |
| --- | --- |
| `r` | 增量同步，再热重载 Dart 修改，保留当前界面状态 |
| `R` | 增量同步，再热重启 Dart 应用，重新执行初始化 |
| `s` | 只增量同步 |
| `q` | 关闭本次开发窗口，退出脚本 |

热重载不能重新执行 `main`、初始化已有对象，或应用所有类型结构变动；这些修改
使用 `R`。修改 `windows/` 原生代码、插件或 `pubspec.yaml` 依赖后，先 `q`，
再运行 `./dev.sh` 重新构建。`./dev.sh --sync-only` 可单独同步。

Flutter 桌面程序首次运行仍需要生成原生 Debug 程序。日常 Dart 修改通过热重载
更新；交付时才运行 `./build.sh` 生成 Release。调试输出仅显示在启动终端，
应用的文件日志及日志开关已移除。

## 工具链与产物

Flutter `3.47.5` / Dart `3.13.4` 与上游 CI 相同。WSL SDK 位于
`~/.local/share/caocode/flutter-3.47.5`，Windows SDK 位于
`C:\Users\11914\develop\flutter-3.47.5`。脚本自动设置自身进程的 PATH。
Windows 需要 PowerShell 7、Git，以及 Visual Studio 的 C++ 桌面工具链。
脚本自动为本地 Flutter 插件创建目录联接，无需管理员符号链接权限。
Windows 引擎资源通过 `curl.exe` 从 Flutter 官方资源地址下载并缓存，首次解压后
按引擎版本复用，以处理当前 Dart 下载器的连接和文件占用问题。
`setup.sh` 不自动安装 Visual Studio 或 Android SDK。

Windows 输出位于 `C:\Users\11914\Documents\Caocode\build\windows\x64\runner\Release\caocode.exe`。
可执行文件和同目录的 DLL、`data` 文件夹需要一起保留。
当前脚本生成可运行的目录，不生成 Inno Setup 安装包。

可通过 `CAOCODE_FLUTTER_SDK` 指定 WSL SDK、`CAOCODE_WINDOWS_DIR` 指定 Windows
挂载目录。Windows PowerShell 脚本支持 `-FlutterSdk` 指定 Windows SDK。

## 同步规则

同步清单来自 Git 的已跟踪文件和未被忽略的新文件，因此未提交的修改也会同步。
WSL 计算源码校验值，Windows 本地检查目标文件，避免反复跨系统读取目标文件。
每个文件按 SHA-256 比较；内容相同的文件不会复制，时间戳不被改写。
Windows 的依赖、Flutter 生成文件、`build`、`.git` 和参考仓库不参与复制。
构建副本的 `.caocode-sync.json` 记录同步源和受管理文件。

源码删除时，只删除上次记录中对应的构建副本文件；如果这个文件在 Windows
被单独修改，则停止并报告。Windows 编译产生的其他文件保留。
同步失败可重新运行；文件复制经过内容校验和原子替换。

上游基线静态检查有 6 条已有告警/提示；编译脚本打印这些提示并以编译错误作为
失败条件。修改模块可单独运行严格静态检查和相关测试。

## Codex 接入方向

默认内核为 `Codex CLI`，真实进程传输、初始化、模型发现、会话保存、恢复、
审批和配置入口已接入。打开 WSL UNC 工程时，Windows 应用通过 `wsl.exe`
在对应发行版内启动 Linux Codex；普通 Windows 路径启动 Windows Codex。
应用设置位于 Caocode 独立数据目录，Codex 沿用自身的登录状态和配置。
详细范围见 [迁移说明](caocode-migration.md)。

协议依据 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)：
通过 stdio 交换 JSON 行，先完成 `initialize` / `initialized`，再调用
`thread/start`、`turn/start`；持续处理事件和服务端审批请求。
