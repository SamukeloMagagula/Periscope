param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$ParamsFile
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib.ps1")

$p = @{}
if (Test-Path $ParamsFile) {
    $raw = Get-Content -Raw -Path $ParamsFile
    if ($raw.Trim().Length -gt 0) {
        $json = $raw | ConvertFrom-Json
        $json.PSObject.Properties | ForEach-Object { $p[$_.Name] = $_.Value }
    }
}

function Get-EyesTargetPoint {
    # Where the avatar should appear: at the action's on-screen coordinates if it has any
    # (click/move_mouse), otherwise a fixed default spot.
    if ($p.ContainsKey("x") -and $p.ContainsKey("y")) {
        return @{ x = [int]$p["x"]; y = [int]$p["y"] }
    }
    return Get-EyesAvatarDefaultPoint
}

function Confirm-OrThrow {
    param([string]$Message)
    if ($p.ContainsKey("skipConfirm") -and $p["skipConfirm"]) { return }
    if (Test-EyesAutoTaskActive) { return }
    $pt = Get-EyesTargetPoint
    Show-EyesAvatar -X $pt.x -Y $pt.y -State "thinking" -DurationMs 550
    if (-not (Confirm-EyesAction -Message $Message)) {
        Show-EyesAvatar -X $pt.x -Y $pt.y -State "denied" -DurationMs 500
        throw "User denied the action: $Message"
    }
}

function Show-EyesActingAvatar {
    param([int]$DurationMs = 700)
    if ($p.ContainsKey("skipToast") -and $p["skipToast"]) { return }
    $pt = Get-EyesTargetPoint
    Show-EyesAvatar -X $pt.x -Y $pt.y -State "acting" -DurationMs $DurationMs
}

function Announce {
    # -NoToast: skip the text toast when an acting avatar will follow right after for the same
    # action - showing both is redundant screen clutter and doubles the wall-clock overlay time
    # for no extra information (the HUD log line still always gets written either way).
    param([string]$Message, [switch]$NoToast)
    $auto = Test-EyesAutoTaskActive
    $prefix = if ($auto) { "[auto] " } else { "" }
    Write-EyesLog -Message "$prefix$Message"
    if ($NoToast) { return }
    if ($p.ContainsKey("skipToast") -and $p["skipToast"]) { return }
    Show-EyesToast -Text "$prefix$Message"
}

$result = $null

switch ($Action) {
    "screenshot" {
        Announce "taking screenshot"
        $monitor = if ($p.ContainsKey("monitor")) { [int]$p["monitor"] } else { -1 }
        $result = Invoke-EyesScreenshot -OutPath $p["outPath"] -Monitor $monitor
    }
    "listScreens" {
        $result = Get-EyesScreens
    }
    "moveMouse" {
        Confirm-OrThrow -Message "Move mouse to ($($p['x']), $($p['y']))"
        Announce -NoToast "moving mouse to ($($p['x']), $($p['y']))"
        Show-EyesActingAvatar
        $result = Move-EyesMouse -X ([int]$p["x"]) -Y ([int]$p["y"])
    }
    "click" {
        $btn = if ($p.ContainsKey("button")) { $p["button"] } else { "left" }
        $count = if ($p.ContainsKey("count")) { [int]$p["count"] } else { 1 }
        Confirm-OrThrow -Message "$btn click x$count at ($($p['x']), $($p['y']))"
        Announce -NoToast "$btn click x$count at ($($p['x']), $($p['y']))"
        Show-EyesActingAvatar
        $result = Invoke-EyesClick -X ([int]$p["x"]) -Y ([int]$p["y"]) -Button $btn -Count $count
    }
    "typeText" {
        $preview = $p["text"]
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
        Confirm-OrThrow -Message "Type text: `"$preview`""
        Announce -NoToast "typing: `"$preview`""
        Show-EyesActingAvatar
        $result = Send-EyesText -Text $p["text"]
    }
    "sendKeys" {
        Confirm-OrThrow -Message "Send key combo: $($p['keys'])"
        Announce -NoToast "sending keys: $($p['keys'])"
        Show-EyesActingAvatar
        $result = Send-EyesKeys -Keys $p["keys"]
    }
    "listWindows" {
        $result = Get-EyesWindows
    }
    "focusWindow" {
        Confirm-OrThrow -Message "Focus window (PID $($p['pid']))"
        Announce -NoToast "focusing window (PID $($p['pid']))"
        Show-EyesActingAvatar
        $result = Set-EyesFocusWindow -Pid ([int]$p["pid"])
    }
    "getClipboard" {
        $result = Get-EyesClipboard
    }
    "setClipboard" {
        Confirm-OrThrow -Message "Set clipboard to: `"$($p['text'])`""
        Announce -NoToast "writing clipboard"
        Show-EyesActingAvatar
        $result = Set-EyesClipboard -Text $p["text"]
    }
    "startTask" {
        $minutes = if ($p.ContainsKey("minutes") -and $p["minutes"]) { [int]$p["minutes"] } else { $null }
        $desc = $p["description"]
        $durationText = if ($minutes) { "for up to $minutes minute(s)" } else { "indefinitely, until stopped" }
        Confirm-OrThrow -Message "Allow Periscope to run AUTONOMOUSLY $durationText without per-action confirmation?`n`nTask: $desc"
        $result = Start-EyesAutoTask -Description $desc -Minutes $minutes
        Write-EyesLog -Message "AUTO-TASK STARTED: $desc ($durationText)"
        Show-EyesToast -Text "autonomous task started: $desc" -DurationMs 1800
        $pt = Get-EyesAvatarDefaultPoint
        Show-EyesAvatar -X $pt.x -Y $pt.y -State "happy" -DurationMs 900
    }
    "endTask" {
        $result = Stop-EyesAutoTask
        Write-EyesLog -Message "AUTO-TASK ENDED"
        Show-EyesToast -Text "autonomous task ended"
    }
    default {
        throw "Unknown action: $Action"
    }
}

$result | ConvertTo-Json -Depth 6 -Compress
