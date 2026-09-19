# PROBLEM_STATE

## 当前问题

菜单栏把侧边聊天派生的临时线程显示为独立 `ChatGPT 会话 01a…`，并可能错误显示全局 `网络重试`。用户已选择把侧边聊天活动归并到主任务。

## 成功标准

- 确认截图中的两个短 ID 对应什么类型的任务。
- 判断 `网络重试` 是否代表该任务真实发生网络错误。
- 找到任务错误命名、错误归属和完成后残留的具体代码路径。

## 已确认事实

- 截图中的 `01a0b985…` 和 `01a0b8fb…` 都由 Codex 的 `Reasoning summary turn-start config resolved` 和 `turn/start` 事件创建，不是普通 ChatGPT 的 `/c/<conversation-id>` 会话。
- 应用读取 `01a0b985…` 时明确返回 `ephemeral threads do not support thread/turns/list`，说明它是临时线程；`01a0b8fb…` 已无法作为正常 Codex 任务读取。
- `01a0b985…` 创建前，应用从主任务 `01a09a16…` 执行 `thread/fork`，随后对新线程执行 `thread/inject_items`；`01a0b8fb…` 也同样由主任务 `01a0b6fb…` 经 `thread/fork` 和 `thread/inject_items` 创建。这与侧边聊天从当前任务派生临时对话窗口的链路一致。
- 两个线程都没有对应的本地会话 JSONL，因此不能通过现有 `task_complete` 路径清理；桌面日志中也没有带这两个线程 ID 的可靠完成事件，只记录了视图变为不活跃。
- 桌面日志解析器会给所有这类信号加 `chat:` 前缀，缺少标题时因此回退显示为 `ChatGPT 会话 <短ID>`，实际类型标签错误。
- `chatgpt_pubsub_reconnect_scheduled` 是 ChatGPT 客户端的全局消息连接重连事件，本身不带任务 ID。解析器仍生成一个无 ID 的“网络重试”信号。
- 状态仓库收到无 ID 的活动信号后，会把它应用到最近活跃任务。因此截图中的 `网络重试：2912` 是全局重连事件被错误挂到 `01a0b8fb…`，不证明该任务发生了网络错误。

## 未知项

- 仍需用户用一次真实侧边聊天操作确认菜单栏视觉行为符合预期。

## 已作决定

- 不把全局 `chatgpt_pubsub_reconnect_scheduled` 归属给任何具体任务。
- `thread_stream_view_activity_changed active=false` 仍不能直接当作任务完成，因为它也可能只是用户切换了页面。
- 用户选择方案 3：侧边聊天不单独占一行，其活动更新主任务状态。

## 当前结论

已增加回归测试并完成最小修复：通过相邻的 `thread/fork` 与 `thread/inject_items` 建立侧边聊天子线程到主任务的映射；子线程开始和活动更新主任务，`IAB_LIFECYCLE ended browser use session activity` 只结束该子线程来源，不误删同时运行的主任务；无任务 ID 的全局重连事件不再生成任务状态。构建测试、真实桌面日志回放和插件校验均通过。仓库、个人市场源和安装缓存的关键文件哈希一致；实际运行进程已切换到 `0.1.0+codex.20260919124304`。

## 下一步唯一动作

用户用一次真实侧边聊天操作进行菜单栏视觉验收。
