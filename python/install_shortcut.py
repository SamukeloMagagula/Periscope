"""Creates (or refreshes) a "Periscope" shortcut on the Desktop that launches host.py with
pythonw.exe - no console window, ever (unlike the old PowerShell approach, which had to hide
its console after the fact). Run once after pip install -r python/requirements.txt (also
runnable via `npm run install-shortcut`). Re-running is safe - it just overwrites the shortcut.
"""
import sys
from pathlib import Path

import win32com.client

ROOT = Path(__file__).resolve().parent.parent
HOST_PY = ROOT / "python" / "host.py"


def _pythonw_path() -> str:
    exe = Path(sys.executable)
    candidate = exe.parent / "pythonw.exe"
    return str(candidate if candidate.exists() else exe)


def main():
    if not HOST_PY.exists():
        raise SystemExit(f"python/host.py not found under {ROOT} - run this from the Periscope project.")

    desktop = Path(win32com.client.Dispatch("WScript.Shell").SpecialFolders("Desktop"))
    shortcut_path = desktop / "Periscope.lnk"

    shell = win32com.client.Dispatch("WScript.Shell")
    shortcut = shell.CreateShortCut(str(shortcut_path))
    shortcut.TargetPath = _pythonw_path()
    shortcut.Arguments = f'"{HOST_PY}"'
    shortcut.WorkingDirectory = str(ROOT)
    shortcut.Description = "Periscope - double-click to start, click the robot to open Claude/Copilot"
    shortcut.Save()

    print(f"Created shortcut: {shortcut_path}")


if __name__ == "__main__":
    main()
