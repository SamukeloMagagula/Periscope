# Standalone launcher entry point (npm run launch / Launch Periscope.cmd). Equivalent to
# clicking the idle avatar once host.ps1 is running - both call Show-EyesLauncherPicker.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "launcher-lib.ps1")
Show-EyesLauncherPicker
