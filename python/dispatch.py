"""Maps an action name + params to its implementation: confirm dialog, avatar, activity
logging, then the actual Win32 call. Mirrors the old assets/dispatch.ps1 one-for-one.
Runs on the Tkinter main thread (see host.py's queue bridge) since it shows GUI.
"""
import state
import win32_input as w32
from avatar import avatar_default_point, confirm_action, show_avatar_blocking, show_toast


class ActionDenied(Exception):
    pass


class ActionBlocked(Exception):
    pass


def _check_scope(process_name: str, action_desc: str):
    # Absolute guardrail: checked unconditionally, before confirm/auto-task logic, and not
    # skippable via skipConfirm or an active autonomous task - the point of a blocklist is
    # that it applies regardless of anything else, not something a running task can bypass.
    if not process_name:
        return
    scope_cfg = state.get_scope_config()
    if process_name.lower() in scope_cfg["blockedProcesses"]:
        raise ActionBlocked(
            f"Blocked by Periscope scope policy: {action_desc} targets '{process_name}', "
            f"which is on the blocklist (assets/scope.config.json)."
        )


def _target_point(root, params):
    if "x" in params and "y" in params:
        return {"x": int(params["x"]), "y": int(params["y"])}
    return avatar_default_point(root)


def _confirm_or_raise(root, cfg, params, message):
    if params.get("skipConfirm"):
        return
    if state.is_auto_task_active():
        return
    pt = _target_point(root, params)
    show_avatar_blocking(root, pt["x"], pt["y"], state="thinking", duration_ms=550, cfg=cfg)
    if not confirm_action(root, message):
        show_avatar_blocking(root, pt["x"], pt["y"], state="denied", duration_ms=500, cfg=cfg)
        raise ActionDenied(f"User denied the action: {message}")


def _announce(root, params, message, no_toast=False):
    # no_toast: skip the text toast when an acting avatar will follow right after for the same
    # action - showing both is redundant screen clutter and doubles wall-clock overlay time.
    auto = state.is_auto_task_active()
    prefix = "[auto] " if auto else ""
    state.write_log(prefix + message)
    if no_toast or params.get("skipToast"):
        return
    show_toast(root, prefix + message)


def _acting_avatar(root, cfg, params, duration_ms=700):
    if params.get("skipToast"):
        return
    pt = _target_point(root, params)
    show_avatar_blocking(root, pt["x"], pt["y"], state="acting", duration_ms=duration_ms, cfg=cfg)


def _enforce_action_budget(root):
    # Only relevant while a task is actually active - a one-off confirmed action outside
    # start_task has no budget to enforce against. Checked right before the Win32 call, after
    # confirm/scope have already passed, so a budget-exhausted action never executes.
    if not state.is_auto_task_active():
        return
    status, count, max_actions = state.register_auto_action()
    if status == "limit_reached":
        raise ActionDenied(
            f"Autonomous task already reached its action limit ({max_actions}) on a prior "
            f"action and was stopped - this action did not run. Start a new task to continue."
        )
    if status == "ended":
        state.write_log(f"AUTO-TASK ENDED: reached its action limit ({count}/{max_actions})")
        show_toast(root, f"autonomous task ended: hit its {max_actions}-action limit", duration_ms=1800)


def dispatch(root, cfg, action: str, params: dict):
    p = params or {}

    if action == "screenshot":
        _announce(root, p, "taking screenshot")
        monitor = p.get("monitor")
        return w32.screenshot(p["outPath"], int(monitor) if monitor is not None else None)

    if action == "listScreens":
        return w32.list_screens()

    if action == "moveMouse":
        msg = f"Move mouse to ({p['x']}, {p['y']})"
        _confirm_or_raise(root, cfg, p, msg)
        _enforce_action_budget(root)
        _announce(root, p, f"moving mouse to ({p['x']}, {p['y']})", no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.move_mouse(int(p["x"]), int(p["y"]))

    if action == "click":
        btn = p.get("button", "left")
        count = int(p.get("count", 1))
        msg = f"{btn} click x{count} at ({p['x']}, {p['y']})"
        _check_scope(w32.process_at_point(int(p["x"]), int(p["y"])), msg)
        _confirm_or_raise(root, cfg, p, msg)
        _enforce_action_budget(root)
        _announce(root, p, msg, no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.click(int(p["x"]), int(p["y"]), button=btn, count=count)

    if action == "typeText":
        text = p["text"]
        preview = text if len(text) <= 120 else text[:120] + "..."
        _check_scope(w32.focused_process_name(), f'typing text: "{preview}"')
        _confirm_or_raise(root, cfg, p, f'Type text: "{preview}"')
        _enforce_action_budget(root)
        _announce(root, p, f'typing: "{preview}"', no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.type_text(text)

    if action == "sendKeys":
        keys = p["keys"]
        _check_scope(w32.focused_process_name(), f"sending keys: {keys}")
        _confirm_or_raise(root, cfg, p, f"Send key combo: {keys}")
        _enforce_action_budget(root)
        _announce(root, p, f"sending keys: {keys}", no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.send_keys(keys)

    if action == "listWindows":
        return w32.list_windows()

    if action == "focusWindow":
        pid = int(p["pid"])
        _check_scope(w32.get_process_name(pid), f"focusing window (PID {pid})")
        _confirm_or_raise(root, cfg, p, f"Focus window (PID {pid})")
        _enforce_action_budget(root)
        _announce(root, p, f"focusing window (PID {pid})", no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.focus_window(pid)

    if action == "getClipboard":
        return w32.get_clipboard()

    if action == "setClipboard":
        text = p["text"]
        _confirm_or_raise(root, cfg, p, f'Set clipboard to: "{text}"')
        _enforce_action_budget(root)
        _announce(root, p, "writing clipboard", no_toast=True)
        _acting_avatar(root, cfg, p)
        return w32.set_clipboard(text)

    if action == "startTask":
        minutes = p.get("minutes")
        minutes = int(minutes) if minutes else None
        max_actions = p.get("maxActions")
        max_actions = int(max_actions) if max_actions else None
        desc = p["description"]
        duration_text = f"for up to {minutes} minute(s)" if minutes else "indefinitely, until stopped"
        budget_text = f", capped at {max_actions} action(s)" if max_actions else ""
        _confirm_or_raise(
            root, cfg, p,
            f"Allow Periscope to run AUTONOMOUSLY {duration_text}{budget_text} without per-action confirmation?\n\nTask: {desc}",
        )
        result = state.start_auto_task(desc, minutes, max_actions)
        state.write_log(f"AUTO-TASK STARTED: {desc} ({duration_text}{budget_text})")
        show_toast(root, f"autonomous task started: {desc}", duration_ms=1800)
        pt = avatar_default_point(root)
        show_avatar_blocking(root, pt["x"], pt["y"], state="happy", duration_ms=900, cfg=cfg)
        return result

    if action == "endTask":
        result = state.stop_auto_task()
        state.write_log("AUTO-TASK ENDED")
        show_toast(root, "autonomous task ended")
        return result

    raise ValueError(f"Unknown action: {action}")
