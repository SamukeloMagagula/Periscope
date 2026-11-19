# Periscope HUD: a small persistent always-on-top panel showing a live narration log
# of every action, plus the current autonomous-task status with a one-click stop button.
# Single-instance (named mutex) so repeated MCP server restarts don't spawn duplicates.

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib.ps1")

$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\PeriscopeHud", [ref]$mutexCreated)
if (-not $mutexCreated) { exit }

$form = New-Object System.Windows.Forms.Form
$form.Text = "Periscope - Activity"
$form.Size = New-Object System.Drawing.Size(360, 420)
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(($screen.Right - 380), 20)
$form.TopMost = $true
$form.FormBorderStyle = "FixedToolWindow"
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)

$status = New-Object System.Windows.Forms.Label
$status.Text = "*  Idle"
$status.ForeColor = [System.Drawing.Color]::Gray
$status.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$status.Dock = "Top"
$status.Height = 32
$status.TextAlign = "MiddleLeft"
$status.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$form.Controls.Add($status)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = "Stop autonomous task"
$stopBtn.Dock = "Top"
$stopBtn.Height = 30
$stopBtn.Visible = $false
$stopBtn.BackColor = [System.Drawing.Color]::FromArgb(140, 40, 40)
$stopBtn.ForeColor = [System.Drawing.Color]::White
$stopBtn.FlatStyle = "Flat"
$form.Controls.Add($stopBtn)

$log = New-Object System.Windows.Forms.RichTextBox
$log.Dock = "Fill"
$log.ReadOnly = $true
$log.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 20)
$log.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
$log.Font = New-Object System.Drawing.Font("Consolas", 9)
$log.BorderStyle = "None"
$form.Controls.Add($log)

$form.Controls.SetChildIndex($log, 0)
$form.Controls.SetChildIndex($stopBtn, 1)
$form.Controls.SetChildIndex($status, 2)

$stopBtn.Add_Click({
    Stop-EyesAutoTask | Out-Null
    Write-EyesLog -Message "AUTO-TASK STOPPED from HUD"
})

$lastLength = 0
if (Test-Path $EyesLogPath) { $lastLength = (Get-Item $EyesLogPath).Length }

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    try {
        if (Test-Path $EyesLogPath) {
            $fileLen = (Get-Item $EyesLogPath).Length
            if ($fileLen -lt $lastLength) { $lastLength = 0 }
            if ($fileLen -gt $lastLength) {
                $fs = [System.IO.File]::Open($EyesLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                [void]$fs.Seek($lastLength, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs)
                $newText = $reader.ReadToEnd()
                $reader.Close()
                $fs.Close()
                $lastLength = $fileLen

                foreach ($line in ($newText -split "`n")) {
                    $line = $line.Trim()
                    if ($line.Length -eq 0) { continue }
                    try {
                        $obj = $line | ConvertFrom-Json
                        $time = ([DateTime]$obj.ts).ToLocalTime().ToString("HH:mm:ss")
                        $log.AppendText("[$time] $($obj.message)`n")
                    } catch {}
                }
                if ($log.Lines.Length -gt 300) {
                    $log.Lines = $log.Lines[-200..-1]
                }
                $log.SelectionStart = $log.Text.Length
                $log.ScrollToCaret()
            }
        }

        if (Test-EyesAutoTaskActive) {
            $info = Get-EyesTaskInfo
            $status.Text = "*  AUTO: $($info.description)"
            $status.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140)
            $stopBtn.Visible = $true
        } else {
            $status.Text = "*  Idle"
            $status.ForeColor = [System.Drawing.Color]::Gray
            $stopBtn.Visible = $false
        }
    } catch {}
})
$timer.Start()

$form.Add_FormClosing({ $timer.Stop() })
[void]$form.ShowDialog()
$mutex.ReleaseMutex()
