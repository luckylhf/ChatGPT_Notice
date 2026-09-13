# PROBLEM_STATE

## 当前问题

菜单栏会把同一个 Codex 任务显示两次，并保留已经完成的旧任务；旧任务计时最终显示为 `9999`。

## 成功标准

- 同一个 Codex 线程只显示一条状态。
- 已完成或已停止活跃的任务会从菜单中移除。
- 状态标题使用 `session_index.jsonl` 中的真实线程标题，不回退为错误的 rollout ID。

## 已确认事实

- 当前会话文件名同时包含线程 ID `01a098cc…` 和 rollout ID `01a098d0…`。
- 会话文件的 `session_meta.payload.id` 与 `session_id` 均为线程 ID `01a098cc…`。
- `sessionIDFromPath:` 从文件名末尾提取 UUID，误取 rollout ID `01a098d0…`。
- 桌面日志使用线程 ID `01a098cc…`，因此同一任务以两个不同 ID 进入状态仓库，形成一条真实标题和一条 `Codex 任务 01a098d0`。
- “制定工具链效费比量化方法”的会话文件最后记录为 `task_complete`，任务实际已经结束。
- 桌面日志对该线程记录了 `thread_stream_view_activity_changed active=false`，但当前桌面日志解析器不把它识别为完成信号，所以桌面日志创建的任务副本没有移除。
- `MLGMElapsedSeconds` 会把超过 9999 秒的间隔固定显示为 `9999`；这不是仍在运行的时长证明。
- 回归测试在旧实现下因缺少元数据 ID 解析而失败，修复后完整构建测试通过。
- 修复后的会话游标使用 JSONL 首行 `session_meta.session_id`，与桌面日志和 `session_index.jsonl` 的线程 ID 一致。
- 修复版已安装为 `0.1.0+codex.20260913081249`，仓库、个人 marketplace 源和安装缓存的变更文件哈希一致。
- 当前菜单栏进程 PID 95993 从修复版缓存启动，旧版缓存进程已退出。
- 用户已查看修复后的菜单栏并确认结果正常。

## 未知项

- 无影响当前实施的未知项。
- `thread_stream_view_activity_changed active=false` 可能只表示视图失活，本次不把它当成任务完成。

## 已作决定

- 上一阶段只诊断原因；用户现已确认进入修复。
- 若进入修复，先添加可复现“重复任务”和“完成任务残留”的失败测试，再做最小修改。
- 已选择统一使用会话 JSONL 首行 `session_meta.session_id` 的线程 ID；不再从文件名末尾提取 rollout ID。
- 不新增桌面日志结束规则；统一 ID 后复用现有去重和 `task_complete` 清理逻辑。

## 当前结论

截图由会话文件 ID 取错造成：错误的 rollout ID 既产生重复项，也使 `task_complete` 无法删除桌面线程副本。源码已改为使用 `session_meta.session_id`，自动化测试、插件结构、签名校验和用户实际显示验收均通过，实际运行进程已切换到修复版。

## 下一步唯一动作

提交当前修复并推送到 `git@github.com:luckylhf/ChatGPT_Notice.git` 的 `main`。
