"""Shared state: activity log, autonomous-task status, avatar position/config.

Mirrors the equivalent helpers from the old assets/lib.ps1 - same file locations and JSON
shapes, so nothing else about the on-disk state format changed during the PowerShell -> Python
rewrite.
"""
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

TEMP_DIR = Path(tempfile.gettempdir())
LOG_PATH = TEMP_DIR / "periscope-activity.log"
TASK_PATH = TEMP_DIR / "periscope-task.json"
AVATAR_POS_PATH = TEMP_DIR / "periscope-avatar-pos.json"

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
AVATAR_CONFIG_PATH = ASSETS_DIR / "avatar.config.json"
SCOPE_CONFIG_PATH = ASSETS_DIR / "scope.config.json"

DEFAULT_SCOPE_CONFIG = {
    "blockedProcesses": [],
}

DEFAULT_AVATAR_CONFIG = {
    "primaryColor": "#4696FF",
    "accentColor": "#FFD166",
    "antenna": True,
    "shoulderLights": True,
    "chestCore": True,
}


def write_log(message: str) -> None:
    entry = {"ts": datetime.now(timezone.utc).astimezone().isoformat(), "message": message}
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def read_log_tail(n: int = 300):
    if not LOG_PATH.exists():
        return []
    entries = []
    with open(LOG_PATH, "r", encoding="utf-8") as f:
        lines = f.readlines()[-n:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def is_auto_task_active() -> bool:
    if not TASK_PATH.exists():
        return False
    try:
        with open(TASK_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        expiry = datetime.fromisoformat(data["expiry"])
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        if datetime.now(timezone.utc) < expiry:
            return True
        try:
            os.remove(TASK_PATH)
        except OSError:
            pass
        return False
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def get_task_info():
    if not is_auto_task_active():
        return None
    try:
        with open(TASK_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def start_auto_task(description: str, minutes: int | None):
    from datetime import timedelta

    indefinite = not minutes
    if minutes and minutes < 1:
        minutes = 1
    expiry = (
        datetime.max.replace(tzinfo=timezone.utc)
        if indefinite
        else datetime.now(timezone.utc) + timedelta(minutes=minutes)
    )
    data = {"description": description, "expiry": expiry.isoformat(), "indefinite": indefinite}
    with open(TASK_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f)
    return {"started": True, **data}


def stop_auto_task():
    try:
        os.remove(TASK_PATH)
    except OSError:
        pass
    return {"ended": True}


def get_avatar_position():
    if not AVATAR_POS_PATH.exists():
        return None
    try:
        with open(AVATAR_POS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return {"x": int(data["x"]), "y": int(data["y"])}
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return None


def save_avatar_position(x: int, y: int):
    with open(AVATAR_POS_PATH, "w", encoding="utf-8") as f:
        json.dump({"x": x, "y": y}, f)


def get_avatar_config():
    cfg = dict(DEFAULT_AVATAR_CONFIG)
    if AVATAR_CONFIG_PATH.exists():
        try:
            with open(AVATAR_CONFIG_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
            for key in ("primaryColor", "accentColor"):
                if raw.get(key):
                    cfg[key] = raw[key]
            for key in ("antenna", "shoulderLights", "chestCore"):
                if key in raw:
                    cfg[key] = bool(raw[key])
        except (OSError, json.JSONDecodeError):
            pass
    return cfg


def get_scope_config():
    # Read fresh on every action (same pattern as avatar config) so edits to the blocklist
    # apply immediately - no rebuild, no host restart needed.
    cfg = {"blockedProcesses": []}
    if SCOPE_CONFIG_PATH.exists():
        try:
            with open(SCOPE_CONFIG_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
            processes = raw.get("blockedProcesses")
            if isinstance(processes, list):
                cfg["blockedProcesses"] = [str(p).strip().lower() for p in processes if str(p).strip()]
        except (OSError, json.JSONDecodeError):
            pass
    return cfg
