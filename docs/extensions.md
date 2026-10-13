# 扩展（VS Code 插件）

Caocode **不运行 VS Code 插件的代码**。Node 扩展宿主曾经接入过，后来因为它让
工作台变重、变卡，在 `a572d6a`（2026-10-10）里整体移除了。现在扩展只用来装
**颜色主题和文件图标主题**；语言功能走原生 LSP 客户端，调试走原生 DAP 客户端。

## 现在的扩展

- 从 Open VSX 或拖入 `.vsix` 安装到 `<data>/extensions/`，用 VS Code 的布局
  （`publisher.name-version/` 加 `extensions.json`）。不支持开发文件夹。
- 只读取 manifest 的 `contributes.themes`、`iconThemes`、`colors`、`icons`
  并应用到工作台（`lib/extensions/theme_extensions.dart`，主题本身在
  `lib/theme/`）。
- 能力判定（`lib/extensions/capabilities/capability_analysis.dart`）只看主题：
  只有主题的算"支持"；有主题、也有代码或其他贡献点的算"部分支持"；没有主题的
  算"不支持"，不能安装。
- 扩展视图分两个页签："主题"和"语言服务器"。

| 目录（`lib/extensions/`） | 内容 |
| --- | --- |
| `theme_extensions.dart` | 安装、列出、应用主题扩展 |
| `gallery/` | Open VSX 客户端、安装/卸载后端 |
| `vsix/` | 读 `.vsix`、manifest、引擎版本、目标平台 |
| `capabilities/` | 能力判定 |
| `ui/` | 扩展视图、详情页、`.vsix` 拖入 |

测试在 `test/extensions/` 下，目录结构同上。

## 依赖插件的功能怎么办

用户要某个插件，实际要的往往是它提供的某项能力。做法是**原生补上这项能力**，
不把插件带进来。

- **语言功能**：用 LSP。服务器清单来自 `assets/lsp/languages.json`（取自 Helix）
  和 `assets/lsp/mason-registry.json`，可以用语言包或 `<data>/User/lsp.json`
  覆盖，见 `lib/ide/lsp/packs/README.md`。
- **调试**：DAP 客户端和调试视图在 `lib/debug/`，由 `lib/ide/ide_debug_host.dart`
  接到工作台。适配器要由 Caocode 自己注册（`DebuggerRegistry.setExtensions`）。
  **目前一个都没有注册。**

### 例：`ms-python.python`（2026-10-11）

有用户要求支持 `ms-python.python`。结论是不内置，原因如下：

- 它全是 JS 代码，没有扩展宿主就不会执行。
- 它的补全、跳转、类型检查来自 Pylance。Pylance 的许可只允许在微软的 VS Code
  里使用，Open VSX 上也没有。它还依赖 `ms-python.debugpy` 和
  `ms-python.vscode-python-envs`。

Python 能力的现状和缺口：

| 能力 | 现状 | 原生方案 |
| --- | --- | --- |
| 补全、跳转、类型检查 | 有。默认服务器是 `ty`、`ruff`、`jedi`、`pylsp`、`zuban`；mason 里有 `pyright`、`basedpyright` | 可以考虑把 `basedpyright` 设为默认，最接近 Pylance |
| 断点调试 | **没有**（没有注册适配器） | 注册 `python` 类型的调试器，用 `python -m debugpy.adapter` |
| 选解释器、venv/conda | 没有 | 扫描 `.venv`、conda、PATH，选中的解释器同时交给 LSP 和调试器 |
| 测试面板（pytest）、Jupyter | 没有 | 工作量大，暂不做 |
