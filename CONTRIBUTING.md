# Contributing to Caocode

[English](#english) · [简体中文](#简体中文)

## English

Issues and pull requests are both welcome. To keep review manageable, pull
requests have to follow the rules below; one that does not is closed without
a detailed review.

### Talk first

Open an [issue](https://github.com/Cxxhh/Caocode/issues) before you
write code for a new feature, a change in behavior or UI, a refactor, or a
new dependency, and wait until a maintainer agrees to the change and to how
it is done. Link that issue in the pull request.

These can go straight to a pull request: typos, translations, documentation,
and a bug fix that is small and obvious.

### Keep it small

- One pull request does one thing. Unrelated fixes, renames and reformatting
  go into pull requests of their own.
- About 400 changed lines at most, not counting tests and generated files.
  Split bigger work into steps that each build and pass their tests, and
  agree on the steps in the issue first.

**Large pull requests, and pull requests for changes not discussed first, are
not accepted.**

### Before you open it

- Match the code around your change: its naming, comment density and idiom.
  UI uses Caocode's own components, not stock Material or Cupertino widgets.
- Run `dart format` and `flutter analyze`, and the tests for what you changed,
  for example `flutter test test/update`. The full suite is slow; you do not
  need to run all of it.
- Add or update tests for what you fixed or added.
- Commit messages follow `type(scope): summary`, for example
  `fix(ide): ...`; see `git log` for more.
- You understand and can explain every line, including any written with an
  AI tool.
- Your contribution is licensed under the license of the files it changes:
  [GPL-3.0-only](LICENSE) for the app, MIT for `packages/bao_editor`,
  `packages/bao_xterm` and `packages/bao_pty`.

## 简体中文

欢迎提交 Issue 和 Pull Request。为了让审阅跟得上，PR 需要遵守下面的规则；
不符合的会直接关闭，不做详细审阅。

### 先讨论

新功能、行为或界面的改动、重构、新增依赖，写代码之前先开
[Issue](https://github.com/Cxxhh/Caocode/issues)，等维护者认可要不要改、
怎么改之后再动手，并在 PR 里关联这个 Issue。

以下可以直接提 PR：错别字、翻译、文档，以及小而明确的 bug 修复。

### 保持小

- 一个 PR 只做一件事。无关的修复、重命名、格式调整另开 PR。
- 改动不超过约 400 行（不含测试和生成文件）。更大的工作拆成几步，每一步都能
  单独编译、通过测试，并且先在 Issue 里商量好怎么拆。

**太大的 PR、未经讨论的 PR，不会被接受。**

### 提交之前

- 跟周围代码保持一致：命名、注释密度、写法。界面用 Caocode 自己的组件，
  不用 Flutter 自带的 Material / Cupertino 控件。
- 运行 `dart format`、`flutter analyze`，以及与改动相关的测试，例如
  `flutter test test/update`。完整测试很慢，不需要全部跑。
- 修复或新增的功能要补上或更新测试。
- 提交信息格式为 `type(scope): summary`，例如 `fix(ide): ...`，可参考 `git log`。
- 每一行你都理解、能解释，包括用 AI 工具写的部分。
- 你的贡献沿用所改文件的许可证：应用本体为 [GPL-3.0-only](LICENSE)，
  `packages/bao_editor`、`packages/bao_xterm`、`packages/bao_pty` 为 MIT。
