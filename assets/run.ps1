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

function Confirm-OrThrow {
    param([string]$Message)
    if ($p.ContainsKey("skipConfirm") -and $p["skipConfirm"]) { return }
    if (Test-EyesAutoTaskActive) { return }
    if (-not (Confirm-EyesAction -Message $Message)) {
        throw "User denied the action: $Message"
    }
}

function Announce {
    param([string]$Message)
    $auto = Test-EyesAutoTaskActive
    $prefix = if ($auto) { "[auto] " } else { "" }
    Write-EyesLog -Message "$prefix$Message"
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
        Announce "moving mouse to ($($p['x']), $($p['y']))"
        Show-EyesCursorRing -X ([int]$p["x"]) -Y ([int]$p["y"])
        $result = Move-EyesMouse -X ([int]$p["x"]) -Y ([int]$p["y"])
    }
    "click" {
        $btn = if ($p.ContainsKey("button")) { $p["button"] } else { "left" }
        $count = if ($p.ContainsKey("count")) { [int]$p["count"] } else { 1 }
        Confirm-OrThrow -Message "$btn click x$count at ($($p['x']), $($p['y']))"
        Announce "$btn click x$count at ($($p['x']), $($p['y']))"
        Show-EyesCursorRing -X ([int]$p["x"]) -Y ([int]$p["y"])
        $result = Invoke-EyesClick -X ([int]$p["x"]) -Y ([int]$p["y"]) -Button $btn -Count $count
    }
    "typeText" {
        $preview = $p["text"]
        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
        Confirm-OrThrow -Message "Type text: `"$preview`""
        Announce "typing: `"$preview`""
        $result = Send-EyesText -Text $p["text"]
    }
    "sendKeys" {
        Confirm-OrThrow -Message "Send key combo: $($p['keys'])"
        Announce "sending keys: $($p['keys'])"
        $result = Send-EyesKeys -Keys $p["keys"]
    }
    "listWindows" {
        $result = Get-EyesWindows
    }
    "focusWindow" {
        Confirm-OrThrow -Message "Focus window (PID $($p['pid']))"
        Announce "focusing window (PID $($p['pid']))"
        $result = Set-EyesFocusWindow -Pid ([int]$p["pid"])
    }
    "getClipboard" {
        $result = Get-EyesClipboard
    }
    "setClipboard" {
        Confirm-OrThrow -Message "Set clipboard to: `"$($p['text'])`""
        Announce "writing clipboard"
        $result = Set-EyesClipboard -Text $p["text"]
    }
    "startTask" {
        $minutes = if ($p.ContainsKey("minutes")) { [int]$p["minutes"] } else { 10 }
        $desc = $p["description"]
        Confirm-OrThrow -Message "Allow Periscope to run AUTONOMOUSLY for up to $minutes minute(s) without per-action confirmation?`n`nTask: $desc"
        $result = Start-EyesAutoTask -Description $desc -Minutes $minutes
        Write-EyesLog -Message "AUTO-TASK STARTED: $desc (up to $minutes min)"
        Show-EyesToast -Text "autonomous task started: $desc" -DurationMs 1800
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
