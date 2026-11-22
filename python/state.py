"""Shared state: activity log, autonomous-task status, avatar position/config.

Mirrors the equivalent helpers from the old assets/lib.ps1 - same file locations and JSON
shapes, so nothing else about the on-disk state format changed during the PowerShell -> Python
rewrite.
"""
import json
import os
import tempfile
import threading
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


_log_cache_lock = threading.Lock()
_log_cache = {"offset": 0, "entries": [], "partial": ""}


def read_log_tail(n: int = 300):
    # Incremental: the log file is never rotated/truncated, so on a long-running host it only
    # grows. Re-reading and re-parsing the whole thing on every dashboard poll (every ~1s while
    # a tab is open) gets slower the longer the session runs for no reason - only the bytes
    # written since the last call are new. Guarded by a lock since the dashboard's
    # ThreadingHTTPServer can call this from multiple request threads concurrently.
    if not LOG_PATH.exists():
        with _log_cache_lock:
            _log_cache.update(offset=0, entries=[], partial="")
        return []

    with _log_cache_lock:
        try:
            size = LOG_PATH.stat().st_size
        except OSError:
            return list(_log_cache["entries"][-n:])

        if size < _log_cache["offset"]:
            _log_cache.update(offset=0, entries=[], partial="")

        if size > _log_cache["offset"]:
            with open(LOG_PATH, "rb") as f:
                f.seek(_log_cache["offset"])
                chunk = f.read()
            _log_cache["offset"] += len(chunk)
            text = _log_cache["partial"] + chunk.decode("utf-8", errors="replace")
            lines = text.split("\n")
            _log_cache["partial"] = lines[-1]
            for line in lines[:-1]:
                line = line.strip()
                if not line:
                    continue
                try:
                    _log_cache["entries"].append(json.loads(line))
                except json.JSONDecodeError:
                    continue
            if len(_log_cache["entries"]) > n:
                _log_cache["entries"] = _log_cache["entries"][-n:]

        return list(_log_cache["entries"][-n:])


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


_config_cache_lock = threading.Lock()
_config_cache: dict = {}  # path -> {"mtime": float, "value": dict}


def _load_config_cached(path: Path, default: dict, parse_fn):
    # avatar.config.json / scope.config.json are read before every single avatar popup / scope
    # check so edits apply immediately with no restart - but re-reading and re-parsing JSON on
    # every action when the file hasn't changed since the last check is wasted work. An mtime
    # check (cheap: one stat() syscall) skips the actual read+parse when nothing changed, while
    # still picking up edits as soon as the file's mtime moves.
    with _config_cache_lock:
        if not path.exists():
            return dict(default)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            return dict(default)

        cached = _config_cache.get(path)
        if cached and cached["mtime"] == mtime:
            return dict(cached["value"])

        try:
            with open(path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            value = parse_fn(raw)
        except (OSError, json.JSONDecodeError):
            value = dict(default)

        _config_cache[path] = {"mtime": mtime, "value": value}
        return dict(value)


def get_avatar_config():
    def parse(raw):
        cfg = dict(DEFAULT_AVATAR_CONFIG)
        for key in ("primaryColor", "accentColor"):
            if raw.get(key):
                cfg[key] = raw[key]
        for key in ("antenna", "shoulderLights", "chestCore"):
            if key in raw:
                cfg[key] = bool(raw[key])
        return cfg

    return _load_config_cached(AVATAR_CONFIG_PATH, DEFAULT_AVATAR_CONFIG, parse)


def get_scope_config():
    def parse(raw):
        cfg = {"blockedProcesses": []}
        processes = raw.get("blockedProcesses")
        if isinstance(processes, list):
            cfg["blockedProcesses"] = [str(p).strip().lower() for p in processes if str(p).strip()]
        return cfg

    return _load_config_cached(SCOPE_CONFIG_PATH, {"blockedProcesses": []}, parse)
