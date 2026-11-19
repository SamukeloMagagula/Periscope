# Builds the HUD panel: a small always-on-top window showing a live narration log of every
# action plus autonomous-task status with a one-click stop button. Returns the form already
# Show()n (non-modal) with its own internal Timer driving log-tailing - the caller just needs
# to keep pumping the Windows message loop (Application.DoEvents() or Application.Run).

function New-EyesHudForm {
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
    }.GetNewClosure())

    $eyesHudLastLength = 0
    if (Test-Path $EyesLogPath) { $eyesHudLastLength = (Get-Item $EyesLogPath).Length }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    # .GetNewClosure() is required here: this scriptblock is defined inside a function
    # (New-EyesHudForm), and .NET event handler scriptblocks don't reliably see a function's
    # local variables ($EyesLogPath, $log, $status, $stopBtn, $eyesHudLastLength) when invoked
    # later by the WinForms event loop unless explicitly bound into a closure at definition
    # time. Without this, the tick handler silently no-ops (wrapped in try/catch) and the HUD
    # never shows any log lines - this was found and fixed during manual testing.
    $timer.Add_Tick({
        try {
            if (Test-Path $EyesLogPath) {
                $fileLen = (Get-Item $EyesLogPath).Length
                if ($fileLen -lt $eyesHudLastLength) { $eyesHudLastLength = 0 }
                if ($fileLen -gt $eyesHudLastLength) {
                    $fs = [System.IO.File]::Open($EyesLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    [void]$fs.Seek($eyesHudLastLength, [System.IO.SeekOrigin]::Begin)
                    $reader = New-Object System.IO.StreamReader($fs)
                    $newText = $reader.ReadToEnd()
                    $reader.Close()
                    $fs.Close()
                    $eyesHudLastLength = $fileLen

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
                $durationTag = if ($info.indefinite) { " (indefinite)" } else { "" }
                $status.Text = "*  AUTO: $($info.description)$durationTag"
                $status.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140)
                $stopBtn.Visible = $true
            } else {
                $status.Text = "*  Idle"
                $status.ForeColor = [System.Drawing.Color]::Gray
                $stopBtn.Visible = $false
            }
        } catch {}
    }.GetNewClosure())
    $timer.Start()
    $form.Add_FormClosing({ $timer.Stop() })

    $form.Show()
    return $form
}
