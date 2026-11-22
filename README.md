# Periscope

MCP server that gives an AI assistant (Claude, GitHub Copilot, or any MCP client) screen
capture and input control on a Windows machine: screenshots, mouse move/click, keyboard
input, window enumeration/focus, and clipboard read/write.

## How it works

It's a [Model Context Protocol](https://modelcontextprotocol.io) server, split into two parts:

- **`python/host.py`** — a persistent background process you start once (by double-clicking a
  desktop icon, run with `pythonw.exe`). It hosts a named pipe server, a localhost web
  dashboard, a system tray icon, and a clickable idle avatar, and performs every actual
  screen/mouse/keyboard/window/clipboard action in-process.
- **`src/index.ts`** (the MCP server, `dist/index.js`) — a thin Node client. Each tool call
  opens a connection to the host's named pipe (`\\.\pipe\PeriscopeActionPipe`), sends a JSON
  request, and reads back a JSON response. It spawns no processes and owns no GUI itself.

This two-process design exists so an MCP tool call is fast and lightweight: a local IPC
round-trip (tens of milliseconds) instead of spawning a fresh process per action. The engine
runs on **`pythonw.exe`**, the windowless variant of the Python interpreter — no console window
is ever created, not hidden after the fact, just never created in the first place. (An earlier
version of this project used PowerShell with a hide-the-console-after-creation workaround; that
approach turned out to be fragile in ways `pythonw.exe` structurally avoids — see "Why Python,
not PowerShell" below.) If `host.py` isn't running, tool calls fail fast with a clear message
telling you to start it, rather than silently doing nothing or auto-spawning background
processes on your behalf.

Mouse/keyboard/window control uses `ctypes` calls directly into `user32.dll`/`kernel32.dll`
(via `pywin32` for the higher-level window/clipboard APIs) and `PIL.ImageGrab` for screenshots —
all mature, prebuilt-wheel Windows packages, so there's no native-module compile step and no
Node-addon ABI fragility either.

### Why Python, not PowerShell

The original implementation used PowerShell + .NET WinForms. Two real problems came up in
practice:

1. **Console visibility.** PowerShell has no equivalent of `pythonw.exe` — every process has a
   console host, and hiding it is a workaround applied after the fact (`-WindowStyle Hidden`,
   which was found to also suppress GUI windows created later in the same process; a Minimized
   shortcut, which was found to make windows open minimized instead of just the console).
   `pythonw.exe` never creates a console in the first place, which eliminates this whole class
   of bug rather than patching around it.
2. **WinForms event-handler closures.** PowerShell event handlers (`Timer.Add_Tick`,
   `Button.Add_Click`) defined inside a function don't reliably see that function's local
   variables when invoked later by the event loop, unless explicitly bound with
   `.GetNewClosure()` — an easy thing to miss once, which is exactly what caused a real crash
   during development (see git history). Python closures don't have this failure mode.

## Getting started

```sh
npm install
npm run build
pip install -r python/requirements.txt
npm run install-shortcut
```

This builds `dist/index.js`, installs the Python dependencies (`pywin32`, `pystray`, `Pillow` —
all prebuilt wheels, no compilation), and creates a **Periscope** shortcut on your Desktop.
Requires Python 3.10+ on PATH.

1. **Double-click the Periscope desktop icon.** This starts `host.py` in the background with
   `pythonw.exe` (genuinely no console window — see above) and shows a small idle robot avatar
   on your screen — that's your confirmation it's running. A Periscope icon also appears in the
   system tray (bottom-right of the taskbar).
2. **Click the robot.** It opens a picker: launch Claude Desktop (configured automatically to
   use Periscope) or open claude.ai in a browser. The robot then hides, and only reappears
   briefly during actual actions from here on.
3. **Prompt Claude/Copilot as normal.** Tool calls connect to the running host over the named
   pipe. If you ask it to do something before starting the host, you'll get a clear error
   telling you to double-click the icon first.

Re-run `npm run install-shortcut` any time (e.g. after moving the folder) to refresh the
shortcut; it's safe to run repeatedly.

**To see what Periscope is doing**, open **http://localhost:51823/** in any browser (or
right-click the tray icon → "Open activity dashboard") — a live, auto-refreshing log of every
action, plus the current autonomous-task status with a stop button.

**To stop Periscope**, right-click the tray icon and choose **Exit Periscope** — the one
reliable way to shut down the whole background process (pipe server, dashboard, idle avatar,
everything). Double-click the desktop icon again to start it back up.

### Wiring up an MCP client

**Claude Code**: `.mcp.json` at the repo root points at `dist/index.js` using a path relative to
the project root, so cloning anywhere and running `claude` from the repo directory picks it up
automatically.

**Claude Desktop**: the robot's picker (above) does this for you. To do it by hand instead, add
to `%APPDATA%\Claude\claude_desktop_config.json` (replace the path with your clone location),
then restart Claude Desktop:

```json
{
  "mcpServers": {
    "periscope": {
      "command": "node",
      "args": ["<absolute-path-to-repo>\\dist\\index.js"]
    }
  }
}
```

**GitHub Copilot (VS Code)**: add the same shape to `.vscode/mcp.json` (workspace) or the user
MCP config, under `"servers"` instead of `"mcpServers"`, then enable via `MCP: List Servers` or
the Copilot Chat tools picker.

None of these need `host.py` itself configured anywhere — it's independent of the MCP client
and just needs to be running (step 1 above) before tool calls will succeed. Note that this
config always points Claude Desktop at `node dist/index.js` (the thin pipe client), never
directly at `host.py` — those are two different, separately-managed processes.

## Safety model

Every **mutating** action (`move_mouse`, `click`, `type_text`, `send_keys`, `focus_window`,
`set_clipboard`) pops a native Windows Yes/No dialog before executing, describing exactly what
is about to happen. A "No" response raises a denial back to the calling AI; nothing executes
until approved.

Read-only actions (`screenshot`, `list_screens`, `list_windows`, `get_clipboard`) run without a
prompt.

Set `PERISCOPE_CONFIRM=0` in the MCP server's environment to disable confirmation prompts
entirely (not recommended — removes the only hard gate between an AI's decision and an action
on the host).

### On-screen activity indicators

- **Avatar.** A small mech character — head with a glowing visor, antenna, torso with a
  pulsing chest core, and jointed arms/legs — appears at the relevant screen location for
  every mutating action. No external image/3D assets: drawn with Tkinter `Canvas` primitives
  (`python/avatar.py`), self-animated from wall-clock time (idle leg sway, bob, pulsing
  lights). Pose/visor reflect state: "thinking" (hand raised toward head, pulsing visor,
  thought bubble) right before the confirm dialog, "acting" (reaching pose) while the action
  executes, easing into "happy" (arms raised, visor steady) at the end, or "denied" (arms
  dropped, red visor) if you decline the confirm dialog. Appears at the action's target
  coordinates for `click`/`move_mouse`, or a fixed default spot for actions with no on-screen
  target (`type_text`, `send_keys`, `focus_window`, `set_clipboard`). It's a non-activating
  window (`WS_EX_NOACTIVATE`, set via a direct `ctypes` call since Tkinter doesn't expose this),
  so it never steals keyboard focus.

  The same character, in a persistent idle pose, is also the "is Periscope running" indicator
  and app launcher described above — click it any time to reopen the Claude Desktop/claude.ai
  picker. **Drag it** anywhere on screen to reposition it; a plain click (no movement) opens
  the picker, a click-and-drag just moves it. Its position is remembered across restarts
  (`%TEMP%\periscope-avatar-pos.json`).

  **Customize it** by editing `assets/avatar.config.json`. The transient per-action avatar
  (above) reads it fresh before every popup — no rebuild, no restart. The persistent idle robot
  reads it once when `host.py` starts, so it needs the host restarted (Exit from the tray icon,
  then double-click the desktop icon again — a second double-click while it's already running
  just reopens the picker, it won't restart it) to pick up a config change:

  ```json
  {
    "primaryColor": "#4696FF",
    "accentColor": "#FFD166",
    "antenna": true,
    "shoulderLights": true,
    "chestCore": true
  }
  ```

  `primaryColor`/`accentColor` are hex colors (body plating / visor & light glow — plating
  color stays consistent across states, the glow color switches to red only for `denied` as a
  universal error signal). The three booleans toggle the antenna, shoulder lights, and chest
  core accessories independently. A malformed or missing file falls back to these defaults
  rather than failing the action.
- **Toast.** A short-lived text toast in a screen corner describing what ran. Shown for
  read-only actions and task start/end; skipped for actions that already show the avatar, to
  avoid redundant overlays and latency.
- **Dashboard.** A localhost web page (**http://localhost:51823/**, see "Getting started"
  above), served by `host.py` itself via Python's built-in `http.server` (no admin rights
  needed — binding to `localhost` is always allowed for a normal user). Deliberately not a
  floating always-on-top window: open it when you want to look, close the tab when you don't.

### Bounded autonomous mode

`start_task(description, minutes?)` / `end_task()` let multi-step work run without a
confirmation prompt per action, inside a revocable window:

- `start_task` pops one confirmation dialog for the whole task. If approved, mutating actions
  skip their individual prompts (still toasting/logging, tagged `[auto]`) until `end_task` is
  called. With no `minutes` argument the run is indefinite — there is no default timeout; pass
  `minutes` to bound it instead. State lives in `host.py`'s process (an expiry timestamp
  written to a file), not something the calling AI can silently extend.
- The dashboard shows the active task's description continuously (flagged `(indefinite)` when
  unbounded), with its own **Stop** button — an independent kill-switch that doesn't depend on
  the calling AI cooperating or on ending the task itself.

### Action scoping (app blocklist)

Edit `assets/scope.config.json` to name processes Periscope must never interact with —
password managers, banking apps, anything you want permanently off-limits regardless of
confirmation:

```json
{
  "blockedProcesses": ["keepass", "1password", "bitwarden"]
}
```

Process names are case-insensitive and match without `.exe` (same form `list_windows` reports
as `processName`). This applies to `click` (checked against whatever window is actually at the
target point), `focus_window` (checked against the target pid), and `type_text`/`send_keys`
(checked against whichever window currently holds keyboard focus).

This is a **hard block, not a confirmation** — a blocked action fails immediately with a clear
error, no Yes/No dialog, and critically it is **not** skippable via `skipConfirm` or an active
`start_task` autonomous run; those only ever bypass the confirm dialog, never the scope check.
Read fresh before every check (same as the avatar config), so edits apply immediately with no
rebuild or host restart.

`move_mouse` and `set_clipboard` are intentionally not scoped — scoping covers actions that
directly interact with a specific app's content or window, not just moving the cursor.

## Tools

| Tool | Confirms? | Description |
|---|---|---|
| `screenshot` | no | Capture the full virtual desktop or one monitor as a PNG image |
| `list_screens` | no | List monitors: index, bounds, which is primary |
| `move_mouse` | yes | Move the cursor to absolute coordinates (x, y) |
| `click` | yes | Click at (x, y); left/right/middle button, single/double/triple click |
| `type_text` | yes | Type literal text at the current keyboard focus |
| `send_keys` | yes | Send a raw key combo, e.g. `^c`, `%{TAB}`, `{ENTER}` (SendKeys-compatible mini-syntax) |
| `list_windows` | no | List open windows: pid, title, process name, bounds, minimized state |
| `focus_window` | yes | Restore (if minimized) and foreground a window by pid |
| `get_clipboard` | no | Read clipboard text |
| `set_clipboard` | yes | Write clipboard text |
| `start_task` | yes (once) | Begin an autonomous run (indefinite by default, or bounded via `minutes`); later mutating actions skip their own confirmation until `end_task` or timeout |
| `end_task` | no | End the current autonomous run, restoring per-action confirmation |

Typical usage: `screenshot` to observe state, compute target coordinates from the image, act
with `click`/`type_text`/`send_keys`, `screenshot` again to verify the result.

## Project layout

```
src/index.ts            MCP server: tool schemas (zod), dispatch to pipe-client.ts
src/pipe-client.ts       named-pipe client - connects to host.py, no process spawning
python/host.py          the persistent background process (started via the desktop icon):
                        named pipe server, HTTP dashboard, tray icon, idle/clickable/draggable
                        avatar, main event loop (Tkinter mainloop + background threads)
python/dispatch.py      maps an action name to its implementation: confirm dialog, avatar,
                        activity logging, then the actual call - the switch-equivalent core
python/win32_input.py   Win32 primitives via ctypes/pywin32: mouse, keyboard (SendInput,
                        Unicode-safe), windows, clipboard; PIL.ImageGrab for screenshots
python/avatar.py        the mech character: Tkinter Canvas rendering/animation, toast,
                        confirm dialog
python/dashboard.py     the localhost dashboard: HTML/JS page plus the HTTP request handler
                        (GET /, /api/log, /api/status, POST /api/task/stop)
python/launcher.py      the Claude Desktop / claude.ai picker, used standalone and by the
                        idle avatar's click handler
python/state.py         shared activity-log, autonomous-task, avatar-position/config state
python/install_shortcut.py  creates/refreshes the Desktop shortcut to host.py (pythonw.exe)
python/requirements.txt  pywin32, pystray, Pillow
assets/avatar.config.json  avatar colors/accessories - edit to customize, no rebuild needed
assets/scope.config.json  app blocklist for action scoping - edit to customize, no rebuild needed
Launch Periscope.cmd    shortcut to python/launcher.py (the picker alone, without the host)
```

## Known limitations

- Windows only; depends on `pywin32`, Tkinter (bundled with standard Python on Windows), and
  Win32 `user32.dll`/`kernel32.dll`.
- Requires `host.py` to be running (via the desktop icon) for the MCP server to do anything;
  it does not auto-start it.
- Requires Python 3.10+ installed and on PATH, in addition to Node.
- `click`/`move_mouse` take absolute coordinates across the full virtual desktop (origin at the
  primary monitor's top-left corner; secondary monitors can have negative or beyond-primary-width
  coordinates — use `list_screens` for each monitor's offset). Coordinates are DPI-aware
  (physical pixels), via `SetProcessDPIAware()`.
- `type_text`/`send_keys` use `SendInput`, which targets whatever window currently holds
  keyboard focus; use `focus_window` or `click` on the target first.
- No OCR or UI-element detection — the calling model reads the screenshot image directly to
  compute click targets.
- Mutating actions still take roughly 0.5-1.5s for the avatar's thinking/acting animation to
  play out (not counting time spent waiting on the confirm dialog itself) — this is deliberate
  visual feedback, not process overhead.
- Action scoping matches on the target process's `.exe` name only, read from the OS at the
  moment of the action. It's a guardrail against the AI's own actions, not a sandbox against a
  determined adversary — a process renamed/repackaged under a different executable name won't
  match the blocklist.

### Idle resource use

The idle robot redraws at 10fps (vs ~33fps for the brief per-action popups) — plenty smooth
for a mostly-still background character, and it's the one thing in this stack that redraws for
as long as `host.py` is running, so its rate matters more than a transient animation's does.
`avatar.config.json`/`scope.config.json` are cached by file modification time, so an action
that doesn't touch either doesn't pay for a disk read + JSON parse it doesn't need; an edit to
either file still takes effect on the very next check. The activity log (which the dashboard
polls every second while open) is read incrementally — only the bytes written since the last
read, not the whole file — so dashboard polling doesn't get slower as a long-running session's
log grows.

## License

[MIT](LICENSE)
