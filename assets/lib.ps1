# Periscope - Win32 / .NET helper functions.
# Dot-sourced by run.ps1 and hud.ps1. Every function returns a plain object meant for ConvertTo-Json.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Shared state files (per-machine, not per-process) so the stateless run.ps1 invocations
# and the persistent hud.ps1 can agree on activity history / autonomous-task status.
$EyesLogPath = Join-Path $env:TEMP "periscope-activity.log"
$EyesTaskPath = Join-Path $env:TEMP "periscope-task.json"

if (-not ("ClaudeEyes.Native" -as [type])) {
Add-Type -Namespace ClaudeEyes -Name Native -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@
}

if (-not ("ClaudeEyes.ToastForm" -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Windows.Forms;

namespace ClaudeEyes {
    public class ToastForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                return cp;
            }
        }
    }
}
"@
}

if (-not ("ClaudeEyes.RingForm" -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System.Windows.Forms;
using System.Drawing;

namespace ClaudeEyes {
    public class RingForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00080000; // NOACTIVATE | TOOLWINDOW | LAYERED
                return cp;
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            using (Pen pen = new Pen(Color.FromArgb(255, 70, 160, 255), 3)) {
                e.Graphics.DrawEllipse(pen, 4, 4, this.Width - 8, this.Height - 8);
            }
        }
    }
}
"@
}

function Show-EyesCursorRing {
    # Draws a blue ring at the target point right before a click/move, distinct from the
    # real mouse cursor, so it's visually obvious *where* the agent is about to act.
    param([int]$X, [int]$Y, [int]$DurationMs = 450)

    $size = 46
    $form = New-Object ClaudeEyes.RingForm
    $form.FormBorderStyle = "None"
    $form.StartPosition = "Manual"
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.Size = New-Object System.Drawing.Size($size, $size)
    $form.Location = New-Object System.Drawing.Point(($X - [int]($size / 2)), ($Y - [int]($size / 2)))
    $form.BackColor = [System.Drawing.Color]::Magenta
    $form.TransparencyKey = [System.Drawing.Color]::Magenta

    $form.Show()
    $deadline = (Get-Date).AddMilliseconds($DurationMs)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    $form.Close()
    $form.Dispose()
}

function Write-EyesLog {
    param([string]$Message)
    $entry = @{ ts = (Get-Date).ToString("o"); message = $Message } | ConvertTo-Json -Compress
    Add-Content -Path $EyesLogPath -Value $entry -Encoding utf8
}

function Test-EyesAutoTaskActive {
    if (-not (Test-Path $EyesTaskPath)) { return $false }
    try {
        $t = Get-Content -Raw -Path $EyesTaskPath | ConvertFrom-Json
        $expiry = [DateTime]::Parse($t.expiry)
        if ((Get-Date) -lt $expiry) { return $true }
        Remove-Item -Path $EyesTaskPath -Force -ErrorAction SilentlyContinue
        return $false
    } catch {
        return $false
    }
}

function Get-EyesTaskInfo {
    if (-not (Test-EyesAutoTaskActive)) { return $null }
    return Get-Content -Raw -Path $EyesTaskPath | ConvertFrom-Json
}

function Start-EyesAutoTask {
    # $Minutes = $null (or 0) means indefinite: runs until Stop-EyesAutoTask is called
    # (via end_task or the HUD's Stop button), matching an "always-on until dismissed" model.
    param([string]$Description, [Nullable[int]]$Minutes = $null)
    if ($Minutes -and $Minutes -lt 1) { $Minutes = 1 }
    $indefinite = -not $Minutes
    $expiry = if ($indefinite) { [DateTime]::MaxValue.ToString("o") } else { (Get-Date).AddMinutes($Minutes).ToString("o") }
    @{ description = $Description; expiry = $expiry; indefinite = $indefinite } | ConvertTo-Json -Compress |
        Out-File -Encoding utf8 -FilePath $EyesTaskPath
    return @{ started = $true; description = $Description; expiry = $expiry; indefinite = $indefinite }
}

function Stop-EyesAutoTask {
    if (Test-Path $EyesTaskPath) { Remove-Item -Path $EyesTaskPath -Force -ErrorAction SilentlyContinue }
    return @{ ended = $true }
}

function Show-EyesToast {
    # Non-activating overlay: never steals keyboard focus from whatever window
    # the action is about to act on.
    param([string]$Text, [int]$DurationMs = 1100)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $form = New-Object ClaudeEyes.ToastForm
    $form.FormBorderStyle = "None"
    $form.StartPosition = "Manual"
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
    $form.Opacity = 0.92

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "* Periscope:  $Text"
    $label.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140)
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $label.AutoSize = $true
    $label.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
    $form.Controls.Add($label)

    $form.Size = $label.PreferredSize
    $x = $screen.Right - $form.Width - 20
    $y = $screen.Bottom - $form.Height - 20
    $form.Location = New-Object System.Drawing.Point($x, $y)

    $form.Show()
    $deadline = (Get-Date).AddMilliseconds($DurationMs)
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $form.Close()
    $form.Dispose()
}

function Confirm-EyesAction {
    param([string]$Message)
    $form = New-Object System.Windows.Forms.Form
    $form.TopMost = $true
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1,1)
    $result = [System.Windows.Forms.MessageBox]::Show(
        $form,
        "$Message`n`nAllow this action?",
        "Periscope - Confirm Action",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    $form.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-EyesScreenshot {
    param([string]$OutPath, [int]$Monitor = -1)

    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($Monitor -ge 0 -and $Monitor -lt $screens.Length) {
        $bounds = $screens[$Monitor].Bounds
    } else {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    }

    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()

    return @{ path = $OutPath; width = $bounds.Width; height = $bounds.Height }
}

function Get-EyesScreens {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $i = 0
    $out = @()
    foreach ($s in $screens) {
        $out += @{
            index = $i
            primary = $s.Primary
            x = $s.Bounds.X; y = $s.Bounds.Y
            width = $s.Bounds.Width; height = $s.Bounds.Height
        }
        $i++
    }
    return $out
}

$MOUSEEVENTF_LEFTDOWN = 0x02
$MOUSEEVENTF_LEFTUP = 0x04
$MOUSEEVENTF_RIGHTDOWN = 0x08
$MOUSEEVENTF_RIGHTUP = 0x10
$MOUSEEVENTF_MIDDLEDOWN = 0x20
$MOUSEEVENTF_MIDDLEUP = 0x40

function Move-EyesMouse {
    param([int]$X, [int]$Y)
    [ClaudeEyes.Native]::SetCursorPos($X, $Y) | Out-Null
    return @{ x = $X; y = $Y }
}

function Invoke-EyesClick {
    param([int]$X, [int]$Y, [string]$Button = "left", [int]$Count = 1)
    [ClaudeEyes.Native]::SetCursorPos($X, $Y) | Out-Null
    Start-Sleep -Milliseconds 50

    switch ($Button) {
        "right"  { $down = $MOUSEEVENTF_RIGHTDOWN;  $up = $MOUSEEVENTF_RIGHTUP }
        "middle" { $down = $MOUSEEVENTF_MIDDLEDOWN; $up = $MOUSEEVENTF_MIDDLEUP }
        default  { $down = $MOUSEEVENTF_LEFTDOWN;   $up = $MOUSEEVENTF_LEFTUP }
    }

    for ($i = 0; $i -lt $Count; $i++) {
        [ClaudeEyes.Native]::mouse_event($down, 0, 0, 0, 0)
        [ClaudeEyes.Native]::mouse_event($up, 0, 0, 0, 0)
        if ($Count -gt 1) { Start-Sleep -Milliseconds 80 }
    }

    return @{ x = $X; y = $Y; button = $Button; count = $Count }
}

function ConvertTo-EyesSendKeysLiteral {
    param([string]$Text)
    $special = '+^%~(){}[]'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($special.IndexOf($ch) -ge 0) {
            [void]$sb.Append('{').Append($ch).Append('}')
        } else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Send-EyesText {
    param([string]$Text)
    $escaped = ConvertTo-EyesSendKeysLiteral -Text $Text
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    return @{ sent = $Text.Length }
}

function Send-EyesKeys {
    # Raw SendKeys syntax, e.g. "^c" (Ctrl+C), "%{TAB}" (Alt+Tab), "{ENTER}"
    param([string]$Keys)
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    return @{ sent = $Keys }
}

function Get-EyesWindows {
    $procs = Get-Process | Where-Object { $_.MainWindowTitle -ne "" -and $_.MainWindowHandle -ne 0 }
    $out = @()
    foreach ($p in $procs) {
        $rect = New-Object ClaudeEyes.Native+RECT
        [ClaudeEyes.Native]::GetWindowRect($p.MainWindowHandle, [ref]$rect) | Out-Null
        $out += @{
            pid = $p.Id
            processName = $p.ProcessName
            title = $p.MainWindowTitle
            minimized = [bool][ClaudeEyes.Native]::IsIconic($p.MainWindowHandle)
            x = $rect.Left; y = $rect.Top
            width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top
        }
    }
    return $out
}

function Set-EyesFocusWindow {
    param([int]$Pid)
    $p = Get-Process -Id $Pid -ErrorAction Stop
    if ($p.MainWindowHandle -eq 0) { throw "Process $Pid has no main window" }
    [ClaudeEyes.Native]::ShowWindowAsync($p.MainWindowHandle, 9) | Out-Null  # SW_RESTORE
    Start-Sleep -Milliseconds 100
    $ok = [ClaudeEyes.Native]::SetForegroundWindow($p.MainWindowHandle)
    return @{ pid = $Pid; focused = [bool]$ok }
}

function Get-EyesClipboard {
    try {
        $text = Get-Clipboard -Raw -ErrorAction Stop
    } catch {
        $text = ""
    }
    return @{ text = $text }
}

function Set-EyesClipboard {
    param([string]$Text)
    Set-Clipboard -Value $Text
    return @{ set = $true }
}
