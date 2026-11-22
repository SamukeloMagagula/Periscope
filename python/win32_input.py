"""Low-level Win32 primitives: cursor/click, keyboard (SendInput, Unicode-safe), window
enumeration/focus, clipboard, screenshot. Equivalent to the Win32 P/Invoke + System.Windows.Forms
calls the old assets/lib.ps1 made, translated to ctypes + pywin32 so no PowerShell/.NET is
involved at runtime.
"""
import ctypes
import ctypes.wintypes as wintypes
import time

import win32clipboard
import win32con
import win32gui
import win32process
from PIL import ImageGrab

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()

# --- mouse ---

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040


def move_mouse(x: int, y: int):
    user32.SetCursorPos(int(x), int(y))
    return {"x": x, "y": y}


def click(x: int, y: int, button: str = "left", count: int = 1):
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    down, up = {
        "right": (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        "middle": (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
    }.get(button, (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP))

    for i in range(count):
        user32.mouse_event(down, 0, 0, 0, 0)
        user32.mouse_event(up, 0, 0, 0, 0)
        if count > 1:
            time.sleep(0.08)
    return {"x": x, "y": y, "button": button, "count": count}


# --- keyboard, via SendInput ---

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG)),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("union", INPUT_UNION)]


def _send_key_input(wVk=0, wScan=0, flags=0):
    inp = INPUT(type=INPUT_KEYBOARD, union=INPUT_UNION(ki=KEYBDINPUT(wVk, wScan, flags, 0, None)))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def type_text(text: str):
    # KEYEVENTF_UNICODE sends arbitrary Unicode characters directly, without needing a
    # virtual-key-code lookup per character - simpler and more robust than scancode-based typing
    # (and avoids the escaping headaches the old SendKeys-based implementation had).
    for ch in text:
        code = ord(ch)
        _send_key_input(wScan=code, flags=KEYEVENTF_UNICODE)
        _send_key_input(wScan=code, flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)
        time.sleep(0.004)
    return {"sent": len(text)}


# Minimal SendKeys-compatible mini-syntax: ^ (ctrl) % (alt) + (shift) modifier prefixes,
# {KEYNAME} for special keys, parens for grouping modifiers over multiple keys, plain chars
# otherwise. Covers the combos documented in the README (^c, %{TAB}, {ENTER}, ^{ESC}, etc.)
_VK_MAP = {
    "ENTER": 0x0D, "TAB": 0x09, "ESC": 0x1B, "ESCAPE": 0x1B,
    "BACKSPACE": 0x08, "BS": 0x08, "DELETE": 0x2E, "DEL": 0x2E,
    "HOME": 0x24, "END": 0x23, "LEFT": 0x25, "UP": 0x26, "RIGHT": 0x27, "DOWN": 0x28,
    "INSERT": 0x2D, "PGUP": 0x21, "PGDN": 0x22, "SPACE": 0x20,
    "F1": 0x70, "F2": 0x71, "F3": 0x72, "F4": 0x73, "F5": 0x74, "F6": 0x75,
    "F7": 0x76, "F8": 0x77, "F9": 0x78, "F10": 0x79, "F11": 0x7A, "F12": 0x7B,
}
VK_CONTROL = 0x11
VK_MENU = 0x12  # alt
VK_SHIFT = 0x10


def _press_vk(vk, down):
    flags = 0 if down else KEYEVENTF_KEYUP
    _send_key_input(wVk=vk, flags=flags)


def send_keys(sequence: str):
    i = 0
    active_modifiers: list[int] = []
    n = len(sequence)

    def press_one(vk_or_char):
        if isinstance(vk_or_char, int):
            _press_vk(vk_or_char, True)
            _press_vk(vk_or_char, False)
        else:
            code = ord(vk_or_char)
            _send_key_input(wScan=code, flags=KEYEVENTF_UNICODE)
            _send_key_input(wScan=code, flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)

    while i < n:
        ch = sequence[i]
        if ch == "^":
            _press_vk(VK_CONTROL, True)
            active_modifiers.append(VK_CONTROL)
            i += 1
        elif ch == "%":
            _press_vk(VK_MENU, True)
            active_modifiers.append(VK_MENU)
            i += 1
        elif ch == "+":
            _press_vk(VK_SHIFT, True)
            active_modifiers.append(VK_SHIFT)
            i += 1
        elif ch == "(":
            i += 1  # grouping: modifiers already held stay held through the group
        elif ch == ")":
            i += 1
        elif ch == "{":
            end = sequence.index("}", i)
            name = sequence[i + 1:end].upper()
            vk = _VK_MAP.get(name)
            if vk:
                press_one(vk)
            elif len(name) == 1:
                press_one(name)
            i = end + 1
            for m in active_modifiers:
                _press_vk(m, False)
            active_modifiers = []
        else:
            press_one(ch)
            i += 1
            for m in active_modifiers:
                _press_vk(m, False)
            active_modifiers = []
        time.sleep(0.01)

    for m in active_modifiers:
        _press_vk(m, False)
    return {"sent": sequence}


# --- windows ---


def list_windows():
    results = []

    def _enum(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return True
        title = win32gui.GetWindowText(hwnd)
        if not title:
            return True
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        rect = win32gui.GetWindowRect(hwnd)
        results.append({
            "pid": pid,
            "processName": _process_name(pid),
            "title": title,
            "minimized": bool(win32gui.IsIconic(hwnd)),
            "x": rect[0], "y": rect[1],
            "width": rect[2] - rect[0], "height": rect[3] - rect[1],
        })
        return True

    win32gui.EnumWindows(_enum, None)
    return results


def _process_name(pid: int) -> str:
    try:
        import win32api

        handle = win32api.OpenProcess(0x0400 | 0x0010, False, pid)  # QUERY_INFORMATION | VM_READ
        try:
            path = win32process.GetModuleFileNameEx(handle, 0)
            name = path.rsplit("\\", 1)[-1]
            return name[:-4] if name.lower().endswith(".exe") else name
        finally:
            win32api.CloseHandle(handle)
    except Exception:
        return ""


def get_process_name(pid: int) -> str:
    return _process_name(pid)


def process_at_point(x: int, y: int) -> str:
    # Used by action scoping (dispatch.py) to find out which app a click would actually land
    # on, before the click happens.
    hwnd = win32gui.WindowFromPoint((int(x), int(y)))
    if not hwnd:
        return ""
    _, pid = win32process.GetWindowThreadProcessId(hwnd)
    return _process_name(pid)


def focused_process_name() -> str:
    # Used by action scoping for type_text/send_keys, which act on whatever currently has
    # keyboard focus rather than a specific target window.
    hwnd = win32gui.GetForegroundWindow()
    if not hwnd:
        return ""
    _, pid = win32process.GetWindowThreadProcessId(hwnd)
    return _process_name(pid)


def focus_window(pid: int):
    target_hwnd = None

    def _enum(hwnd, _):
        nonlocal target_hwnd
        if not win32gui.IsWindowVisible(hwnd) or not win32gui.GetWindowText(hwnd):
            return True
        _, wpid = win32process.GetWindowThreadProcessId(hwnd)
        if wpid == pid:
            target_hwnd = hwnd
            return False
        return True

    win32gui.EnumWindows(_enum, None)
    if not target_hwnd:
        raise RuntimeError(f"Process {pid} has no visible top-level window")

    if win32gui.IsIconic(target_hwnd):
        win32gui.ShowWindow(target_hwnd, win32con.SW_RESTORE)
    time.sleep(0.1)
    try:
        win32gui.SetForegroundWindow(target_hwnd)
        ok = True
    except Exception:
        ok = False
    return {"pid": pid, "focused": ok}


# --- clipboard ---


def get_clipboard():
    try:
        win32clipboard.OpenClipboard()
        try:
            text = win32clipboard.GetClipboardData(win32con.CF_UNICODETEXT)
        except TypeError:
            text = ""
        finally:
            win32clipboard.CloseClipboard()
        return {"text": text or ""}
    except Exception:
        return {"text": ""}


def set_clipboard(text: str):
    win32clipboard.OpenClipboard()
    try:
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardData(win32con.CF_UNICODETEXT, text)
    finally:
        win32clipboard.CloseClipboard()
    return {"set": True}


# --- screens / screenshot ---


def list_screens():
    import win32api

    monitors = win32api.EnumDisplayMonitors()
    results = []
    for i, (_, _, rect) in enumerate(monitors):
        info = win32api.GetMonitorInfo(win32api.MonitorFromRect(rect))
        results.append({
            "index": i,
            "primary": bool(info["Flags"] & 1),
            "x": rect[0], "y": rect[1],
            "width": rect[2] - rect[0], "height": rect[3] - rect[1],
        })
    return results


def screenshot(out_path: str, monitor: int | None = None):
    screens = list_screens()
    if monitor is not None and 0 <= monitor < len(screens):
        s = screens[monitor]
        bbox = (s["x"], s["y"], s["x"] + s["width"], s["y"] + s["height"])
    else:
        bbox = None  # full virtual desktop

    img = ImageGrab.grab(bbox=bbox, all_screens=True)
    img.save(out_path, "PNG")
    return {"path": out_path, "width": img.width, "height": img.height}
