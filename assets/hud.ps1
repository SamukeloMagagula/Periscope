# Standalone HUD entry point (npm run hud), for when you want just the activity panel
# without the full host (e.g. the persistent host from the desktop icon already includes
# its own HUD - this is only needed if you closed that one and want it back separately).
# Single-instance (named mutex) so repeated launches don't spawn duplicates.

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib.ps1")
. (Join-Path $here "hud-lib.ps1")

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PeriscopeHud", [ref]$mutexCreated)
if (-not $mutexCreated) { exit }

$form = New-EyesHudForm
[System.Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
