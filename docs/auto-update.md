# Caocode 自动更新

Caocode 从 [Cxxhh/Caocode 的 GitHub Releases](https://github.com/Cxxhh/Caocode/releases) 获取更新。当前 Windows x64 安装包支持检查、下载、校验、静默安装及重开；发布流程见 [release.md](release.md)。

## 更新地址

- 清单：`https://github.com/Cxxhh/Caocode/releases/latest/download/latest.json`
- 手动下载：`https://github.com/Cxxhh/Caocode/releases/latest`
- 更新日志：对应版本的 `releases/tag/v<公开版本>`
- 调试覆盖：环境变量 `CAOCODE_UPDATE_URL`，可指向本地测试清单。

更新在 Release 构建中启用；Debug 构建只在显式设置调试覆盖时启用。应用已停止使用上游更新渠道，遥测仍默认关闭。

## 用户行为

“设置 → 更新”显示当前公开版本（如 `1.1.0c`）、检查结果、下载进度和更新日志。

| `update.mode` | 行为 |
| --- | --- |
| `default` | 启动 30 秒后检查，此后每 6 小时检查；后台下载，提示重启更新 |
| `manual` | 仅手动检查，安装时下载 |
| `none` | 关闭更新检查 |

支持稍后安装和跳过版本。自动检查失败只记录状态；手动检查失败会显示错误。安装前走正常退出流程，保留未保存文件和正在执行任务的确认；取消退出就不会启动安装。

## 清单与校验

`latest.json` 包含内部数字版本、发布时间、中英文更新说明及各平台的安装包信息：

```json
{
  "version": "1.1.0+12",
  "notes": {"zh": "首个 Codex 版本", "en": "First Codex edition"},
  "platforms": {
    "windows-x64": {
      "url": "https://github.com/Cxxhh/Caocode/releases/download/v1.1.0c/Caocode-1.1.0c-setup.exe",
      "size": 12345,
      "sha256": "<64 位十六进制 SHA-256>",
      "signature": "<Ed25519 签名，base64>"
    }
  }
}
```

下载策略只接受此仓库的 HTTPS Release 附件地址，拒绝其他仓库、其他域名、凭据、非标准端口及路径越界。显式测试清单可以使用自己的来源地址。GitHub 下载重定向由 HTTP 客户端处理。

下载支持断点续传；完成后依次检查字节数、SHA-256 和 Ed25519 签名。签名使用 `caocode-update-v1` 格式，覆盖内部版本、平台、字节数和哈希；任一检查失败都不会安装。公钥内置于应用，私钥位于仓库外。

版本比较保持数字 semver 加 build；公开版本的 `c` 仅表示 Codex 版本。清单缺少当前平台时不会提供安装，已发布的同一数字版本也不会重复提供。

## Windows 安装

`tool/caocode.iss` 使用独立的 Caocode AppId：`da15d7fd-aed2-4f72-b2af-34c18d5db30c`。`WindowsUpdateInstaller` 用同一标识查找安装方式，并将 `/CURRENTUSER` 或 `/ALLUSERS`、安装目录、等待进程及 `/RELAUNCH` 参数传给安装器。

直接运行 `build/` 或复制后的可运行目录没有 `unins000.exe`，需要从发布页手动安装。安装器会记录日志；下次启动时若仍是旧版本，应用会提示更新未完成。

## 代码与检查

主要代码在 `lib/update/`，设置入口是 `lib/settings/pages/updates_page.dart`，发布工具是 `tool/release_manifest.dart`。

```bash
./flutterw test test/update
./flutterw analyze lib/update lib/settings/pages/updates_page.dart
```

测试覆盖版本比较、仓库地址限制、签名和文件校验、状态流转、安装参数及设置界面。正式发布后还需读取实际清单并核对附件的哈希和签名。
