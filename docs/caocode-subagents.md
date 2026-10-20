# 查看与切换 Codex 子代理

主代理派出子代理后，点击对话中的代理卡片，或使用对话顶部的 **子代理** 按钮。
列表将运行中的代理排在前面，已完成和已停止的代理仍可打开。
进入后可查看任务、思考摘要、工具执行和回复；顶部返回按钮、面包屑或 Esc 返回上层。
切换列表也可以直接打开另一个代理，嵌套代理按层级显示。

切换查看不停止主代理，不向子代理发送消息，不更改模型或权限。
主对话的滚动位置和未发送草稿保留。子代理中的任务消息只读，避免把编辑、重试或目标操作
误发到主代理。需要调整任务时，返回主对话向主代理说明。

子线程的审批和问题显示代理名称，可在主对话及当前子代理详情中回答；回答仍发送给
发出请求的线程。主代理完成不会清除尚未处理的子线程审批。

打开子代理时按需加载最近 30 个回合，有更早记录时提供 **加载更早消息**。
收到的子线程通知立即显示；查看运行中的子线程时，每 2 秒补读持久化历史，
兼容未转发全部子线程消息的 CLI。返回主对话或关闭页面即停止补读。
读取失败会保留已收到内容，点击 **重试** 恢复。已完成线程可手动刷新。
重新打开主会话时，从其派出记录恢复代理卡片，打开卡片后再读取相应子线程。

## 设计依据

- BaoCode：固定参考仓库的 `lib/chat/agent_view.dart`、`chat_feed.dart` 和 `chat_screen.dart`。
  沿用层叠对话、只读详情、面包屑及 Esc 返回，底层主对话保留其状态。
- Codex for VS Code：本机 `openai.chatgpt-26.1007.21434` 扩展的
  `local-conversation-subagents-panel-tab`、`subagent-panel` 及线程恢复逻辑。
  采用稳定线程标识、运行状态排序、独立详情、按需读取和明确的错误恢复。
- [OpenAI 子代理说明](https://learn.chatgpt.com/docs/agent-configuration/subagents)及
  [App Server 协议](https://learn.chatgpt.com/docs/app-server)。

Caocode 通过 `subAgentActivity`、`collabAgentToolCall` 的接收线程 ID
和 `thread/started` 的派生来源建立树，兼容当前及较早的 CLI 协议。
以线程 ID 定位卡片。工具调用完成与代理完成分别处理；`wait`、后续指令和状态更新
更新原代理卡片。子线程数据独立投影，父、子及同级的相同 item ID 不会互相覆盖。
读取使用 `thread/read` 和 `thread/turns/list`，分页不可用的旧 CLI 才使用完整读取。
查看不会调用子线程的 `thread/resume` 或 `turn/start`，从而保留主代理对任务的执行控制。

实现入口为 `lib/kernel/codex/codex_subagents.dart`、`lib/chat/subagent_switcher.dart`
以及已有的子代理对话层；测试覆盖协议隔离、审批、历史分页、恢复、竞态、切换和草稿保留。
