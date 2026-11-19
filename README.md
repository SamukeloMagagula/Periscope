# Periscope

MCP server that gives an AI assistant (Claude, GitHub Copilot, or any MCP client) screen
capture and input control on a Windows machine: screenshots, mouse move/click, keyboard
input, window enumeration/focus, and clipboard read/write.

## How it works

It's a [Model Context Protocol](https://modelcontextprotocol.io) server. The Node/TypeScript
layer (`src/`) only validates tool input and shells out to `powershell.exe`; the actual screen,
input and window control is implemented in `.NET` (`System.Drawing`, `System.Windows.Forms`)
and raw Win32 P/Invoke (`user32.dll`) from PowerShell (`assets/`). There are no native Node
addons to compile, so it has no node-gyp/prebuild/ABI dependency on the Node version in use.

Each tool call spawns a fresh `powershell.exe assets/run.ps1 -Action <name> -ParamsFile <path>`
process, which dot-sources `assets/lib.ps1` for the actual implementations and prints a single
JSON object to stdout that the Node side parses.

## Safety model

Every **mutating** action (`move_mouse`, `click`, `type_text`, `send_keys`, `focus_window`,
`set_clipboard`) pops a native Windows Yes/No dialog before executing, describing exactly what
is about to happen. A "No" response raises a denial back to the calling AI; nothing executes
until approved.

Read-only actions (`screenshot`, `list_screens`, `list_windows`, `get_clipboard`) run without a
prompt.

Set `PERISCOPE_CONFIRM=0` in the server's environment to disable confirmation prompts entirely
(not recommended — removes the only hard gate between an AI's decision and an action on the
host).

### On-screen activity indicators

- Every action logs a short-lived, non-activating toast (`WS_EX_NOACTIVATE`) in a screen
  corner describing what ran. Non-activating so it never steals keyboard focus from whatever
  window an action is about to type into.
- `click`/`move_mouse` flash a ring at the target coordinates immediately before acting, as a
  visual marker distinct from the real cursor.
- `assets/hud.ps1` is a persistent, single-instance (named mutex), always-on-top panel that
  tails a shared activity log and shows a running history of all actions. The MCP server spawns
  it automatically on startup; run it manually with `npm run hud` if it's been closed.

### Bounded autonomous mode

`start_task(description, minutes?)` / `end_task()` let multi-step work run without a
confirmation prompt per action, inside a time-boxed, revocable window:

- `start_task` pops one confirmation dialog for the whole task. If approved, mutating actions
  skip their individual prompts (still toasting/logging, tagged `[auto]`) until `end_task` is
  called or the window expires (default 10 minutes, max 30, enforced server-side via an expiry
  timestamp written to a state file).
- The HUD shows the active task's description continuously, with its own **Stop** button —
  an independent kill-switch that doesn't depend on the calling AI cooperating.

## Setup

```sh
npm install
npm run build
```

Produces `dist/index.js`, the server entry point (stdio transport).

### Claude Code

`.mcp.json` at the repo root points at `dist/index.js` using a path relative to the project
root, so cloning anywhere and running `claude` from the repo directory picks it up
automatically — no edits needed.

### Claude Desktop

Claude Desktop spawns MCP servers from its own working directory, so it needs an absolute
path. Add to `%APPDATA%\Claude\claude_desktop_config.json`, replacing the path with your clone
location:

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

Restart Claude Desktop afterward — MCP clients only read their config at startup.

### GitHub Copilot (VS Code)

Add to `.vscode/mcp.json` (workspace) or the user MCP config:

```json
{
  "servers": {
    "periscope": {
      "command": "node",
      "args": ["<absolute-path-to-repo>\\dist\\index.js"]
    }
  }
}
```

Enable via the `MCP: List Servers` command or the Copilot Chat tools picker.

### Launcher

```sh
npm run launch
```

or run `Launch Periscope.cmd`. Opens a picker:

- **Launch Claude Desktop** — merges a `periscope` entry into
  `%APPDATA%\Claude\claude_desktop_config.json` (backs up the existing file to `.bak` first,
  preserving any other configured servers), then starts Claude Desktop. Reports clearly if
  Claude Desktop isn't installed rather than failing silently.
- **Open claude.ai in browser** — opens the site for a plain chat session. claude.ai's web UI
  only supports remote HTTPS+OAuth MCP connectors, not a local stdio process, so this path gets
  no device control; the picker states this before opening the browser.

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
| `start_task` | yes (once) | Begin a bounded autonomous run; later mutating actions skip their own confirmation until `end_task` or timeout |
| `end_task` | no | End the current autonomous run, restoring per-action confirmation |

Typical usage: `screenshot` to observe state, compute target coordinates from the image, act
with `click`/`type_text`/`send_keys`, `screenshot` again to verify the result.

## Project layout

```
src/index.ts        MCP server: tool schemas (zod), dispatch to powershell.ts, HUD auto-spawn
src/powershell.ts    spawns assets/run.ps1 per action, parses its JSON stdout
assets/lib.ps1       screen/mouse/keyboard/window/clipboard implementations; toast and cursor-ring
                      overlays; shared activity-log and autonomous-task state helpers
assets/run.ps1       dispatches -Action to the matching function; confirm dialog, toast, cursor
                      ring, and auto-task state checks happen here
assets/hud.ps1       persistent always-on-top narration panel; tails the shared activity log
assets/launcher.ps1  app picker; merges claude_desktop_config.json; launches Claude Desktop
Launch Periscope.cmd shortcut to assets/launcher.ps1
```

## Known limitations

- Windows only; depends on `powershell.exe`, .NET WinForms, and Win32 user32.dll.
- `click`/`move_mouse` take absolute coordinates across the full virtual desktop (origin at the
  primary monitor's top-left corner; secondary monitors can have negative or beyond-primary-width
  coordinates — use `list_screens` for each monitor's offset).
- `type_text` goes through `SendKeys`, which targets whatever window currently holds focus; use
  `focus_window` or `click` on the target first.
- No OCR or UI-element detection — the calling model reads the screenshot image directly to
  compute click targets.
- Each action spawns a new `powershell.exe` process; expect roughly 0.5-1s of fixed overhead
  per call before the action itself runs.

## License

[MIT](LICENSE)
