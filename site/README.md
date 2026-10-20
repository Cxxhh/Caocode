# Caocode 网站参考素材

`site/` 保留了上游静态页面、截图与样式，尚未作为 Caocode 的独立网站部署。
其中旧功能展示不代表当前 Codex 版本的全部支持范围；当前项目介绍以根目录
[README](../README.md) 为准，安装包和更新日志以
[GitHub Releases](https://github.com/Cxxhh/Caocode/releases) 为准。

下列说明用于维护参考素材：

- English at the root, Chinese under `zh/` (`/zh/`, `/zh/download`,
  `/zh/changelog`); each page links to itself in the other language. A
  change to a page's copy goes into both. The Chinese pages use absolute
  paths (`/style.css`, `/shots/…`); the screenshots are shared.
- `changelog.html`, `zh/changelog.html`: made by
  `dart run tool/build_changelog.dart` from `release-notes/`. Edit those.

- `import.html`, `import.js`: a site's one-click import of an upstream,
  handed on to the app (`caocode://provider/import`); `upstreams.html`, how
  a site adds it. See `docs/upstream-import.md`.
- `site.js` keeps, on any page, where a visitor came from (`?abc` after
  any page's address, the site linking here, or direct); `head.js`,
  `activate.html`, `activate.js`, `channels.json` and `channels/`: the
  channels listed (lib/channel/). A channel asks to be listed with the
  `channel` issue template.
- `shots/`: the screenshots on the page.
- `sounds/`: the notification sound the page plays.
- `qr/`: the phone cards' QR codes, made by
  `dart run tool/make_download_qr.dart`.
- Copy marked `<mark class="todo">` is still to be written.
