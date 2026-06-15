# Operations: start, lifecycle, diagnose

Read this when the health check in SKILL.md shows the daemon missing, not running, or the worker not
connected — or when the user asks to start, stop, restart, or troubleshoot appbridge.

## Path convention

Everything lives under `~/.appbridge/`:

- `bin/appbridge.mjs` — lifecycle CLI (run with `node`)
- `daemon/daemon.mjs` — HTTP bridge on `127.0.0.1:10087`
- `daemon/worker.ps1` — persistent PowerShell UIA engine (window/read/click/type/keys)
- `daemon/capture.ps1` — one-shot screen-grab helper, invoked by the worker only for `screenshot`
- `logs/daemon.log` — daemon + worker logs
- `appbridge.pid` — daemon pid

The CLI is plain Node (Node 24 present): `node "$HOME/.appbridge/bin/appbridge.mjs" <cmd>`.

## Routing table (what to do based on status)

Run: `node "$HOME/.appbridge/bin/appbridge.mjs" status`

| Observed | Action |
|---|---|
| `{"running": false}` or no output | Daemon not running. Run: `node "$HOME/.appbridge/bin/appbridge.mjs" start` |
| `{"running": true, "worker_connected": false, ...}` | Daemon up but UIA engine not attached. Wait ~2s and re-check; if still false, `node "$HOME/.appbridge/bin/appbridge.mjs" logs -n 60`. |
| `{"running": true, "worker_connected": true, ...}` | Healthy. Return to SKILL.md and make tool calls. |
| `node: command not found` | Node missing from PATH — appbridge requires Node. |

## /status fields

- `running` (bool) — daemon listening on `:10087`
- `port` (int) — 10087
- `version` (string)
- `worker_connected` (bool) — the PowerShell UIA engine is attached and ready
- `worker_pid`, `pid` (int) — worker and daemon process ids
- `uptime_seconds` (int)

## Daily operations

- **Status:** `node "$HOME/.appbridge/bin/appbridge.mjs" status`
- **Start:** `node "$HOME/.appbridge/bin/appbridge.mjs" start` (idempotent; waits until the worker is ready)
- **Stop:** `node "$HOME/.appbridge/bin/appbridge.mjs" stop` (kills the daemon tree + any orphaned worker)
- **Restart:** `node "$HOME/.appbridge/bin/appbridge.mjs" restart` (needed after editing `worker.ps1`)
- **Logs:** `node "$HOME/.appbridge/bin/appbridge.mjs" logs -n 100`

## Diagnosing common failures

| Symptom | Action |
|---|---|
| `start` says port in use | Another daemon is already running — that's fine. Or `stop` then `start`. |
| `worker_connected` stays `false` | `logs -n 60`. If the log shows the worker script was quarantined/blocked by antivirus, the user must allow `~/.appbridge/` in their AV (a Microsoft Defender folder exclusion). See note below. |
| Tool calls time out | `logs -n 100` for `[error]`/worker stack traces. The worker auto-respawns on crash (up to 5 fast failures, then it stops to avoid a crash loop). |
| Snapshot is empty / tiny | The app exposes no UIA tree (game / canvas). Use `screenshot` + coordinate `click`. |
| Input does nothing on an admin app | The target runs elevated; a normal worker can't drive it (UIPI). Run the daemon elevated. |

## Antivirus note

This is a legitimate UI-automation tool, but some endpoint antivirus uses heuristics that can
false-positive on automation scripts (input simulation, screen capture). If `worker_connected` stays
`false` and the logs show the script was blocked, the supported fix is for the **user** to allow-list
the `~/.appbridge/` folder in their antivirus (e.g. a Microsoft Defender exclusion). That is a
security decision the user makes deliberately — surface it to them; don't work around AV silently.

The codebase keeps `screenshot`'s screen-grab in its own small `capture.ps1` rather than inside the
main engine — straightforward least-privilege modularity (the core read/click/type engine carries no
screen-capture capability of its own).

## Architecture (for reference)

```
AI (HTTP) --> daemon.mjs (:10087) --NDJSON over stdio--> worker.ps1 (UIA engine) --> desktop apps
                                                          worker.ps1 --spawns--> capture.ps1 (screen grab)
```

This mirrors a browser bridge's "daemon + always-on agent" topology; here the always-on agent is a
PowerShell process driving Windows UI Automation instead of a browser extension driving the DOM.
