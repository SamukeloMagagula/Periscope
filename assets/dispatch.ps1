# Periscope - action dispatch. Dot-sourced after lib.ps1 by both run.ps1 (standalone,
# one action per process invocation) and host.ps1 (persistent, every action in-process over
# the named pipe). Keeping this in one place means both callers share identical behavior.

function Invoke-EyesAction {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][hashtable]$P
    )

    function Get-EyesTargetPoint {
        # Where the avatar should appear: at the action's on-screen coordinates if it has any
        # (click/move_mouse), otherwise a fixed default spot.
        if ($P.ContainsKey("x") -and $P.ContainsKey("y")) {
            return @{ x = [int]$P["x"]; y = [int]$P["y"] }
        }
        return Get-EyesAvatarDefaultPoint
    }

    function Confirm-OrThrow {
        param([string]$Message)
        if ($P.ContainsKey("skipConfirm") -and $P["skipConfirm"]) { return }
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
        if ($P.ContainsKey("skipToast") -and $P["skipToast"]) { return }
        $pt = Get-EyesTargetPoint
        Show-EyesAvatar -X $pt.x -Y $pt.y -State "acting" -DurationMs $DurationMs
    }

    function Announce {
        # -NoToast: skip the text toast when an acting avatar will follow right after for the
        # same action - showing both is redundant screen clutter and doubles the wall-clock
        # overlay time for no extra information (the HUD log line still always gets written).
        param([string]$Message, [switch]$NoToast)
        $auto = Test-EyesAutoTaskActive
        $prefix = if ($auto) { "[auto] " } else { "" }
        Write-EyesLog -Message "$prefix$Message"
        if ($NoToast) { return }
        if ($P.ContainsKey("skipToast") -and $P["skipToast"]) { return }
        Show-EyesToast -Text "$prefix$Message"
    }

    $result = $null

    switch ($Action) {
        "screenshot" {
            Announce "taking screenshot"
            $monitor = if ($P.ContainsKey("monitor")) { [int]$P["monitor"] } else { -1 }
            $result = Invoke-EyesScreenshot -OutPath $P["outPath"] -Monitor $monitor
        }
        "listScreens" {
            $result = Get-EyesScreens
        }
        "moveMouse" {
            Confirm-OrThrow -Message "Move mouse to ($($P['x']), $($P['y']))"
            Announce -NoToast "moving mouse to ($($P['x']), $($P['y']))"
            Show-EyesActingAvatar
            $result = Move-EyesMouse -X ([int]$P["x"]) -Y ([int]$P["y"])
        }
        "click" {
            $btn = if ($P.ContainsKey("button")) { $P["button"] } else { "left" }
            $count = if ($P.ContainsKey("count")) { [int]$P["count"] } else { 1 }
            Confirm-OrThrow -Message "$btn click x$count at ($($P['x']), $($P['y']))"
            Announce -NoToast "$btn click x$count at ($($P['x']), $($P['y']))"
            Show-EyesActingAvatar
            $result = Invoke-EyesClick -X ([int]$P["x"]) -Y ([int]$P["y"]) -Button $btn -Count $count
        }
        "typeText" {
            $preview = $P["text"]
            if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + "..." }
            Confirm-OrThrow -Message "Type text: `"$preview`""
            Announce -NoToast "typing: `"$preview`""
            Show-EyesActingAvatar
            $result = Send-EyesText -Text $P["text"]
        }
        "sendKeys" {
            Confirm-OrThrow -Message "Send key combo: $($P['keys'])"
            Announce -NoToast "sending keys: $($P['keys'])"
            Show-EyesActingAvatar
            $result = Send-EyesKeys -Keys $P["keys"]
        }
        "listWindows" {
            $result = Get-EyesWindows
        }
        "focusWindow" {
            Confirm-OrThrow -Message "Focus window (PID $($P['pid']))"
            Announce -NoToast "focusing window (PID $($P['pid']))"
            Show-EyesActingAvatar
            $result = Set-EyesFocusWindow -Pid ([int]$P["pid"])
        }
        "getClipboard" {
            $result = Get-EyesClipboard
        }
        "setClipboard" {
            Confirm-OrThrow -Message "Set clipboard to: `"$($P['text'])`""
            Announce -NoToast "writing clipboard"
            Show-EyesActingAvatar
            $result = Set-EyesClipboard -Text $P["text"]
        }
        "startTask" {
            $minutes = if ($P.ContainsKey("minutes") -and $P["minutes"]) { [int]$P["minutes"] } else { $null }
            $desc = $P["description"]
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

    return $result
}
