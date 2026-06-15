---
name: appbridge
description: |
  AppBridge lets AI control the user's real Windows desktop apps — launch, focus, read the UI tree, click, type, screenshot, and interact with any application using Windows UI Automation. Use this skill whenever the user wants to automate a desktop program, drive a native/Electron/Office/UWP app, read what is on screen, click buttons, fill fields, or take a window screenshot. The desktop counterpart of a browser bridge: the browser's accessibility tree maps to Windows UIA. Use even for simple-sounding requests — the daemon handles the complexity.
---

# AppBridge

Control the user's real Windows desktop apps via a local daemon at `http://127.0.0.1:10087`.
The daemon owns a persistent PowerShell **UI Automation (UIA)** engine — the desktop equivalent
of a browser's accessibility tree.

## Health check (always do this first)

```bash
node "$HOME/.appbridge/bin/appbridge.mjs" status
```

Then act on the result:

- **`running: true` and `worker_connected: true`** — healthy. Proceed with the tool calls below.
- **Anything else** (`running: false`, `worker_connected: false`, no output, errors) — **Read `references/operations.md`** in this skill directory. It has the start / diagnose routing table.

## Tools

POST to `http://127.0.0.1:10087/command` with `{action, args, session}`.

| Tool | Args | Returns | Note |
|------|------|---------|------|
| `launch` | `path` (exe / app name / uri), `args`, `waitMs` | `{launched, pid, window}` | Start an app. **Then call `find_window` to bind the target** — the launched pid often isn't the window's pid (UWP/packaged apps) |
| `list_windows` | — | `{windows:[{ref,title,class,pid,handle,bounds,foreground}]}` | Enumerate top-level windows; refs are `@wN` |
| `find_window` | `title` (substring, case-insensitive) | `{matched, window, all}` | **Binds the session** to the first match. Use after `launch`, or to grab an already-open window |
| `focus` | `window`(@w) / `title` / `handle`, or session target | `{focused, window}` | Bring a window to the foreground (needed before `key` and coordinate clicks) |
| `snapshot` | optional target (`window`@w / `title` / `handle`), `maxNodes`(400), `maxDepth`(40), `includeOffscreen`(false) | `{title, class, pid, nodes, truncated, tree}` | **UIA tree** (text) with `@e` refs — use this to read the app and locate elements |
| `click` | `selector` (`@e`/`@w` ref) **or** `x`,`y`; `button`(left\|right) | `{clicked, via}` | Tries UIA Invoke/Toggle/Select/Expand; falls back to a real pointer click at the element center. `x,y` does a raw screen-coordinate click |
| `fill` | `selector` (`@e`), `value` | `{filled, mode}` | Sets text. `mode` is `"value"` (UIA ValuePattern) or `"clipboard-paste"` (focus + select-all + paste, for rich editors) |
| `paste` | `text`, optional `selector` | `{pasted, chars}` | Types Unicode text (incl. Chinese) at the **current keyboard focus** via clipboard + Ctrl+V. Use for apps with no usable `@e` ref (weak-UIA apps): coordinate-`click` the field first to focus it, then `paste`. **Verify the right window is foreground first** (`list_windows` → `foreground`) so keys don't land elsewhere |
| `key` | `keys` (SendKeys syntax), optional `selector` | `{sent, keys}` | Focuses the target, then sends keystrokes. e.g. `{ENTER}`, `^s` (Ctrl+S), `hi{TAB}there`, `%{F4}` (Alt+F4) |
| `screenshot` | optional target / `selector`(@e crop) / `region:"screen"`; `format`(png\|jpeg), `quality`, `path`, `raise`(true) | `{path, format, width, height, sizeBytes, mimeType}` | Daemon writes the file and returns its path; open it via the `Read` tool |
| `close_window` | `window`(@w) / `title` / `handle`, or session target | `{closed, via}` | Closes via UIA WindowPattern or WM_CLOSE |

### Call format

```bash
curl -s -X POST http://127.0.0.1:10087/command \
  -H 'Content-Type: application/json' \
  -d '{"action":"list_windows","args":{}}'
```

Every response is `{"success":true,"data":{...}}` or `{"success":false,"error":"..."}`.

### Sending non-ASCII (Chinese) args

A shell can mangle UTF-8 inside `curl -d`. When an arg contains non-ASCII (a Chinese `value` to
`fill`, or a Chinese window `title`), **write the JSON body to a file** and use `--data-binary`:

```bash
# write body.json with the Write tool (UTF-8), then:
curl -s -X POST http://127.0.0.1:10087/command \
  -H 'Content-Type: application/json' --data-binary @/tmp/body.json
```

ASCII-only bodies are fine inline.

## The core loop

1. **`launch`** the app (or skip if it's already open).
2. **`find_window`** with a title substring to bind the session to the right window. Don't rely on "whatever's in front" — the foreground can be anything.
3. **`snapshot`** to read the UIA tree and get `@e` refs.
4. **`click` / `fill` / `key`** using the `@e` refs from that snapshot.
5. **`screenshot`** + `Read` the returned path to visually confirm.

```bash
# bind an already-open app and read it
curl -s -X POST http://127.0.0.1:10087/command \
  -d '{"action":"find_window","args":{"title":"Notepad"},"session":"np"}'
curl -s -X POST http://127.0.0.1:10087/command \
  -d '{"action":"snapshot","args":{},"session":"np"}'
```

## Sessions

A session maps to **a bound target window**. Use distinct session names for distinct apps so they
don't fight over which window is "current":

```bash
-d '{"action":"snapshot","args":{},"session":"excel"}'
```

> `@e` refs come from the **most recent snapshot** (a single global registry). If you snapshot app A,
> then snapshot app B, then act on A's old `@e` refs, they'll be wrong. Re-snapshot a window right
> before acting on its elements.

## Prefer snapshot `@e` refs over coordinates

`snapshot` returns interactive elements with `@e` refs based on UIA role/name. Use them directly with
`click`/`fill` — they survive layout/position changes that break raw `x,y` clicks. Fall back to
coordinate clicks (`x,y`) only when the app exposes **no** UIA tree (some games, pure-canvas/GPU apps)
— in that case `screenshot` + read the pixels, then `click` with `x,y`.

## Screenshots: read the returned path

The daemon writes the image to disk and returns `{path, ...}`. Read the `.data.path` and open it via
the `Read` tool — the model can't interpret raw base64, so the file-path indirection is what makes the
screenshot viewable.

```bash
# whole screen
-d '{"action":"screenshot","args":{"region":"screen"}}'
# the bound window (raises it first; pass "raise":false to capture in place)
-d '{"action":"screenshot","args":{},"session":"excel"}'
# just one element, cropped to its bounds
-d '{"action":"screenshot","args":{"selector":"@e42"}}'
# caller-supplied path (overwrites)
-d '{"action":"screenshot","args":{"path":"C:/Users/me/Desktop/state.png"}}'
```

## Text input — use `fill`

`fill` is clear-and-insert: existing content is replaced. It tries UIA ValuePattern first
(`mode:"value"`); for rich/contenteditable controls with no settable value it focuses, selects all,
and pastes via the clipboard (`mode:"clipboard-paste"`). To append, read the current value from the
snapshot, concatenate, and `fill` the whole thing.

## Keys / shortcuts — use `key`

There's no separate "press Enter". Use `key` with SendKeys syntax: `{ENTER}`, `{ESC}`, `{TAB}`,
`{F5}`, `^s` (Ctrl+S), `^c`, `%{F4}` (Alt+F4), `+{TAB}` (Shift+Tab). `key` focuses the bound window
first. To submit a form you can also just `click` the submit button's `@e` ref.

## Known limitations

- **No / weak UIA tree** — games, emulators, pure-canvas/GPU apps, and some Qt/Electron apps (e.g. **WeChat**) expose little or nothing to `snapshot` (it returns ~1 node). Drive these by **screenshot → `Read` → coordinate `click` → `paste` → screenshot-verify**: click a field by `x,y` to focus it, confirm the app is `foreground` via `list_windows`, `paste` the text, screenshot to confirm it landed and was **not** sent, then `key {ENTER}`. Verify at each step so a mis-aimed click is recoverable.
- **Elevated (admin) apps** — a normal-privilege worker cannot send input to windows running as Administrator (Windows UIPI blocks it). The user would need to run the daemon elevated to drive those.
- **Synthetic input** — `click`/`fill`/`key` are synthetic. A few apps that hard-check trusted input may ignore them. This is a platform boundary.
- **Occlusion** — window `screenshot` raises the target first (so it isn't covered). Pass `raise:false` to capture exactly as-is.
- **Windows only** — this engine is Windows UIA. macOS (AX) / Linux (AT-SPI) would need a different worker.

## Version

```bash
node "$HOME/.appbridge/bin/appbridge.mjs" status   # -> {"version":"...","worker_connected":...}
```
