# 公网访问：用 Cloudflare Tunnel 打通

手机在外网连桌面端，本来是靠「公网地址」直连（在路由器上转发端口，或桌面端有公网 IPv6）。如果你**没有公网 IP**、也不想在路由器上开端口，可以用 Cloudflare Tunnel：由 Cloudflare 给你一个固定域名，流量经它转发到本机的 47100。

这份文档手把手走一遍。全程不用写代码，靠一个 MCP 工具完成。协议和配对原理见 [`mobile-link.md`](./mobile-link.md)。

## 0. 前提

- 有一个**托管在 Cloudflare 的域名**（免费套餐就够）。
- 桌面端 BaoCode 正在运行，设置 → 手机 → 打开「允许手机连接」（默认监听 **47100**）。
- 装了 [Claude Code](https://claude.com/claude-code)，或者任何支持 MCP 的客户端。

文中用 `example.com` 代替你自己的域名，`link.example.com` 是要用的子域——**照着做的时候换成你自己的**。

## 1. 地址要写成 `wss://`

先理解这一点，不然后面会卡住。

Cloudflare 的隧道入口在 **443 端口只收 TLS**，所以手机要用 `wss://` 去连。公网地址写成 `wss://link.example.com`，手机就会走 TLS（[`packages/bao_link/lib/src/pairing.dart`](../packages/bao_link/lib/src/pairing.dart) 的 `DirectEndpoint.parse`，`secure` 为真）：

```
手机 → wss://link.example.com:443/baocode-link
     → Cloudflare（443，TLS 在这里卸掉）
     → 隧道 → http://localhost:47100（本机 LinkServer）
```

本机的 `LinkServer` 还是明文 `ws`，TLS 只在手机和 Cloudflare 之间；两端之间的内容本来就端到端加密，TLS 是外面再套一层。

实测结果：

| 走法 | 结果 |
| --- | --- |
| `wss://link.example.com:443/baocode-link` | ✅ 101 ← **用这个** |
| `ws://link.example.com:80/baocode-link` | ✅ 101（仅在 `always_use_https` 为 off 时） |
| `ws://<任何域名>:443/baocode-link` | ❌ Cloudflare 400，443 上不收明文 |

用 `wss://` 时，域名的 **Always Use HTTPS 开着关着都行**，不用为了 BaoCode 去改它。

> 旧版本手机只会用明文 `ws://`，只能走 80 端口，还要求 `always_use_https` 为 off。手机升级到新版后就不用管这些了。

## 2. 装好 MCP 并登录

Cloudflare 官方 MCP 服务器地址是 `https://mcp.cloudflare.com/mcp`，提供 `search()`、`execute()`、`docs()` 三个工具——`execute()` 能调 Cloudflare 全部 API，下面所有配置都靠它。

**在 Claude Code 里加：**

```bash
claude mcp add --transport http cloudflare-api https://mcp.cloudflare.com/mcp
```

**登录 / 授权**，二选一：

- **OAuth（推荐）**：在 Claude Code 里执行 `/mcp`，选 `cloudflare-api`，浏览器会弹出 Cloudflare 授权页，登录并勾选权限即可。第一次连接就会触发。
- **API Token（适合自动化）**：到 [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) 建一个 token，需要 **Account → Cloudflare Tunnel: Edit** 和 **Zone → DNS: Edit** 权限，用 `Authorization: Bearer <token>` 传入。

> **注意**：这一步**不需要** `cloudflared tunnel login`。下面用的是 token 方式（隧道自带凭据），不依赖 CLI 登录。

装好后确认一下能通，让 MCP 跑这段：

```js
async () => (await cloudflare.request({ method: 'GET', path: '/accounts' })).result
```

**看到你的账号名就说明登录成功了。**把返回里的账号 id 记下来，下面要用。

## 3. 用 MCP 配置隧道

下面每一步在 Claude Code 里直接说「用 cloudflare 的 execute 执行这段」即可。把 `ACCOUNT_ID`、`ZONE_ID`、`example.com` 换成你自己的。

**a. 查你有哪些域名**（拿到 `ZONE_ID`）：

```js
async () => (await cloudflare.request({ method: 'GET', path: '/zones' })).result
  .map(z => ({ name: z.name, id: z.id }))
```

顺便确认两件事：目标子域还没被占用、没有同名隧道。

**b. 建隧道**：

```js
async () => (await cloudflare.request({
  method: 'POST',
  path: `/accounts/${ACCOUNT_ID}/cfd_tunnel`,
  body: { name: 'baocode-link', config: { ingress: [] } },
})).result.id
```

把返回的隧道 id 记作 `TUNNEL_ID`。

**c. 取隧道 token**（这是凭据，别外传、别提交进 git）：

```js
async () => (await cloudflare.request({
  method: 'GET',
  path: `/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token`,
})).result
```

**d. 配置回源规则（ingress）**：

```js
async () => (await cloudflare.request({
  method: 'PUT',
  path: `/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations`,
  body: {
    config: {
      ingress: [
        { hostname: 'link.example.com', service: 'http://localhost:47100' },
        { service: 'http_status:404' },     // 兜底，必须有，少了会报错
      ],
    },
  },
})).success
```

> 创建隧道时（b 步）传的 `config` 对 token 型隧道**不生效**，必须像这里单独推一次。

**e. 加 DNS，把子域指到隧道**：

```js
async () => (await cloudflare.request({
  method: 'POST',
  path: `/zones/${ZONE_ID}/dns_records`,
  body: {
    type: 'CNAME',
    name: 'link',                                    // 即 link.example.com
    content: `${TUNNEL_ID}.cfargotunnel.com`,
    proxied: true,
  },
})).success
```

## 4. 在本机跑起来

> 需要先安装 `cloudflared`（macOS）：`brew install cloudflared`。

把 c 步拿到的 token 存成文件：

```bash
mkdir -p ~/.cloudflared && chmod 700 ~/.cloudflared
# 把 token 内容写进去
nano ~/.cloudflared/link-tunnel.token && chmod 600 ~/.cloudflared/link-tunnel.token
```

启动：

```bash
cloudflared tunnel --no-autoupdate run --token-file ~/.cloudflared/link-tunnel.token
```

日志里要看到这两行才算成功：

```
INF Registered tunnel connection connIndex=0 ...
INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"link.example.com\",...}]}"
```

**坑**：隧道进程**只在启动时拉一次**远程 ingress。如果你是先起了进程、后推的配置（d 步），日志会一直重复 `No ingress rules were defined`，请求回来是 503——**重启进程**就好。

## 5. 做成常驻服务（macOS）

先按 `Ctrl+C` 停掉前台进程，再用 launchd 托管，开机自启、挂了自动拉回。

`~/Library/LaunchAgents/dev.baocode.cftunnel-link.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.baocode.cftunnel-link</string>

	<key>ProgramArguments</key>
	<array>
		<string>/opt/homebrew/bin/cloudflared</string>
		<string>tunnel</string>
		<string>--no-autoupdate</string>
		<string>run</string>
		<string>--token-file</string>
		<string>/Users/你的用户名/.cloudflared/link-tunnel.token</string>
	</array>

	<key>RunAtLoad</key>
	<true/>

	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>

	<key>StandardOutPath</key>
	<string>/Users/你的用户名/Library/Logs/cftunnel-link.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/你的用户名/Library/Logs/cftunnel-link.log</string>

	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
```

**把两处 `/Users/你的用户名` 换成你的家目录路径**（`echo $HOME` 查看）。

```bash
# 装 / 更新
launchctl bootout gui/$(id -u)/dev.baocode.cftunnel-link 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.baocode.cftunnel-link.plist

# 看状态（应有 state = running 和一个 pid）
launchctl print gui/$(id -u)/dev.baocode.cftunnel-link | grep -E "state|pid"

# 停掉（保留配置，下次登录还会起）
launchctl bootout gui/$(id -u)/dev.baocode.cftunnel-link
```

> `brew services` 不行——它管的是 `~/.cloudflared/config.yml` 那套，和 token 方式对不上。

## 6. 填到手机里

桌面端 → 设置 → 手机 → **公网地址**，填：

```
wss://link.example.com
```

**必须带 `wss://`。**带上它端口默认就是 443；不带的话会被当成明文、端口当成本机的 47100（[`lib/link/link_host.dart`](../lib/link/link_host.dart) 的 `_parse`），连到 Cloudflare 的 47100 上，不通。写成 `https://link.example.com` 也一样。

填好之后，桌面端会把它（存成 `wss://link.example.com:443`）写进二维码的地址列表，手机连的时候就会走 `wss://link.example.com:443/baocode-link`。已经配对过的手机，也可以在手机端的设备页里手动加这个地址。

## 7. 排错

```bash
# 域名有没有回源到本机：两条都应返回 404 + 正文 "BaoCode"
curl -s https://link.example.com/
curl -s http://localhost:47100/

# WebSocket 升级（要看到 101 Switching Protocols）
curl -i --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://link.example.com/baocode-link
```

| 现象 | 原因 |
| --- | --- |
| 503 + 日志 `No ingress rules` | 进程没拉到配置，重启它（第 4 节末尾的坑） |
| 502 | ingress 生效了但回源失败：本机 47100 没在监听 |
| 手机连不上，公网地址没写 `wss://` | 被当成了明文 `ws` 连 47100，改成 `wss://link.example.com`（第 6 节） |
| `ws://…:443` 返回 400 | 正常，Cloudflare 在 443 上只收 TLS |
| 浏览器能打开但手机连不上 | 浏览器只说明隧道通了；看手机端设备页里的地址是不是 `wss://` 开头 |
| DNS 改了但解析没变 | 等几分钟；用 `dig link.example.com` 确认 |

## 8. 注意

- 走的是标准的 443 + WebSocket，Cloudflare 各套餐都支持。不过隧道适合个人使用；如果是要长期、规模化地给很多用户用，请改用 [`mobile-link.md`](./mobile-link.md) §5 里预留的中转方案（`RelayEndpoint`），也就是走 Cloudflare Workers 而不是隧道。
- 隧道是**绑定这台机器**的。换机器要重新装 token 和 plist。
- 隧道 token 是凭据，泄露了别人就能往你的隧道上挂服务。**别提交进 git**，别贴给别人。要作废就删掉隧道重新建一条。
- 根路径返回 404、正文是 `BaoCode` 是**正常的**：`LinkServer` 只处理 `/baocode-link` 的 WebSocket 升级，别的路径一律 404。
