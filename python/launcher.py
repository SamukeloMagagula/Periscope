"""The "which app do you want to use with Periscope" picker, shown standalone or from the
idle avatar's click handler. Mirrors the old assets/launcher-lib.ps1."""
import json
import os
import shutil
import subprocess
import tkinter as tk
from pathlib import Path
from tkinter import messagebox

ROOT = Path(__file__).resolve().parent.parent


def _server_entry():
    # Claude Desktop spawns the MCP server (Node, src/index.ts -> dist/index.js), which is a
    # thin named-pipe client - it is NOT the same process as the Python host (host.py), which
    # is launched separately and persistently via the desktop shortcut.
    return {"command": "node", "args": [str(ROOT / "dist" / "index.js")]}


def _set_desktop_config():
    config_path = Path(os.environ["APPDATA"]) / "Claude" / "claude_desktop_config.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)

    config = {}
    if config_path.exists():
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            config = {}

    config.setdefault("mcpServers", {})
    config["mcpServers"]["periscope"] = _server_entry()

    if config_path.exists():
        shutil.copy(config_path, config_path.with_suffix(".json.bak"))
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config_path


def _find_claude_desktop_exe():
    local = Path(os.environ["LOCALAPPDATA"])
    candidates = [
        local / "AnthropicClaude" / "Claude.exe",
        local / "Programs" / "Claude" / "Claude.exe",
        local / "Programs" / "claude" / "Claude.exe",
        local / "Claude" / "Claude.exe",
    ]
    for c in candidates:
        if c.exists():
            return c
    try:
        for p in local.rglob("Claude.exe"):
            return p
    except OSError:
        pass
    return None


def show_picker(parent):
    """parent: an existing Tk root/Toplevel. Opens as a Toplevel, not a second Tk() instance -
    Tkinter only tolerates one of those per process, and host.py already has one running."""
    win = tk.Toplevel(parent)
    win.title("Periscope")
    win.geometry("420x220")
    win.resizable(False, False)
    win.attributes("-topmost", True)

    tk.Label(win, text="Which app do you want to use with Periscope?", wraplength=380,
             justify="left").place(x=20, y=15, width=380, height=40)

    def launch_desktop():
        config_path = _set_desktop_config()
        exe = _find_claude_desktop_exe()
        if exe:
            subprocess.Popen([str(exe)])
            win.destroy()
        else:
            messagebox.showwarning(
                "Claude Desktop not found",
                f"Updated {config_path} with the periscope server, but Claude Desktop isn't "
                "installed on this machine.\n\nInstall it, then relaunch this picker (or just "
                "open Claude Desktop yourself - it will pick up the config automatically).",
                parent=win,
            )

    def open_web():
        messagebox.showinfo(
            "No laptop control in web",
            "claude.ai in a browser cannot use the periscope tools (screenshot/click/type) - "
            "that only works through a local MCP client like Claude Desktop or Claude Code."
            "\n\nOpening claude.ai for a normal chat, without laptop control.",
            parent=win,
        )
        os.startfile("https://claude.ai")
        win.destroy()

    tk.Button(win, text="Launch Claude Desktop (full control)", command=launch_desktop
              ).place(x=20, y=65, width=360, height=40)
    tk.Button(win, text="Open claude.ai in browser (no laptop control)", command=open_web
              ).place(x=20, y=115, width=360, height=40)

    tk.Label(
        win,
        text="claude.ai web can't load a local MCP server - it won't be able to see your screen or click.",
        fg="#808080", font=("Segoe UI", 8), wraplength=380, justify="left",
    ).place(x=20, y=160, width=380, height=40)

    win.grab_set()
    parent.wait_window(win)


if __name__ == "__main__":
    _root = tk.Tk()
    _root.withdraw()
    show_picker(_root)
    _root.destroy()
