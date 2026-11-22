"""The mech avatar: transient per-action popups (thinking/acting/happy/denied) and the
persistent, draggable, clickable idle robot. Rendered with Tkinter Canvas instead of GDI+;
same poses/states/animation approach as the old assets/lib.ps1 AvatarForm, translated.
"""
import ctypes
import math
import time
import tkinter as tk
from tkinter import messagebox

GWL_EXSTYLE = -20
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TOOLWINDOW = 0x00000080

W, H = 170, 150
CX = 60  # fixed anchor x, independent of W, leaving room on the right for the thought bubble


def _make_noactivate(win: tk.Toplevel):
    # Never steals keyboard focus from whatever window an action is about to type into -
    # same guarantee WS_EX_NOACTIVATE gave the old WinForms AvatarForm.
    try:
        hwnd = win.winfo_id()
        style = ctypes.windll.user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
        ctypes.windll.user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)
    except Exception:
        pass


def _hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _rgb_hex(rgb):
    return "#%02x%02x%02x" % tuple(max(0, min(255, int(c))) for c in rgb)


def _blend(hex_a, hex_b, t):
    a, b = _hex_rgb(hex_a), _hex_rgb(hex_b)
    return _rgb_hex(tuple(a[i] + (b[i] - a[i]) * t for i in range(3)))


def _lighten(h, amount):
    return _blend(h, "#ffffff", amount)


def _darken(h, amount):
    return _blend(h, "#000000", amount)


def _arm_offsets(state, happy, is_lead):
    if happy:
        return (12, -10, 16, -22)
    if state == "denied":
        return (4, 16, 2, 30)
    if state == "thinking" and is_lead:
        return (6, 2, 0, -8)
    if state == "acting":
        return (12, 10, 20, 16)
    return (10, 14, 14, 28)  # idle fallback


class AvatarWindow:
    """One avatar popup/character instance. For transient states it self-destructs after
    duration_ms and calls on_done(); for the idle state it stays up indefinitely and the
    caller wires its own mouse handlers (see host.py)."""

    def __init__(self, root, x, y, state="acting", duration_ms=650, cfg=None, on_done=None,
                 tick_ms=30):
        self.root = root
        self.state = state
        self.start = time.time()
        self.duration = duration_ms / 1000.0
        self.cfg = cfg or {}
        self.on_done = on_done
        self._destroyed = False
        # Transient action popups redraw at ~33fps for snappy-feeling state transitions; the
        # idle avatar (host.py passes a slower tick_ms) runs for as long as host.py does, so a
        # much lower redraw rate matters for CPU use on a resource-constrained machine - bob/
        # blink don't need 33fps to read as smooth for a mostly-still background character.
        self.tick_ms = tick_ms

        self.win = tk.Toplevel(root)
        self.win.overrideredirect(True)
        self.win.attributes("-topmost", True)
        self.win.configure(bg="magenta")
        self.win.attributes("-transparentcolor", "magenta")
        self.win.geometry(f"{W}x{H}+{x - CX}+{y - (H - 14)}")
        self.canvas = tk.Canvas(self.win, width=W, height=H, bg="magenta", highlightthickness=0)
        self.canvas.pack()
        self.win.update_idletasks()
        _make_noactivate(self.win)

        self._tick()

    def _tick(self):
        if self._destroyed:
            return
        elapsed = time.time() - self.start
        progress = min(1.0, max(0.0, elapsed / max(0.001, self.duration)))
        self._draw(elapsed, progress)

        if elapsed >= self.duration:
            self.destroy()
            if self.on_done:
                self.on_done()
            return
        self.win.after(self.tick_ms, self._tick)

    def destroy(self):
        if self._destroyed:
            return
        self._destroyed = True
        try:
            self.win.destroy()
        except Exception:
            pass

    def _draw(self, elapsed_s, progress):
        c = self.canvas
        c.delete("all")
        elapsed_ms = elapsed_s * 1000.0

        bob = math.sin(elapsed_ms / 260.0) * 2.5
        happy = (self.state == "happy") or (self.state == "acting" and progress > 0.72)
        thinking = self.state == "thinking"

        ground_y = (H - 14) + bob
        leg_len = 26
        hip_y = ground_y - leg_len
        torso_h = 32
        torso_top_y = hip_y - torso_h
        shoulder_y = torso_top_y + 6
        head_w, head_h = 26, 20
        head_bottom_y = torso_top_y - 2
        head_top_y = head_bottom_y - head_h
        head_center_y = (head_top_y + head_bottom_y) / 2

        plate = self.cfg.get("primaryColor", "#4696FF")
        plate_dark = _darken(plate, 0.35)
        plate_light = _lighten(plate, 0.35)
        glow = "#e64646" if self.state == "denied" else self.cfg.get("accentColor", "#FFD166")

        # legs
        for i, side in enumerate((-1, 1)):
            hip_x = CX + side * 9
            phase = elapsed_ms / 260.0 + i * math.pi
            knee_wobble = math.sin(phase) * 2
            knee_x = hip_x + side * 2
            knee_y = hip_y + leg_len / 2 + knee_wobble
            foot_x = hip_x + side * 3
            foot_y = ground_y
            c.create_line(hip_x, hip_y, knee_x, knee_y, fill=plate, width=7, capstyle=tk.ROUND)
            c.create_line(knee_x, knee_y, foot_x, foot_y, fill=plate, width=7, capstyle=tk.ROUND)
            c.create_rectangle(foot_x - 6, foot_y - 2, foot_x + 6, foot_y + 3, fill=plate, outline=plate_dark)

        # torso
        c.create_rectangle(CX - 15, torso_top_y, CX + 15, torso_top_y + torso_h,
                            fill=plate, outline=plate_dark, width=2)
        if self.cfg.get("chestCore", True):
            pulse = 0.5 + 0.5 * math.sin(elapsed_ms / 180.0)
            core_color = _blend(plate, glow, 0.4 + pulse * 0.6)
            c.create_oval(CX - 5, torso_top_y + torso_h / 2 - 5, CX + 5, torso_top_y + torso_h / 2 + 5,
                           fill=core_color, outline="")

        # arms
        for side in (-1, 1):
            is_lead = side > 0
            sx = CX + side * 14
            ex, ey, hx, hy = _arm_offsets(self.state, happy, is_lead)
            elbow_x, elbow_y = sx + side * ex, shoulder_y + ey
            hand_x, hand_y = sx + side * hx, shoulder_y + hy
            c.create_line(sx, shoulder_y, elbow_x, elbow_y, fill=plate, width=6, capstyle=tk.ROUND)
            c.create_line(elbow_x, elbow_y, hand_x, hand_y, fill=plate, width=6, capstyle=tk.ROUND)
            c.create_oval(sx - 3, shoulder_y - 3, sx + 3, shoulder_y + 3, fill=plate_dark, outline="")
            c.create_oval(hand_x - 3, hand_y - 3, hand_x + 3, hand_y + 3, fill=plate_dark, outline="")
            if self.cfg.get("shoulderLights", True):
                c.create_oval(sx - 2, shoulder_y - 2, sx + 2, shoulder_y + 2, fill=glow, outline="")

        # head
        c.create_rectangle(CX - head_w / 2, head_top_y, CX + head_w / 2, head_bottom_y,
                            fill=plate_light, outline=plate_dark, width=2)

        # visor
        visor_alpha = (0.55 + 0.45 * math.sin(elapsed_ms / 150.0)) if thinking else 1.0
        visor_color = _blend("#18181c", glow, visor_alpha)
        vx0, vy0 = CX - head_w / 2 + 4, head_center_y - 3
        vx1, vy1 = CX + head_w / 2 - 4, head_center_y + 3
        c.create_rectangle(vx0, vy0, vx1, vy1, fill=visor_color, outline="")
        c.create_line(CX, vy0, CX, vy1, fill=plate_dark)

        # antenna
        if self.cfg.get("antenna", True):
            ant_top_y = head_top_y - 10
            c.create_line(CX, head_top_y, CX, ant_top_y, fill=plate_dark, width=2)
            tip_pulse = (0.4 + 0.6 * (0.5 + 0.5 * math.sin(elapsed_ms / 150.0))) if thinking else 1.0
            tip_color = _blend("#18181c", glow, tip_pulse)
            c.create_oval(CX - 3, ant_top_y - 3, CX + 3, ant_top_y + 3, fill=tip_color, outline="")

        # thought bubble
        if thinking:
            bx, by = CX + 20, head_top_y - 4
            c.create_oval(bx, by + 14, bx + 6, by + 20, fill="#ffffff", outline="#b4b4be")
            c.create_oval(bx + 5, by + 6, bx + 13, by + 14, fill="#ffffff", outline="#b4b4be")
            brx0, bry0, brx1, bry1 = bx + 10, by - 16, bx + 44, by + 6
            c.create_oval(brx0, bry0, brx1, bry1, fill="#ffffff", outline="#b4b4be")
            dot_y = (bry0 + bry1) / 2 - 2
            for dx in (6, 15, 24):
                c.create_oval(brx0 + dx, dot_y, brx0 + dx + 4, dot_y + 4, fill="#5a5a64", outline="")


def confirm_action(root, message: str) -> bool:
    # A plain messagebox.askyesno() with no parent can open BEHIND other windows (VS Code,
    # a browser, etc.) instead of on top - found live: it silently blocked the whole host
    # (confirm dialogs run on the main thread) with no visible indication why. A topmost,
    # transient anchor window forces the dialog itself to the front, matching the old
    # PowerShell version's explicit TopMost owner form.
    anchor = tk.Toplevel(root)
    anchor.withdraw()
    anchor.attributes("-topmost", True)
    anchor.update_idletasks()
    try:
        result = messagebox.askyesno(
            "Periscope - Confirm Action", f"{message}\n\nAllow this action?", parent=anchor
        )
    finally:
        anchor.destroy()
    return result


def show_toast(root, text: str, duration_ms: int = 1100):
    win = tk.Toplevel(root)
    win.overrideredirect(True)
    win.attributes("-topmost", True)
    win.configure(bg="#202024")
    win.attributes("-alpha", 0.92)
    label = tk.Label(win, text=f"* Periscope:  {text}", fg="#78dc8c", bg="#202024",
                      font=("Segoe UI", 10, "bold"), padx=14, pady=10)
    label.pack()
    win.update_idletasks()
    _make_noactivate(win)

    sw = win.winfo_screenwidth()
    sh = win.winfo_screenheight()
    ww = label.winfo_reqwidth()
    wh = label.winfo_reqheight()
    win.geometry(f"{ww}x{wh}+{sw - ww - 20}+{sh - wh - 60}")

    deadline = time.time() + duration_ms / 1000.0
    while time.time() < deadline:
        root.update()
        time.sleep(0.03)
    try:
        win.destroy()
    except Exception:
        pass


def show_avatar_blocking(root, x, y, state="acting", duration_ms=650, cfg=None):
    aw = AvatarWindow(root, x, y, state=state, duration_ms=duration_ms, cfg=cfg)
    deadline = time.time() + duration_ms / 1000.0
    while time.time() < deadline and not aw._destroyed:
        root.update()
        time.sleep(0.02)
    aw.destroy()


def avatar_default_point(root):
    sw = root.winfo_screenwidth()
    sh = root.winfo_screenheight()
    return {"x": sw - 190, "y": sh - 190}
