# Caocode 版本与发布

源码和发布仓库：<https://github.com/Cxxhh/Caocode>。安装包、更新清单和校验文件全部作为 GitHub Release 附件发布，应用不再读取上游发布服务。

## 版本约定

首版公开名称为 **1.1.0c**，标签为 **v1.1.0c**。`c` 表示 Codex 版本。

| 用途 | 首版值 |
| --- | --- |
| 界面、安装包名称、GitHub Release | `1.1.0c` |
| Git 标签 | `v1.1.0c` |
| `pubspec.yaml`、`lib/update/version.dart`、更新清单 | `1.1.0+12` |
| Windows 可执行文件数字版本 | `1.1.0.12` |
| 安装包 | `Caocode-1.1.0c-setup.exe` |

Flutter 和 Windows 的数字版本保持兼容。更新按主、次、修订和 build 比较；后续发布必须增加 build，不能只改公开名称。`AppVersion.display` 和 `releaseTag` 统一生成带 `c` 的名称与标签。

## Windows 安装包

在 WSL 主工程运行：

```bash
./build.sh --installer
```

脚本先做静态检查、同步代码，再使用固定的 Windows Flutter SDK 编译，并调用 Inno Setup 6。打包模式在独立的 `runner/Package/<公开版本>/Release` 中构建，不覆盖正在运行的开发版本。

产物在 Windows 副本的 `build/installers/`。安装器定义在 `tool/caocode.iss`；可执行文件、快捷方式、卸载项和资源均使用 Caocode 标识，AppId 独立于上游。默认按当前用户安装，也支持按机器安装；自动更新保持原安装模式。

## 签名更新清单

应用除 SHA-256 外，还校验安装包元数据的 Ed25519 签名。首次准备本地密钥：

```bash
install -d -m 700 ~/.caocode-release
./flutterw pub get
~/.local/share/caocode/flutter-3.47.5/bin/dart run tool/release_manifest.dart \
  --generate-key ~/.caocode-release/update-signing.key
```

将工具输出的公钥写入 `lib/update/update_signature.dart` 后再编译应用。私钥只保存在仓库外，权限为 `600`；不要提交、上传到 Release 或写入发布说明。首版已经使用 Caocode 自己的公钥。

生成清单（安装包路径按本机调整）：

```bash
CAOCODE_UPDATE_SIGNING_KEY=~/.caocode-release/update-signing.key \
  ~/.local/share/caocode/flutter-3.47.5/bin/dart run tool/release_manifest.dart \
  --windows /mnt/c/Users/11914/Documents/Caocode/build/installers/Caocode-1.1.0c-setup.exe \
  --notes-zh release-notes/1.1.0c.zh.md \
  --notes-en release-notes/1.1.0c.en.md \
  --manifest build/installers/latest.json
```

下载地址由工具生成：`https://github.com/Cxxhh/Caocode/releases/download/v1.1.0c/<文件名>`。清单版本仍是 `1.1.0+12`。

## 提交与发布

本地开发分支为 `caocode/main`，发布到远端 `main`，保留上游历史：

```bash
git push origin caocode/main:main
git tag v1.1.0c
git push origin v1.1.0c
gh release create v1.1.0c --repo Cxxhh/Caocode --verify-tag \
  --title 'Caocode 1.1.0c' --notes-file release-notes/1.1.0c.zh.md \
  /mnt/c/Users/11914/Documents/Caocode/build/installers/Caocode-1.1.0c-setup.exe \
  build/installers/latest.json build/installers/SHA256SUMS.txt
```

发布前完成相关测试、静态检查和安装包校验。上传完成后检查 Release 附件和清单的实际下载，确认 SHA-256 与签名正确。首版仅发布 Windows x64；未提供安装包的平台不会收到更新。

`.github/workflows/release.yml` 提供手动 Windows 构建与安装包制品，适合复查构建。发布签名和正式 Release 由本地流程完成，不要求上游 Cloudflare、R2 或 macOS 签名密钥。
