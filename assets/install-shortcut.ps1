# Creates (or refreshes) a "Periscope" shortcut on the Desktop that launches assets/host.ps1.
# Run once after `npm install && npm run build` (also runnable via `npm run install-shortcut`).
# Re-running is safe - it just overwrites the existing shortcut.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$hostPs1 = Join-Path $root "assets\host.ps1"

if (-not (Test-Path $hostPs1)) {
    throw "assets\host.ps1 not found under $root - run this from the Periscope project."
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop "Periscope.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hostPs1`""
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 1  # Normal - host.ps1 hides its own console window via a direct
                           # Win32 call once it's running (Hide-EyesConsoleWindow). Neither
                           # "-WindowStyle Hidden" nor a Minimized shortcut work here: both
                           # were found to also affect GUI windows created later in the
                           # process (fully suppressed / started minimized, respectively).
$shortcut.Description = "Periscope - double-click to start, click the robot to open Claude/Copilot"
$shortcut.Save()

Write-Output "Created shortcut: $shortcutPath"
