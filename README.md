# Caocode

基于 [BaoCode](https://github.com/baocode-dev/baocode) 的新 IDE 工程，目标是将代理
执行底层迁移到 Codex CLI 的 `codex app-server`，继续使用现有编辑器、终端和
Flutter 桌面界面。已完成开发环境与 Windows 编译基线，默认代理已接入 Codex。
当前支持对话、图片、审批、会话保存与恢复；迁移范围见
[迁移说明](docs/caocode-migration.md)。

在 WSL 开发源码，从终端启动 Windows 开发窗口：

```bash
cd /home/noxae/Documents/Caocode
./setup.sh
./dev.sh
```

首次启动自动构建 Debug，之后修改 Dart 代码，回到终端按 `r` 增量同步并热重载；
`R` 热重启，`q` 退出。开发完成后用 `./build.sh` 生成 Windows Release 程序。
`./build.sh --sync-only` 只同步，`./build.sh --debug` 单独构建 Debug。
同步按内容校验，只复制变更文件，保留 Windows 依赖和编译缓存。
开发环境、同步规则和检查命令见 [开发说明](docs/caocode-environment.md)。

| 路径 | 用途 |
| --- | --- |
| 工程根目录 | 本地派生工程，保留上游 Git 历史，开发分支 `caocode/main` |
| `reference/baocode` | 固定版本的独立上游参考仓库 |
| `lib/` | Flutter 应用及代理内核 |
| `packages/` | 编辑器、终端、PTY 和远程模块 |
| `tool/caocode/` | 初始化、增量同步、开发启动、Windows 编译及 Codex 协议检查 |
| `C:\Users\11914\Documents\Caocode` | Windows 构建副本 |

上游基线和 Flutter 版本固定在 [toolchain.json](tool/caocode/toolchain.json)。
当前为本地派生仓库，远程 `upstream` 指向原工程。

---

以下为上游 BaoCode 项目说明。原始参考副本见 `reference/baocode/README.md`。

# BaoCode
<a href="https://trendshift.io/repositories/289180?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-289180" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/289180/daily?language=Dart" alt="baocode-dev%2Fbaocode | Trendshift" width="250" height="55"/></a>

An awesome, easy-to-use desktop UI for [Claude Code](https://github.com/anthropics/claude-code), with a millisecond-fast IDE built in.

[Website](https://baocode.dev) · [Download](https://baocode.dev/download) · [Changelog](https://baocode.dev/changelog)

![BaoCode's main window: agents grouped by project, two conversations side by side, and the model picker](site/shots/main.png)

## Why

We use Claude Code every day. The terminal is a fine place to run it, but a poor place to read it: long diffs scroll out of view, earlier steps are hard to find again, and reviewing what changed means switching to another app. BaoCode is the window we wanted around it.

BaoCode has no agent of its own, by design. Claude Code is the agent, and its ecosystem is unmatched: its tools, skills, plugins, MCP servers, subagents and hooks. BaoCode gives it the interface it deserves and makes everything around it work out of the box. It runs the Claude Code you already have, with your settings and your `CLAUDE.md`.

## Features

- **An interface made for reading.** Reads, searches and commands fold into single lines. Keep or Undo each change Claude made, file by file; checkpoints live in BaoCode's own data folder, never in your repository's `.git`.
- **Goals.** Type `/goal` and what you want done, and Claude keeps working until it is met, with the goal and its progress above the input.
- **A rich-text input.** Code copied from the editor arrives as a reference to its file and lines; pasted images and dropped files sit where you put them in the sentence.
- **Fast IDE.** An editor, a terminal and Source Control with a commit graph, built in. Claude Code drafts your commit messages. VS Code, IntelliJ, Sublime and Atom keymaps, and language servers.
- **Your VS Code themes.** The editor, the conversation and the sidebar all follow them.
- **Skills, MCP servers and more.** Plugins, MCP servers, skills, subagents, rules, commands and hooks in one place, for you or for a single project.
- **Any model.** Add an upstream that speaks Anthropic's API, OpenAI's Chat Completions or OpenAI's Responses; a local proxy translates between it and Claude Code. Keys stay in the system keychain.
- **Remote projects over SSH.** The window stays on your machine; files, Git, search, terminals, language servers and Claude Code run on the remote host (Linux, x64 or arm64).
- **Notifications.** A system notification, a sound and a badge when an agent needs you or finishes. Close the window and the agents keep running in the menu bar or tray.
- **Updates itself** in the background, or manually, or not at all.

## Speed

VS Code and Cursor are built on Electron: each window is a web page, and every copy carries its own Chromium and Node.js. BaoCode is a native app that draws its own interface straight to the GPU.

| | BaoCode | VS Code | Cursor |
| --- | --- | --- | --- |
| Launch | ≈ 0.18 s | ≈ 2–3 s | ≈ 2–3 s |
| Memory, one window idle | ≈ 120 MB | ≈ 970 MB | ≈ 1.9 GB |
| Processes, one window | 2 | 8 | 13 |
| Download size, Windows | ≈ 16 MB | ≈ 244 MB | ≈ 214 MB |

## Requirements

- macOS 12 or later (Apple silicon or Intel, one download each), or Windows 10 or later (x64).
- [Claude Code](https://github.com/anthropics/claude-code), installed.

## Building from source

BaoCode is a Flutter app (Dart SDK `^3.13.4`).

```sh
flutter pub get
flutter run -d macos        # or: flutter run -d windows
```

To build what is released, into `build/installers/`:

```sh
dart run tool/build_macos.dart            # BaoCode-<version>-{arm64,x64}.dmg and BaoCode-<version>-mac-{arm64,x64}.zip
dart run tool/build_windows.dart          # BaoCode-<version>-setup.exe (needs Inno Setup)
dart run tool/build_remote_server.dart    # the SSH remote server, for Linux x64 and arm64
```

The full test suite is slow; run the tests for what you changed, for example `flutter test test/update`.

Releases are built and published by CI when a `v*` tag is pushed; versions, signing and where releases go are in [docs/release.md](docs/release.md). More in [docs/](docs): [auto-update](docs/auto-update.md), [SSH remote](docs/ssh-remote.md), [Windows](docs/windows.md) (some are in Chinese).

## Repository

| Path | What it is |
| --- | --- |
| [lib/](lib) | The app |
| [packages/bao_editor](packages/bao_editor) | Monaco, ported to Flutter: the editor, its highlighting, VS Code's themes and keybindings |
| [packages/bao_xterm](packages/bao_xterm) | A Dart port of xterm.js |
| [packages/bao_pty](packages/bao_pty) | Pseudo terminals for Dart: forkpty on macOS and Linux, ConPTY on Windows |
| [packages/bao_remote](packages/bao_remote) | The remote host served over SSH |
| [macos/](macos), [windows/](windows) | The native runners |
| [tool/](tool) | Build, packaging and release scripts |
| [site/](site) | The website, [baocode.dev](https://baocode.dev) |
| [docs/](docs) | Design notes |

## Feedback

Issues are welcome. Pull requests are not accepted.

## License

BaoCode is licensed under the [GNU General Public License v3.0](LICENSE)
(GPL-3.0-only). The editor and terminal packages in [packages/](packages)
(bao_editor, bao_xterm, bao_pty) are MIT. Third-party components keep their
own licenses, found next to them in the source tree.

BaoCode is an independent project, not affiliated with or endorsed by
Anthropic.
