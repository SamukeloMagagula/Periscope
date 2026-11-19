# Periscope

MCP server that gives an AI assistant (Claude, GitHub Copilot, or any MCP client) screen
capture and input control on a Windows machine: screenshots, mouse move/click, keyboard
input, window enumeration/focus, and clipboard read/write.

## How it works

It's a [Model Context Protocol](https://modelcontextprotocol.io) server, split into two parts:

- **`assets/host.ps1`** — a persistent background process you start once (by double-clicking a
  desktop icon). It hosts a named pipe server, the activity HUD, and a clickable idle avatar,
  and performs every actual screen/mouse/keyboard/window/clipboard action in-process. All the
  .NET types (`System.Drawing`, `System.Windows.Forms`, raw Win32 P/Invoke into `user32.dll`)
  compile once at startup, not per action.
- **`src/index.ts`** (the MCP server, `dist/index.js`) — a thin Node client. Each tool call
  opens a connection to the host's named pipe (`\\.\pipe\PeriscopeActionPipe`), sends a JSON
  request, and reads back a JSON response. It spawns no processes and owns no GUI itself.

This two-process design exists specifically so an MCP tool call is fast and lightweight: it's a
local IPC round-trip (tens of milliseconds for read-only calls) instead of spawning a fresh
`powershell.exe` per action, which matters on a resource-constrained machine — spawning a new
process and recompiling the .NET types in it from scratch previously cost roughly 0.5-2s
*before* the actual action even ran. If `host.ps1` isn't running, tool calls fail fast with a
clear message telling you to start it, rather than silently doing nothing or auto-spawning
background processes on your behalf.

There are no native Node addons anywhere in this stack, so it has no node-gyp/prebuild/ABI
dependency on the Node version in use.

## Getting started

```sh
npm install
npm run build
npm run install-shortcut
```

This builds `dist/index.js` and creates a **Periscope** shortcut on your Desktop.

1. **Double-click the Periscope desktop icon.** This starts `host.ps1` in the background (no
   visible console window) and shows a small idle robot avatar in the middle of your screen —
   that's your confirmation it's running. The activity HUD panel also appears, top-right.
2. **Click the robot.** It opens a picker: launch Claude Desktop (configured automatically to
   use Periscope) or open claude.ai in a browser. The robot then hides, and only reappears
   briefly during actual actions from here on.
3. **Prompt Claude/Copilot as normal.** Tool calls connect to the running host over the named
   pipe. If you ask it to do something before starting the host, you'll get a clear error
   telling you to double-click the icon first.

Re-run `npm run install-shortcut` any time (e.g. after moving the folder) to refresh the
shortcut; it's safe to run repeatedly.

**To stop Periscope**, close the "Periscope - Activity" HUD panel — that shuts down the whole
background process (pipe server, idle avatar, everything). Double-click the desktop icon again
to start it back up.

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

None of these need `host.ps1` itself configured anywhere — it's independent of the MCP client
and just needs to be running (step 1 above) before tool calls will succeed.

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
  every mutating action. No external image/3D assets: pure GDI+ drawing (`AvatarForm.OnPaint`
  in `assets/lib.ps1`), self-animated from wall-clock time (idle leg sway, bob, pulsing
  lights). Pose/visor reflect state: "thinking" (hand raised toward head, pulsing visor,
  thought bubble) right before the confirm dialog, "acting" (reaching pose) while the action
  executes, easing into "happy" (arms raised, visor steady) at the end, or "denied" (arms
  dropped, red visor) if you decline the confirm dialog. Appears at the action's target
  coordinates for `click`/`move_mouse`, or a fixed default spot for actions with no on-screen
  target (`type_text`, `send_keys`, `focus_window`, `set_clipboard`). It's a non-activating,
  layered window (`WS_EX_NOACTIVATE`), so it never steals keyboard focus.

  The same character, in a persistent idle pose, is also the "is Periscope running" indicator
  and app launcher described above — click it any time to reopen the Claude Desktop/claude.ai
  picker.

  **Customize it** by editing `assets/avatar.config.json`. The transient per-action avatar
  (above) reads it fresh before every popup — no rebuild, no restart. The persistent idle robot
  reads it once when `host.ps1` starts, so it needs the host process restarted (close it and
  double-click the desktop icon again — a second double-click while it's already running just
  reopens the picker, it won't restart it) to pick up a config change:

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
- **HUD.** A persistent, always-on-top panel, part of `host.ps1`, showing a running history of
  every action and the current autonomous-task status with a one-click stop button.

### Bounded autonomous mode

`start_task(description, minutes?)` / `end_task()` let multi-step work run without a
confirmation prompt per action, inside a revocable window:

- `start_task` pops one confirmation dialog for the whole task. If approved, mutating actions
  skip their individual prompts (still toasting/logging, tagged `[auto]`) until `end_task` is
  called. With no `minutes` argument the run is indefinite — there is no default timeout; pass
  `minutes` to bound it instead. State lives in `host.ps1`'s process (an expiry timestamp
  written to a file), not something the calling AI can silently extend.
- The HUD shows the active task's description continuously (flagged `(indefinite)` when
  unbounded), with its own **Stop** button — an independent kill-switch that doesn't depend on
  the calling AI cooperating or on ending the task itself.

## Tools

| Tool | Confirms? | Description |
|---|---|---|
| `screenshot` | no | Capture the full virtual desktop or one monitor as a PNG image |
| `list_screens` | no | List monitors: index, bounds, which is primary |
| `move_mouse` | yes | Move the cursor to absolute coordinates (x, y) |
| `click` | yes | Click at (x, y); left/right/middle button, single/double/triple click |
| `type_text` | yes | Type literal text at the current keyboard focus |
| `send_keys` | yes | Send a raw Windows `SendKeys` combo, e.g. `^c`, `%{TAB}`, `{ENTER}` |
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
src/index.ts          MCP server: tool schemas (zod), dispatch to powershell.ts
src/powershell.ts      named-pipe client - connects to host.ps1, no process spawning
assets/host.ps1        the persistent background process (started via the desktop icon):
                        named pipe server, HUD, idle/clickable avatar, main event loop
assets/dispatch.ps1    Invoke-EyesAction: the switch that maps an action name to its
                        implementation, confirm dialog, avatar, and HUD logging - shared by
                        host.ps1 and the standalone run.ps1
assets/lib.ps1         screen/mouse/keyboard/window/clipboard implementations; avatar/toast
                        overlays; shared activity-log and autonomous-task state helpers
assets/run.ps1         standalone single-action runner for manual testing (not used by the
                        live MCP server - see "Quick manual test" below)
assets/launcher-lib.ps1  Show-EyesLauncherPicker: the Claude Desktop / claude.ai picker,
                        used by both launcher.ps1 and the idle avatar's click handler
assets/launcher.ps1    standalone entry point for the picker (npm run launch)
assets/hud-lib.ps1      New-EyesHudForm: builds the activity panel, used by host.ps1 and hud.ps1
assets/hud.ps1         standalone HUD (npm run hud), only needed if you want it separately
assets/install-shortcut.ps1  creates/refreshes the Desktop shortcut to host.ps1
assets/avatar.config.json  avatar colors/accessories - edit to customize, no rebuild needed
Launch Periscope.cmd   shortcut to assets/launcher.ps1 (the picker alone, without the host)
```

### Quick manual test

To exercise an action without an MCP client or the host process, with `host.ps1` NOT running:

```powershell
'{"outPath":"C:\\path\\to\\test.png"}' | Out-File -Encoding utf8 "$env:TEMP\params.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File assets\run.ps1 -Action screenshot -ParamsFile "$env:TEMP\params.json"
```

## Known limitations

- Windows only; depends on `powershell.exe`, .NET WinForms, and Win32 user32.dll/kernel32.dll.
- Requires `host.ps1` to be running (via the desktop icon) for the MCP server to do anything;
  it does not auto-start it.
- `click`/`move_mouse` take absolute coordinates across the full virtual desktop (origin at the
  primary monitor's top-left corner; secondary monitors can have negative or beyond-primary-width
  coordinates — use `list_screens` for each monitor's offset).
- `type_text` goes through `SendKeys`, which targets whatever window currently holds focus; use
  `focus_window` or `click` on the target first.
- No OCR or UI-element detection — the calling model reads the screenshot image directly to
  compute click targets.
- Mutating actions still take roughly 0.5-1.5s for the avatar's thinking/acting animation to
  play out (not counting time spent waiting on the confirm dialog itself) — this is deliberate
  visual feedback, not fixed process overhead like before.

## License

[MIT](LICENSE)
