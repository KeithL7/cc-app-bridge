# CC 本地 App 点击浏览插件 · cc-app-bridge

> 让 Claude Code（CC）像操作浏览器一样，操作你 Windows 上的**任意本地桌面应用**——
> 启动、聚焦、读取界面、点击、输入、按快捷键、截图。
>
> Let Claude Code drive **any local Windows desktop app** the way it drives a browser —
> launch, focus, read the UI, click, type, hotkeys, screenshot.

[English below ↓](#english)

---

## 这是什么

市面上的「AI 控制浏览器」桥（如 Kimi WebBridge）只能在浏览器里点网页。**cc-app-bridge 把同一套架构搬到了桌面**：

```
浏览器桥:  AI → daemon → 浏览器扩展 → 网页的无障碍树(DOM)
本插件:    AI → daemon → 常驻 PowerShell 引擎 → 桌面 App 的 UI Automation 树
```

核心洞察：**浏览器的无障碍树，在 Windows 桌面上的对应物就是 UI Automation（UIA）**。
所以"读页面 → 找元素 → 点击/输入"这套范式，可以一对一平移到任意桌面软件。

## 能干什么（示例）

只要软件把界面暴露给 Windows UIA（绝大多数原生 / Electron / Office / UWP 应用都会），就能自动化：

- 🎮 **游戏收菜**：识别按钮、定点点击、循环操作（无 UIA 树的纯画面游戏走「截图 + 坐标点击」兜底）
- 💬 **微信回复**：读取聊天列表、定位输入框、填入文字、发送
- 📱 **抖音/短视频评论操作**：在桌面端打开、定位评论框、输入、提交
- 📄 **办公自动化**：填表单、点菜单、批量处理、导出
- 🖼️ **看一眼再决策**：截窗口图给 AI，让它根据画面继续操作

> ⚠️ **合规使用**：本工具是通用 UI 自动化框架（同类如 AutoHotkey / pywinauto）。请**只在你自己的账号、自己的设备**上用于个人效率自动化；自动化可能违反某些平台（游戏、社交、短视频）的服务条款，**请勿用于刷量、群发、垃圾评论或任何滥用行为**，后果自负。

## 架构

```
AI (HTTP) ──> daemon.mjs (127.0.0.1:10087) ──NDJSON over stdio──> worker.ps1 (UIA 引擎) ──> 桌面 App
                                                                   worker.ps1 ──spawns──> capture.ps1 (截图)
```

- **daemon.mjs**：Node 写的本地 HTTP 桥，`/status` + `/command`，请求体 `{action,args,session}`。
- **worker.ps1**：常驻 PowerShell 7 进程，加载 .NET UI Automation，负责读树/点击/输入/按键。
- **capture.ps1**：独立的一次性截图子进程（截图能力单独隔离，最小权限）。

## 安装

需要 **Node 24+** 和 **PowerShell 7（pwsh）**（Win10/11 自带或一键装）。

```powershell
git clone https://github.com/<your-name>/cc-app-bridge.git
cd cc-app-bridge
pwsh -File install.ps1
```

`install.ps1` 会把运行时装到 `~/.appbridge/`、技能文档装到 `~/.claude/skills/appbridge/`，并启动 daemon。
之后在 Claude Code 里直接说「帮我操作 XX 软件」即可触发该技能。

## 用法（10 个动作）

健康检查：

```bash
node "$HOME/.appbridge/bin/appbridge.mjs" status
# {"running":true,"worker_connected":true,...}
```

驱动桌面（任意 HTTP 客户端）：

```bash
curl -s -X POST http://127.0.0.1:10087/command \
  -H 'Content-Type: application/json' \
  -d '{"action":"list_windows","args":{}}'
```

| 动作 | 作用 |
|------|------|
| `launch` | 启动 App（之后用 `find_window` 绑定窗口） |
| `list_windows` | 列出所有顶层窗口（带 `@w` 引用） |
| `find_window` | 按标题绑定目标窗口到会话 |
| `focus` | 把窗口切到前台 |
| `snapshot` | 读 UIA 树，得到带 `@e` 引用的可交互元素 |
| `click` | UIA Invoke 优先，`x,y` 坐标点击兜底 |
| `fill` | 填文字（ValuePattern → 剪贴板粘贴兜底，支持中文） |
| `key` | 发快捷键（SendKeys 语法：`{ENTER}`、`^s`…） |
| `screenshot` | 截窗口/元素/全屏，返回文件路径 |
| `close_window` | 关闭窗口 |

**惯用法**：`launch` → `find_window` 绑窗口 → `snapshot` 拿 `@e` 引用 → `click`/`fill`/`key` → `screenshot` 验证。

详见 [`skill/SKILL.md`](skill/SKILL.md) 与 [`skill/references/operations.md`](skill/references/operations.md)。

## 已知边界

- **仅 Windows**（引擎是 Win UIA；macOS/Linux 需另写后端）。
- **没有 UIA 树的程序**（部分游戏、纯 canvas/GPU 应用）只能走截图 + 坐标点击。
- **管理员权限的 App**：普通权限的引擎无法向其发送输入（Windows UIPI 限制），需以管理员身份运行 daemon。
- **个别强校验"可信输入"的程序**可能忽略合成的点击/按键。
- 本工具**不含**任意代码执行口子（刻意不做 `eval`），降低风险面。

## License

MIT © 2026 Keith Liao

---

<a name="english"></a>

## English

**cc-app-bridge** is a Claude Code skill that lets AI control **any local Windows desktop app** via
Windows UI Automation (UIA) — the desktop counterpart of a browser-automation bridge. Where a browser
bridge reads the DOM accessibility tree, this reads the UIA tree, so the same
"read → find element → click/type" loop works on native, Electron, Office, and UWP apps.

### What it can do (examples)

Any app that exposes its UI to Windows UIA can be automated:

- 🎮 **Game chores / harvesting** — find buttons, click, loop (pure-canvas games fall back to screenshot + coordinate clicks)
- 💬 **Messaging replies** (e.g. WeChat) — read the chat, locate the input box, type, send
- 📱 **Short-video comment actions** (e.g. Douyin/TikTok desktop) — open, locate the comment box, type, submit
- 📄 **Office automation** — fill forms, click menus, batch process, export
- 🖼️ **Look-then-act** — screenshot a window so the AI can decide the next step from pixels

> ⚠️ **Responsible use**: This is a general-purpose UI-automation framework (like AutoHotkey or
> pywinauto). Use it **only on your own accounts and your own machine** for personal productivity.
> Automation may violate the Terms of Service of some platforms (games, social, short-video). **Do not
> use it for spam, mass posting, bot comments, or any abuse.** You are responsible for how you use it.

### Architecture

```
AI (HTTP) ──> daemon.mjs (127.0.0.1:10087) ──NDJSON over stdio──> worker.ps1 (UIA engine) ──> desktop apps
                                                                   worker.ps1 ──spawns──> capture.ps1 (screenshot)
```

A Node HTTP bridge (`/status`, `/command`) in front of an always-on PowerShell 7 process that drives
.NET UI Automation. Screenshots are taken by an isolated one-shot helper (`capture.ps1`).

### Install

Requires **Node 24+** and **PowerShell 7 (pwsh)**.

```powershell
git clone https://github.com/<your-name>/cc-app-bridge.git
cd cc-app-bridge
pwsh -File install.ps1
```

Installs the runtime to `~/.appbridge/` and the skill to `~/.claude/skills/appbridge/`, then starts the
daemon. Health check: `node "$HOME/.appbridge/bin/appbridge.mjs" status`.

### Actions

`launch · list_windows · find_window · focus · snapshot · click · fill · key · screenshot · close_window`

Typical loop: `launch` → `find_window` (bind a window) → `snapshot` (get `@e` element refs) →
`click`/`fill`/`key` → `screenshot` to verify. Full reference in
[`skill/SKILL.md`](skill/SKILL.md).

### Limitations

Windows-only (Win UIA); no-UIA apps need screenshot + coordinate clicks; can't drive elevated/admin
windows from a non-elevated worker; no arbitrary-code-execution surface (no `eval`, by design).

### License

MIT © 2026 Keith Liao
