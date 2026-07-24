# ChatGPT Notice

> 中文名：**喵了个咪的赶紧干活**

一个只在本机运行的 macOS 菜单栏工具，用来判断 ChatGPT/Codex 任务究竟是在工作、等待、重试，还是已经很久没有新进展。

菜单栏平时只显示：

```text
状态：秒数
```

例如 `推理：210`。每出现一个新的有效状态，秒数就会归零；最大显示 `9999`。鼠标悬停在菜单栏文字上时，会显示全部尚未完成的任务。

## 功能

- 监控所有尚未完成的 ChatGPT/Codex 任务。
- 菜单栏显示最近活跃任务。
- 悬停时显示全部未完成任务，不弹出下拉菜单。
- 所有任务完成后显示 `没有任务：0`。
- ChatGPT 完全退出约 3 秒后自动退出。
- 新会话开始时通过 Codex `SessionStart` Hook 自动启动。
- 多个任务同时运行时只启动一个菜单栏实例。

## 自动启动范围

当前版本只有 **Codex 任务启动**会触发插件的 `SessionStart` Hook，普通 ChatGPT 对话不会触发。

- 只打开普通 ChatGPT 对话：菜单栏程序不会自动出现。
- 开始一次 Codex 任务：菜单栏程序自动出现，并持续运行到 ChatGPT 退出。
- 程序运行期间：仍会尝试监控普通 ChatGPT 对话产生的桌面日志。

因此，重启 ChatGPT 后如果只使用普通对话，暂时看不到菜单栏状态属于当前版本的预期行为，不代表插件安装失败。

目前归并后的状态包括：

| 状态 | 含义 |
| --- | --- |
| 推理 | 模型正在思考或生成推理内容 |
| 执行 | 正在运行本机命令或工具 |
| Git | 正在进行 Git/GitHub 相关操作 |
| 网络 | 正在访问网络服务 |
| 回复 | 正在生成或输出回复 |
| 等待确认 | 等待用户授权或输入 |
| 网络重试 | 网络失败后正在重连或重试 |

## 系统要求

- Apple Silicon Mac
- macOS 13 或更高版本
- 当前版 ChatGPT 桌面应用（包含 Codex）

当前仓库内附带的是本机临时签名的 ARM64 菜单栏程序。Intel Mac 暂未提供预编译版本，但可以修改构建参数自行编译。

## 安装

在“终端”中依次运行：

```bash
/Applications/ChatGPT.app/Contents/Resources/codex plugin marketplace add https://github.com/luckylhf/ChatGPT_Notice.git
/Applications/ChatGPT.app/Contents/Resources/codex plugin add miao-le-ge-mi-status@chatgpt-notice
```

然后在 ChatGPT/Codex 中新建一个任务。第一次运行 Hook 时，请确认信任该插件。

看到菜单栏出现 `状态：秒数` 或 `没有任务：0` 即表示启动成功。

## 卸载

```bash
/Applications/ChatGPT.app/Contents/Resources/codex plugin remove miao-le-ge-mi-status
/Applications/ChatGPT.app/Contents/Resources/codex plugin marketplace remove chatgpt-notice
```

如果菜单栏程序仍在运行，退出 ChatGPT 后它会在约 3 秒内自行退出。

## 隐私

程序只读分析以下本机文件：

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/session_index.jsonl`
- `~/Library/Logs/com.openai.codex/**/*.log`

它不会读取或展示提示词正文、回复正文或工具输出正文，也不会主动发送网络请求。状态判断只使用事件类型、工具名称、错误标记和时间戳。

## 工作原理

每个任务保存最近一次识别到的状态和时间戳。新状态到来时立即替换状态并把计时器归零；同一状态的新事件也会重置计时器。菜单栏选择时间戳最新且尚未完成的任务展示。

日志格式属于 ChatGPT/Codex 的内部实现。未来桌面应用如果修改日志结构，部分状态可能需要更新匹配规则。

## 从源码构建

需要安装 Xcode Command Line Tools：

```bash
cd plugins/miao-le-ge-mi-status
./scripts/build-app.sh
```

构建脚本会：

1. 编译并运行状态解析测试。
2. 编译原生 AppKit 菜单栏程序。
3. 对 `.app` 进行本机临时签名。
4. 校验应用的 `Info.plist`。

构建结果位于：

```text
plugins/miao-le-ge-mi-status/assets/喵了个咪的赶紧干活.app
```

## 项目结构

```text
.agents/plugins/marketplace.json        Codex 市场清单
plugins/miao-le-ge-mi-status/
├── .codex-plugin/plugin.json           插件清单
├── Sources/                             Objective-C 源码
├── Tests/                               状态解析测试
├── assets/                              菜单栏应用
├── hooks/hooks.json                     SessionStart Hook
└── scripts/                             构建与启动脚本
```

## 参与修改

欢迎直接 Fork、修改和重新发布。提交改动前请运行：

```bash
cd plugins/miao-le-ge-mi-status
./scripts/build-app.sh
```

## 许可证

[0BSD](LICENSE)——可以自由使用、复制、修改和分发。
