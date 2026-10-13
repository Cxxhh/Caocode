# 手机连接（扫码或局域网发现配对、端到端加密）

手机上的 Caocode（`../mobile`）通过扫码、或在「附近的电脑」里选择，与桌面端配对。之后经**局域网或公网直连**查看并操作桌面端的智能体。两端之间的内容端到端加密。

Caocode 当前工程只包含桌面端服务和配对设置，手机 App 为上游独立工程。
Codex 工作区屏蔽 Claude 专有的扩展列表，原实现保留；手机客户端应按以下能力
字段隐藏或禁用入口：`state.canListExtensions`、`session.canUndo`、
`session.canUndoFiles`、`session.canStopTasks`。服务端对不支持的操作返回
`unsupported`，不会静默成功。模型、权限和推理强度来自当前会话的 `choices`。

密钥只在配对时交换一次，之后两端只认对方的公钥。电脑换了 IP，手机会通过局域网发现（DNS-SD/Bonjour）自动找到它，也可以在手机上手动改地址。中转服务只**预留接口**，尚未实现。

- 协议与加密：`packages/bao_link/`（纯 Dart，两端共用；`dart:io` 部分在 `bao_link_io.dart`）
- 桌面端：`lib/link/`（`LinkHost` 监听与配对，`WorkspaceBridge` 把 Workspace 暴露给手机），设置页 `lib/settings/pages/mobile_page.dart`（设置 → 手机）
- 手机端：`../mobile/lib/link/`（`PhoneLink` 连接与配对，`link_store.dart` 存储），`lib/state/app_state.dart` 把收到的状态并入界面
- 测试：`packages/bao_link/test/`、`test/link/`、`test/settings/mobile_page_test.dart`、`../mobile/test/link_test.dart`

## 1. 用户怎么用

1. 桌面端：设置 → 手机 → 「显示二维码」（会顺带打开「允许手机连接」并开始监听，默认端口 47100）。
2. 手机端：我的 → 已配对的电脑 → 配对新电脑，扫码；扫不了码就在桌面端点「复制链接」，在手机上粘贴。
   也可以不扫码：电脑在显示二维码期间，同一网络里的手机能在配对页的「附近的电脑」里看到它，点一下就会发起配对。
3. 两边都会显示 4 组 3 位数的安全码。核对一致后在手机上点「一致，完成配对」；不一致就在任意一端取消。从「附近的电脑」发起的配对没有二维码里的一次性令牌，所以电脑上也要点「允许」才会保存。
4. 之后手机打开 App 会自动重连，断线后会退避重试（2s、4s……最长 30s），从后台回来会立刻重试。尝试顺序：
   - 先试用户手动填的地址；
   - 再试局域网发现找到的地址；
   - 最后试电脑上次告诉它的地址。
5. 电脑换了 IP：只要在同一局域网，手机发现它的新地址后会立刻重连。不在同一局域网时，在手机的「已配对的电脑 → 这台电脑 → 连接地址」里手动添加或修改地址。两种情况都不用重新配对。

公网访问有两种方式：一是桌面端如果有公网 IPv6 地址，会自动写进二维码；二是在「公网地址」里填域名或 IP（需要在路由器上转发端口），多个用逗号分隔。

## 2. 二维码里有什么

`caocode://pair?d=<base64url(JSON)>`，JSON 字段：

| 字段 | 含义 |
| --- | --- |
| `v` | 版本，目前是 1 |
| `n` | 桌面端名称 |
| `k` | 桌面端长期公钥（X25519，base64url） |
| `t` | 一次性令牌（16 字节随机数），只有看到二维码的人知道 |
| `x` | 过期时间（Unix 秒），默认 10 分钟 |
| `a` | 地址列表 `host:port`，局域网在前、公网在后，IPv6 写成 `[addr]:port` |
| `r` | 预留：中转 `{u: url, r: room}`，目前不会出现 |

## 3. 加密与握手

每台设备生成一对长期 X25519 密钥，私钥不离开设备：桌面端存在 `state/mobile.json`（权限 600），手机端存在 App 私有目录的 `link.json`。设备 id 是公钥 SHA-256 的前 16 字节（hex），指纹是同一串每 4 位分一组。

握手类似 Noise IK，手机发起，事先已知桌面端的长期公钥 `S`：

1. 手机 → 桌面：`[1][e_c (32)][secretbox(k0, nonce=0, C)]`，其中 `k0 = SHA256("caocode-link-v1 hello" ‖ DH(e_c, S))`，`C` 是手机的长期公钥。这样即使经过中转，也看不到是哪台手机在连。
2. 桌面 → 手机：`[1][e_s (32)]`。
3. 双方计算 `SHA512("caocode-link-v1" ‖ DH(e_s,e_c) ‖ DH(S,e_c) ‖ DH(e_s,C) ‖ SHA256(两条握手消息))`，前 32 字节是手机→桌面的密钥，后 32 字节是桌面→手机的密钥。只有持有 `S` 私钥的桌面和持有 `C` 私钥的手机能得到这两把密钥。临时密钥用完即弃，所以事后泄露长期密钥也解不开以前的流量（前向保密）。

之后每条消息都用 XSalsa20-Poly1305（NaCl secretbox）加密，nonce 是每个方向各自递增的计数器。任何一条解不开，连接就断开。

**安全码**：`SHA256("caocode-safety" ‖ 桌面公钥 ‖ 手机公钥)` 前 12 字节，每 3 字节取模 1000，得到 4 组数字。中间人只有换掉其中一把公钥才能插进来，而那样安全码就对不上。

**配对授权**：桌面端只接受三类手机：
- 已配对的手机，按公钥识别。
- 带着当前二维码令牌的手机。令牌比较是常数时间，过期即作废。这一类在手机发来 `confirm` 后就保存。
- 在「附近的电脑」里找到它、发起请求的手机（hello 带 `request: true`）。只在电脑正在配对（二维码显示中）时接受，否则回 `notPairing`。这一类要等手机发来 `confirm`、并且桌面端用户点了「允许」（`LinkHost.approvePending`）才保存；`confirm` 的应答会一直等到用户点「允许」，用户拒绝则返回 `rejected`。

同一时刻只允许一台手机处于核对状态，另一台再来会收到 `busy`。核对期间桌面端只把它记在内存里。

## 3.1 局域网发现

桌面端在「允许手机连接」且「局域网发现」打开时（设置 → 手机，默认开），用 DNS-SD 广播服务 `_caocode._tcp`：
- 端口：监听的端口；
- 服务名：电脑名；
- TXT 记录：`v=1`、`k=<桌面公钥 base64url>`、`p=1|0`（是否正在配对）。

格式见 `packages/bao_link/lib/src/discovery.dart` 的 `LinkAdvert`。实现上：
- 桌面端用 `bonsoir` 插件广播（`link_platform_io.dart`），状态变化时由 `LinkHost._syncAdvert` 重新广播；
- 手机端用 `bonsoir` 浏览（`../mobile/lib/link/desktop_discovery.dart`）；
- iOS 和 macOS 的 Info.plist 都声明了 `NSBonjourServices` 和 `NSLocalNetworkUsageDescription`。

广播的内容都是公开信息：名字、公钥、是否在配对。有人冒充广播也没用，因为手机连接时用的是配对时记下的公钥（IK 握手），只有持有对应私钥的电脑才能完成握手。发现只提供地址，不交换密钥。

## 4. 消息

安全通道之上是 JSON 消息（`LinkPeer`）：

- 请求 `{"id", "m", "p"}`；应答 `{"id", "r"}` 或 `{"id", "e": {"c", "m"}}`
- 事件 `{"ev", "p"}`

手机 → 桌面的方法见 `LinkMethods`：

- 配对相关：`hello`、`confirm`、`unpair`
- 状态与订阅：`state`、`open`、`close`
- 操作会话：`send`、`stop`、`answer`、`choose`、`rename`、`pin`、`archive`、`keep`、`undo`
- 后台任务：`stopTask`（停任务或子代理）、`output`（命令输出的最后 64K 字符；手机打开终端页时每秒读一次）
- 文件：`files`（列出项目文件，最多 2 万个，跳过 node_modules 等；附带各会话还没保留的改动）、`read`（读文件，最大 512KB，二进制和过大文件不传；被改过的文件附带改动前的原文，手机据此显示改动）
- 扩展：`extensions`（本机用户级和各本地项目的技能、MCP、插件、子代理，来自「自定义」用的 `CustomizationStore`）
- 新对话：`draft`（项目的「新对话」智能体，和桌面端 New Chat 用的同一个，发消息前不出现在列表里）。手机 `open` 它拿到可选的模型、模式、权限、思考强度，用 `choose` 选好，再 `send` 给它，就按选好的设置开始。
- 项目图标：`state` 里每个项目带 `icon`（emoji、codicon 加主题色、图片、厂商 logo，格式同桌面端 `ProjectIcon.toJson`）。图片用 `icon`（`{id}` → `{kind, data}`）读取；id 由内容算出，手机按 id 缓存。

`files`、`read` 和新建会话的 `send` 只认侧栏里列出的项目（按项目路径匹配），读文件的路径归一化后必须仍在项目根目录内，所以手机拿不到项目以外的文件。多文件夹工作区和 VS Code 的多根资源管理器一样：每个文件夹以它的名字作为顶层（`mobile/lib/main.dart`），列文件、读文件、会话改动的路径、`@文件` 都按这个命名；手机发来的 `@文件` 会换成文件的完整路径再交给智能体。智能体改了项目以外的文件时，手机拿到的是完整路径，只有这种被该项目智能体改过的文件可以按完整路径读取。`send` 可以带图片（`images`，base64，png/jpeg/gif/webp，桌面端接着会话里的编号往下编，并在文字末尾写上 `[Image #N]`）和 `@文件`（`mentions`，相对项目根目录的路径）。

桌面 → 手机的事件：`state`（项目和会话列表，有变化时推送，每 150ms 最多一次）、`session`（已订阅会话的增量更新，包括后台任务列表 `tasks`）、`unpaired`。

**会话增量**：`open` 时先返回整个会话，之后只发从第一个变化的条目开始的部分（`start` + 之后的条目）。判断“变没变”时，先看是不是同一个对象；对象不同再比较 JSON。条目的 JSON 格式见 `lib/link/chat_codec.dart`；手机端 `lib/link/chat_codec.dart` 是同一份文件，只改了头部注释。工具输出、命令输出超过 64KB 的部分会截掉。

应答请求（工具权限审批、提问、计划审批）的格式见 `lib/link/interaction_codec.dart`。手机端的模型在 `../mobile/lib/models/interaction.dart`。

## 5. 中转（预留，未实现）

现在已经预留的部分：

- `RelayEndpoint(url, room)`：二维码的 `r` 字段、手机端 `KeptDesktop.relay` 都能存它。
- `LinkConnector.connect` 会先同时尝试所有直连地址；全部失败且有 `relay` 时抛 `LinkRelayUnavailableException`，手机提示“只能经中转连接，中转服务暂不可用”。
- 桌面端设置页有一行「中转：暂不可用」。

以后实现时：

1. 中转服务（`../relay`，Cloudflare）只转发 `LinkSocket` 的二进制消息：两端各连一条 WebSocket 到 `url`，按 `room`（建议用桌面端 id）配对，原样转发。它看不到内容，也看不到是哪台手机（手机公钥在 hello 里是加密的）。
2. 实现一个 `LinkSocket`，在 `LinkConnector.connect` 里把抛异常换成连接中转；桌面端在启用中转时也连上去，并在 `PairingOffer.relay` 里写上地址。
3. 握手和上层协议都不用改。

## 6. 已知限制

- 首次打开很长的会话会一次性传完整历史（未分页）。
- 局域网发现只在同一局域网（同一组播域）内有效。跨网段、访客 Wi-Fi 隔离的环境下，要在手机上手动填写地址。
- 手机在 iOS 上第一次使用时会弹出「本地网络」授权，拒绝后既发现不了电脑，也连不上局域网地址。
- 定时任务页在手机端仍是演示数据，没有接到桌面端。
- 通知（智能体需要处理、完成一轮）由手机在本地发出，只在 App 打开或刚切到后台、连接还在时有效；被系统挂起后收不到，远程推送要等中转服务。
- 扩展页只列出、不能在手机上安装或开关；远程（SSH）项目的扩展暂不列出。
- 桌面端取消配对时，如果手机不在线，手机下次连上会被拒，目前只显示为离线，需要在手机上手动移除后重新配对。
