# Periscope host: the persistent background process launched by double-clicking the
# "Periscope" desktop icon. It owns everything that used to require spawning a fresh
# powershell.exe per MCP tool call:
#
#   - all the actual screen/mouse/keyboard/window/clipboard work (dispatch.ps1), now running
#     in a long-lived process so .NET types compile ONCE at startup instead of once per call
#   - a named pipe server the MCP server (src/powershell.ts) connects to for each action,
#     instead of spawning a process
#   - a localhost web dashboard (no floating always-on-top window) showing live activity
#   - a system tray icon: the "is it running" indicator and the one reliable way to exit
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
. (Join-Path $here "dashboard-lib.ps1")

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PeriscopeHost", [ref]$mutexCreated)
if (-not $mutexCreated) {
    Show-EyesLauncherPicker
    exit
}

# Defense in depth: if any future bug throws inside a WinForms event handler (as the HUD's
# Timer.Add_Tick once did - see the fixed closure bug in git history), this catches it and
# logs it instead of showing the native "Unhandled exception has occurred" crash dialog that
# blocks all interaction until dismissed, sometimes repeatedly.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($exSender, $exArgs)
    try { Write-EyesLog -Message "UI ERROR (recovered): $($exArgs.Exception.Message)" } catch {}
})

Hide-EyesConsoleWindow

$DashboardPort = 51823
$DashboardUrl = "http://localhost:$DashboardPort/"

function Stop-EyesHost {
    try { if ($listener) { $listener.Stop(); $listener.Close() } } catch {}
    try { $trayIcon.Visible = $false } catch {}
    try { $idleAvatar.Close() } catch {}
    [System.Environment]::Exit(0)
}

# --- System tray icon: the "is it running" indicator and the documented way to exit ---
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Application
$trayIcon.Text = "Periscope - right-click to exit"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $trayMenu.Items.Add("Open activity dashboard")
$exitItem = $trayMenu.Items.Add("Exit Periscope")
$trayIcon.ContextMenuStrip = $trayMenu

$openItem.Add_Click({ Start-Process $DashboardUrl }.GetNewClosure())
$exitItem.Add_Click({ Stop-EyesHost }.GetNewClosure())
$trayIcon.Add_DoubleClick({ Start-Process $DashboardUrl }.GetNewClosure())

# --- Idle, clickable avatar: click opens the Claude Desktop / claude.ai picker ---
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

# --- Localhost dashboard (no admin rights needed: "localhost" prefix, not a wildcard) ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($DashboardUrl)
$listener.Start()
$httpWait = $listener.BeginGetContext($null, $null)

Write-EyesLog -Message "Periscope is running - click the robot to launch Claude Desktop or claude.ai. Dashboard: $DashboardUrl"

# --- Named pipe server: every MCP tool call arrives here instead of spawning a process ---
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
    try {
        if ($httpWait.IsCompleted) {
            $context = $listener.EndGetContext($httpWait)
            Invoke-EyesDashboardRequest -Context $context
            $httpWait = $listener.BeginGetContext($null, $null)
        }

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
    } catch {
        try { Write-EyesLog -Message "HOST ERROR (recovered): $($_.Exception.Message)" } catch {}
    }

    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 20
}
