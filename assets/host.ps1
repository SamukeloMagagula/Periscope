# Periscope host: the persistent background process launched by double-clicking the
# "Periscope" desktop icon. It owns everything that used to require spawning a fresh
# powershell.exe per MCP tool call:
#
#   - all the actual screen/mouse/keyboard/window/clipboard work (dispatch.ps1), now running
#     in a long-lived process so .NET types compile ONCE at startup instead of once per call
#   - a named pipe server the MCP server (src/powershell.ts) connects to for each action,
#     instead of spawning a process
#   - the activity HUD panel
#   - an idle, clickable avatar ("the bot") that sits on screen until clicked, at which point
#     it opens the Claude Desktop / claude.ai picker, then hides; it reappears briefly during
#     each action exactly as before
#
# Single-instance via a named mutex: double-clicking the desktop icon again while this is
# already running just reopens the picker instead of starting a second host.

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib.ps1")
. (Join-Path $here "dispatch.ps1")
. (Join-Path $here "launcher-lib.ps1")
. (Join-Path $here "hud-lib.ps1")

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PeriscopeHost", [ref]$mutexCreated)
if (-not $mutexCreated) {
    Show-EyesLauncherPicker
    exit
}

Hide-EyesConsoleWindow

$hudForm = New-EyesHudForm
# Closing the HUD panel is the documented way to shut Periscope down - without this, the pipe
# server and idle avatar would keep running invisibly in the background after the one visible
# window disappears, which would be confusing (no obvious way to tell it's still running).
$hudForm.Add_FormClosing({
    [System.Environment]::Exit(0)
})

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$idleX = [int]($screen.Width / 2)
$idleY = [int]($screen.Height / 2)
$cfg = Get-EyesAvatarConfig

$idleAvatar = New-Object ClaudeEyes.AvatarForm
$idleAvatar.FormBorderStyle = "None"
$idleAvatar.StartPosition = "Manual"
$idleAvatar.TopMost = $true
$idleAvatar.ShowInTaskbar = $false
$idleAvatar.Size = New-Object System.Drawing.Size(170, 150)
$idleAvatar.Location = New-Object System.Drawing.Point(($idleX - 60), ($idleY - 136))
$idleAvatar.BackColor = [System.Drawing.Color]::Magenta
$idleAvatar.TransparencyKey = [System.Drawing.Color]::Magenta
$idleAvatar.State = "idle"
$idleAvatar.StartTicks = [DateTime]::Now.Ticks
$idleAvatar.TotalMs = 999999999
$idleAvatar.PrimaryColor = ConvertFrom-EyesHexColor -Hex $cfg.primaryColor -FallbackColor ([System.Drawing.Color]::FromArgb(70, 160, 255))
$idleAvatar.AccentColor = ConvertFrom-EyesHexColor -Hex $cfg.accentColor -FallbackColor ([System.Drawing.Color]::FromArgb(255, 209, 102))
$idleAvatar.AntennaEnabled = [bool]$cfg.antenna
$idleAvatar.ShoulderLightsEnabled = [bool]$cfg.shoulderLights
$idleAvatar.ChestCoreEnabled = [bool]$cfg.chestCore
$idleAvatar.Cursor = [System.Windows.Forms.Cursors]::Hand

$idleAvatar.Add_Click({
    $idleAvatar.Hide()
    Show-EyesLauncherPicker
    $idleAvatar.Close()
}.GetNewClosure())
$idleAvatar.Show()

Write-EyesLog -Message "Periscope is running - click the robot to launch Claude Desktop or claude.ai"

function New-EyesPipeServer {
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
        "PeriscopeActionPipe",
        [System.IO.Pipes.PipeDirection]::InOut,
        4,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    $wait = $pipe.BeginWaitForConnection($null, $null)
    return @{ pipe = $pipe; wait = $wait }
}

$server = New-EyesPipeServer

while ($true) {
    if ($server.wait.IsCompleted) {
        try {
            $server.pipe.EndWaitForConnection($server.wait)
            $reader = New-Object System.IO.StreamReader($server.pipe)
            $writer = New-Object System.IO.StreamWriter($server.pipe)
            $writer.AutoFlush = $true
            $line = $reader.ReadLine()

            try {
                $req = $line | ConvertFrom-Json
                $pHash = @{}
                if ($req.params) {
                    $req.params.PSObject.Properties | ForEach-Object { $pHash[$_.Name] = $_.Value }
                }
                $result = Invoke-EyesAction -Action $req.action -P $pHash
                $response = @{ ok = $true; result = $result } | ConvertTo-Json -Depth 8 -Compress
            } catch {
                $msg = $_.Exception.Message
                $denied = $msg -like "User denied the action:*"
                $response = @{ ok = $false; error = $msg; denied = $denied } | ConvertTo-Json -Compress
            }

            $writer.WriteLine($response)
        } catch {
            # client disconnected early or similar pipe-level hiccup - drop this connection
            # and keep serving; nothing to report back to a client that's already gone.
        } finally {
            try { $server.pipe.Disconnect() } catch {}
            $server.pipe.Dispose()
        }
        $server = New-EyesPipeServer
    }

    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}
