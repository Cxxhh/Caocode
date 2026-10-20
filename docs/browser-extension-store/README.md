# 浏览器扩展：Chrome 应用商店上架资料

开发者后台（https://chrome.google.com/webstore/devconsole）里要填的内容都在这里，照抄即可。发布流程见 [release.md 第 11 节](../release.md#11-浏览器扩展)。

## 第一次上传

商店会按**第一次上传的包**定下扩展 ID。要让它沿用开发时的 ID `jfjagocghaaheooicmdnhcholmgdkngk`（BaoCode 只认这个 ID，开发者模式的 zip 也是这个 ID），第一次上传的 zip 根目录里要带私钥 `key.pem`：

```sh
tool/pack_browser_extension.sh --first-upload
# 上传 build/browser_extension/BaoCode-browser-<版本>-store.zip
```

上传后在后台确认 ID 是 `jfjagoc…`，然后把这个 zip **删掉**（里面有私钥）。以后的上传不带 `--first-upload`，交给 CI。

ID 不对的话（商店没认 key.pem），就在后台删掉这个草稿，检查 zip 根目录是否有 `key.pem` 后重新上传。草稿一旦发布，ID 就改不了了。

## 商店信息（Store listing）

**名称**：BaoCode（来自 `_locales`，中英文一样）

**简短说明**（来自 `_locales/*/messages.json` 的 `description`）：
- en：Lets BaoCode's agents use the tabs you share with them: open, read, click and type, as you watch.
- zh_CN：让 BaoCode 的 agent 使用你共享给它的标签页：打开、阅读、点击和输入，全程在你眼前。

**详细说明（English）**：

```
BaoCode is a desktop app for working with AI coding agents (Claude Code). This extension connects it to your own browser, so its agents can use the web the way you do: signed in as you, with your extensions and settings.

• Shared tabs only. The agents work in the tabs of the yellow "BaoCode" tab group: those they open, and those you share with the toolbar button. Your other tabs stay yours.
• Watch it work. BaoCode's side panel shows the tab live while the agent opens pages, clicks and types. Take over at any time.
• Show it once. Ask the agent to watch, do it yourself in the browser, click Done: it sees each step you took.
• Debug for real. Console messages, network requests and performance traces of the shared tab, for the agent to read.

Requires BaoCode (https://baocode.dev/download) on macOS. Everything stays on your computer: the extension talks only to BaoCode, through native messaging, never over the network.

Open source: https://github.com/baocode-dev/baocode
```

**详细说明（中文）**：

```
BaoCode 是一款与 AI 编程 agent（Claude Code）协作的桌面应用。这个扩展把它连到你自己的浏览器，让 agent 像你一样上网：带着你的登录状态、你的扩展和设置。

• 只用共享的标签页。agent 只在黄色的「BaoCode」标签页分组里工作：它自己打开的，以及你用工具栏按钮共享的。其他标签页仍然只属于你。
• 看着它操作。agent 打开网页、点击、输入时，BaoCode 的侧边栏实时显示这个标签页，你随时可以接手。
• 演示一遍就会。让 agent 看着，你自己在浏览器里操作一遍，点「完成」，它就能看到你的每一步。
• 真正的调试。共享标签页的控制台信息、网络请求和性能追踪，agent 都能读到。

需要在 macOS 上安装 BaoCode（https://baocode.dev/zh/download）。所有数据都留在你的电脑上：扩展只通过本地消息（Native Messaging）与 BaoCode 通信，不经过网络。

开源：https://github.com/baocode-dev/baocode
```

**类别**：Developer Tools（开发者工具）

**语言**：English（默认），另加 中文（简体）

**图片**：
- 图标：包里的 `icons/icon-128.png`，后台自动取
- 小型宣传图 440×280：`promo-small-440x280.png`（`python3 tool/make_brand_assets.py --extension` 生成）
- 截图 1280×800 或 640×400，至少一张：BaoCode 侧边栏里的网页镜像、对话里的浏览器步骤、Chrome 里黄色的 BaoCode 分组。用 BaoCode 截，裁到 1280×800。

**官网**：https://baocode.dev
**支持**：https://github.com/baocode-dev/baocode/issues

## 隐私（Privacy practices）

**单一用途（Single purpose）**：

```
Lets the BaoCode desktop app's AI agents use the browser tabs the user shares with them (the "BaoCode" tab group): open pages, read them, click, type, take screenshots and read console and network logs, while the user watches in BaoCode.
```

**权限理由**：

| 权限 | 理由 |
| --- | --- |
| `debugger` | The agents act in a shared tab through the Chrome DevTools Protocol: they read the page and its elements, click and type with real input events, take screenshots, and read the console, network requests and performance traces. Only tabs in the "BaoCode" tab group are attached to. |
| `nativeMessaging` | The extension's only connection: it talks to the BaoCode desktop app on the same computer through its native messaging host. Nothing goes over the network. |
| `tabs` | To list the tabs of the "BaoCode" group, open a page for an agent in a new tab there, and close or bring forward one of them when asked. |
| `tabGroups` | Shared tabs are those of the "BaoCode" tab group: the extension makes the group, and puts the tabs the user shares in it. |
| `alarms` | Reconnects to the BaoCode app every minute while it is not running, so the extension is ready as soon as the app starts. |

**远程代码（Remote code）**：No, I am not using remote code.

**数据使用（Data usage）**：勾选
- Website content（网页内容）：页面文字、截图，交给本机的 BaoCode。
- User activity（用户活动）：仅在用户同意“看我操作”时记录共享标签页里的点击和输入。

其他都不勾。下面三条声明全部勾选：
- I do not sell or transfer user data to third parties, outside of the approved use cases
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose
- I do not use or transfer user data to determine creditworthiness or for lending purposes

**隐私政策网址**：https://baocode.dev/browser-privacy

## 分发（Distribution）

- 公开（Public），所有地区。
- 审核说明（给审核员，在提交时的备注里）：

```
The extension needs the BaoCode desktop app (macOS, free, https://baocode.dev/download) to do anything: it only talks to the app, through native messaging. Without the app, its toolbar button opens a page saying how to get it. To try it: install BaoCode, open a folder, start a chat and ask the agent to open a web page; the tab opens in a yellow "BaoCode" tab group and the agent uses it.
```

## CI 自动提交（之后每个版本）

`.github/workflows/extension.yml` 的 `store` 任务用 Chrome Web Store API 上传并提交审核。需要在 GitHub 的 `release` 环境里配置：

| 名字 | 类型 | 怎么拿 |
| --- | --- | --- |
| `CWS_PUBLISHER_ID` | 变量 | 开发者后台 → 账号（Account）页里的 Publisher ID |
| `CWS_CLIENT_ID` | 密钥 | Google Cloud Console 新建项目 → 启用 Chrome Web Store API → OAuth 同意屏幕（外部，把自己加为测试用户）→ 凭据 → OAuth 客户端 ID（类型选“桌面应用”） |
| `CWS_CLIENT_SECRET` | 密钥 | 同上 |
| `CWS_REFRESH_TOKEN` | 密钥 | 打开 https://developers.google.com/oauthplayground ，右上角齿轮里勾选“使用自己的 OAuth 凭据”，填上面的 ID 和密钥；作用域填 `https://www.googleapis.com/auth/chromewebstore`，授权后换取令牌，复制 refresh token |
| `CHROME_WEB_STORE_URL` | 变量 | 上架通过后填 `https://chromewebstore.google.com/detail/jfjagocghaaheooicmdnhcholmgdkngk`。填之前 baocode.dev/dl/chrome-web-store 跳到下载页的说明 |

没配这些时，`store` 任务只给出提示，商店的 zip 在这次运行的产物（Artifacts）里，手动上传即可。

OAuth 同意屏幕处于“测试”状态时，refresh token 7 天就过期。要长期用，把同意屏幕发布为“正式”（只用这一个作用域、只给自己用，不需要 Google 审核）。
