"""Periscope host: the persistent background process launched by double-clicking the
"Periscope" desktop icon (pythonw.exe, so no console window is ever created - not even
briefly, unlike the old PowerShell console-hiding workaround). Owns:

  - a named pipe server the MCP server (src/powershell.ts) connects to for each action,
    instead of spawning a process
  - a localhost web dashboard (dashboard.py)
  - a system tray icon: the "is it running" indicator and the one reliable way to exit
  - an idle, clickable, draggable avatar ("the bot")

Single-instance via a named mutex: double-clicking the desktop icon again while this is
already running just reopens the picker instead of starting a second host.
"""
import json
import os
import queue
import sys
import threading
import tkinter as tk
import webbrowser

import pystray
import win32api
import win32event
import win32file
import win32pipe
import winerror
from PIL import Image, ImageDraw

import avatar
import dashboard
import dispatch
import launcher
import state

PIPE_NAME = r"\\.\pipe\PeriscopeActionPipe"
DASHBOARD_URL = f"http://localhost:{dashboard.PORT}/"

_request_queue: "queue.Queue[tuple[dict, queue.Queue]]" = queue.Queue()


# --- single instance guard ---

_mutex = win32event.CreateMutex(None, False, "Global\\PeriscopeHost")
if win32api.GetLastError() == winerror.ERROR_ALREADY_EXISTS:
    _root = tk.Tk()
    _root.withdraw()
    launcher.show_picker(_root)
    sys.exit(0)


# --- named pipe server (background thread; hands actual work to the main/Tk thread) ---


def _pipe_server_loop():
    while True:
        pipe = win32pipe.CreateNamedPipe(
            PIPE_NAME,
            win32pipe.PIPE_ACCESS_DUPLEX,
            win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_READMODE_BYTE | win32pipe.PIPE_WAIT,
            win32pipe.PIPE_UNLIMITED_INSTANCES,
            65536,
            65536,
            0,
            None,
        )
        try:
            win32pipe.ConnectNamedPipe(pipe, None)

            buf = b""
            while b"\n" not in buf:
                _, data = win32file.ReadFile(pipe, 65536)
                if not data:
                    break
                buf += data
            line = buf.split(b"\n", 1)[0].decode("utf-8")

            try:
                req = json.loads(line)
                response_box: "queue.Queue[dict]" = queue.Queue()
                _request_queue.put((req, response_box))
                response = response_box.get()
            except Exception as e:  # malformed request JSON etc.
                response = {"ok": False, "error": str(e), "denied": False}

            win32file.WriteFile(pipe, (json.dumps(response) + "\n").encode("utf-8"))
            # Without this, DisconnectNamedPipe can tear down the connection before the
            # client finishes reading what WriteFile just wrote, surfacing as EPIPE/ECONNRESET
            # on the Node side even though the server "succeeded" - found via live testing.
            win32file.FlushFileBuffers(pipe)
        except Exception:
            pass  # client disconnected early or similar pipe-level hiccup - keep serving
        finally:
            try:
                win32pipe.DisconnectNamedPipe(pipe)
                win32file.CloseHandle(pipe)
            except Exception:
                pass


# --- main Tk root (never shown itself - just the event-loop host for Toplevel popups) ---

root = tk.Tk()
root.withdraw()


def _poll_request_queue():
    try:
        while True:
            req, response_box = _request_queue.get_nowait()
            cfg = state.get_avatar_config()
            try:
                result = dispatch.dispatch(root, cfg, req.get("action"), req.get("params") or {})
                response_box.put({"ok": True, "result": result})
            except dispatch.ActionDenied as e:
                response_box.put({"ok": False, "error": str(e), "denied": True})
            except dispatch.ActionBlocked as e:
                response_box.put({"ok": False, "error": str(e), "denied": False, "blocked": True})
            except Exception as e:
                response_box.put({"ok": False, "error": str(e), "denied": False})
    except queue.Empty:
        pass
    root.after(20, _poll_request_queue)


# --- system tray icon: status indicator and the documented way to exit ---


def _make_tray_image():
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((2, 2, 30, 30), fill="#4696FF", outline="#2a5fa8")
    d.ellipse((10, 11, 15, 16), fill="white")
    d.ellipse((17, 11, 22, 16), fill="white")
    return img


def _open_dashboard(icon=None, item=None):
    webbrowser.open(DASHBOARD_URL)


def _exit_periscope(icon=None, item=None):
    try:
        _http_server.shutdown()
    except Exception:
        pass
    try:
        tray_icon.stop()
    except Exception:
        pass
    os._exit(0)


tray_icon = pystray.Icon(
    "periscope",
    _make_tray_image(),
    "Periscope - right-click to exit",
    menu=pystray.Menu(
        pystray.MenuItem("Open activity dashboard", _open_dashboard, default=True),
        pystray.MenuItem("Exit Periscope", _exit_periscope),
    ),
)


# --- idle, clickable, draggable avatar ---

_saved_pos = state.get_avatar_position()
if _saved_pos:
    idle_x, idle_y = _saved_pos["x"], _saved_pos["y"]
else:
    idle_x, idle_y = root.winfo_screenwidth() // 2, root.winfo_screenheight() // 2

_idle_cfg = state.get_avatar_config()
idle_avatar = avatar.AvatarWindow(
    root, idle_x, idle_y, state="idle", duration_ms=10**9, cfg=_idle_cfg, tick_ms=100
)  # 10fps instead of ~33fps - this one redraws for as long as host.py runs, unlike the
   # transient per-action popups, so its redraw rate matters for idle CPU use
idle_avatar.win.config(cursor="hand2")

_drag = {"dragging": False, "moved": False, "start_mouse": None, "start_win": None}


def _on_press(event):
    _drag["dragging"] = True
    _drag["moved"] = False
    _drag["start_mouse"] = (event.x_root, event.y_root)
    _drag["start_win"] = (idle_avatar.win.winfo_x(), idle_avatar.win.winfo_y())


def _on_motion(event):
    if not _drag["dragging"]:
        return
    dx = event.x_root - _drag["start_mouse"][0]
    dy = event.y_root - _drag["start_mouse"][1]
    if abs(dx) > 3 or abs(dy) > 3:
        _drag["moved"] = True
    nx = _drag["start_win"][0] + dx
    ny = _drag["start_win"][1] + dy
    idle_avatar.win.geometry(f"+{nx}+{ny}")


def _on_release(event):
    if not _drag["dragging"]:
        return
    _drag["dragging"] = False
    if _drag["moved"]:
        anchor_x = idle_avatar.win.winfo_x() + avatar.CX
        anchor_y = idle_avatar.win.winfo_y() + (avatar.H - 14)
        state.save_avatar_position(anchor_x, anchor_y)
    else:
        idle_avatar.destroy()
        launcher.show_picker(root)


idle_avatar.canvas.bind("<ButtonPress-1>", _on_press)
idle_avatar.canvas.bind("<B1-Motion>", _on_motion)
idle_avatar.canvas.bind("<ButtonRelease-1>", _on_release)


# --- start everything ---

state.write_log(f"Periscope is running - click the robot to launch Claude Desktop or claude.ai. Dashboard: {DASHBOARD_URL}")

_http_server = dashboard.start()
threading.Thread(target=_pipe_server_loop, daemon=True).start()
threading.Thread(target=tray_icon.run, daemon=True).start()

root.after(20, _poll_request_queue)
root.mainloop()
