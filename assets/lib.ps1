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
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
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

if (-not ("ClaudeEyes.AvatarForm" -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace ClaudeEyes {
    // A small customizable mech character - arms, legs, a visor-eyed head, and optional
    // antenna/shoulder-lights/chest-core accessories - whose pose/visor color changes by
    // State, bobs gently, and shows a thought bubble while thinking. All animation is
    // computed from wall-clock elapsed time (StartTicks/TotalMs), so the caller only needs
    // to Invalidate() on a timer loop - no per-frame state needs pushing in from PowerShell.
    // Colors/accessories are plain public fields PowerShell sets before Show(), read from
    // avatar.config.json by Show-EyesAvatar.
    public class AvatarForm : Form {
        public string State = "thinking"; // thinking | acting | happy | denied
        public long StartTicks;
        public double TotalMs = 600;
        public Color PrimaryColor = Color.FromArgb(70, 160, 255);
        public Color AccentColor = Color.FromArgb(255, 209, 102);
        public bool AntennaEnabled = true;
        public bool ShoulderLightsEnabled = true;
        public bool ChestCoreEnabled = true;

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00080000; // NOACTIVATE | TOOLWINDOW | LAYERED
                return cp;
            }
        }

        private static GraphicsPath RoundedRect(Rectangle r, int radius) {
            GraphicsPath path = new GraphicsPath();
            int d = radius * 2;
            path.AddArc(r.Left, r.Top, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        private static void GetArmOffsets(string state, bool happy, bool isLead, out int ex, out int ey, out int hx, out int hy) {
            if (happy) { ex = 12; ey = -10; hx = 16; hy = -22; return; }
            if (state == "denied") { ex = 4; ey = 16; hx = 2; hy = 30; return; }
            if (state == "thinking" && isLead) { ex = 6; ey = 2; hx = 0; hy = -8; return; }
            if (state == "acting") { ex = 12; ey = 10; hx = 20; hy = 16; return; }
            ex = 10; ey = 14; hx = 14; hy = 28; // idle fallback
        }

        private static void DrawThoughtBubble(Graphics g, int bx, int by) {
            using (Brush bubbleBrush = new SolidBrush(Color.FromArgb(235, 255, 255, 255)))
            using (Pen bubblePen = new Pen(Color.FromArgb(180, 180, 190), 1f)) {
                g.FillEllipse(bubbleBrush, bx, by + 14, 6, 6);
                g.DrawEllipse(bubblePen, bx, by + 14, 6, 6);
                g.FillEllipse(bubbleBrush, bx + 5, by + 6, 8, 8);
                g.DrawEllipse(bubblePen, bx + 5, by + 6, 8, 8);
                Rectangle bubbleRect = new Rectangle(bx + 10, by - 16, 34, 22);
                g.FillEllipse(bubbleBrush, bubbleRect);
                g.DrawEllipse(bubblePen, bubbleRect);
                using (Brush dot = new SolidBrush(Color.FromArgb(90, 90, 100))) {
                    int dotY = bubbleRect.Top + bubbleRect.Height / 2 - 2;
                    g.FillEllipse(dot, bubbleRect.Left + 6, dotY, 4, 4);
                    g.FillEllipse(dot, bubbleRect.Left + 15, dotY, 4, 4);
                    g.FillEllipse(dot, bubbleRect.Left + 24, dotY, 4, 4);
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            double elapsedMs = (DateTime.Now.Ticks - StartTicks) / 10000.0;
            double progress = Math.Min(1.0, Math.Max(0.0, elapsedMs / Math.Max(1.0, TotalMs)));
            double bob = Math.Sin(elapsedMs / 260.0) * 2.5;
            bool happy = (State == "happy") || (State == "acting" && progress > 0.72);
            bool thinking = (State == "thinking");

            int cx = 60;
            int groundY = (this.Height - 14) + (int)bob;
            int legLen = 26;
            int hipY = groundY - legLen;
            int torsoH = 32;
            int torsoTopY = hipY - torsoH;
            int shoulderY = torsoTopY + 6;
            int headW = 26, headH = 20;
            int headBottomY = torsoTopY - 2;
            int headTopY = headBottomY - headH;
            int headCenterY = (headTopY + headBottomY) / 2;

            Color plate = PrimaryColor;
            Color plateDark = ControlPaint.Dark(plate, 0.25f);
            Color plateLight = ControlPaint.Light(plate, 0.3f);
            Color glow = (State == "denied") ? Color.FromArgb(230, 70, 70) : AccentColor;

            using (Pen outline = new Pen(plateDark, 1.6f))
            using (Brush plateBrush = new SolidBrush(plate))
            using (Brush plateLightBrush = new SolidBrush(plateLight)) {

                for (int i = 0; i < 2; i++) {
                    int side = (i == 0) ? -1 : 1;
                    int hipX = cx + side * 9;
                    double phase = elapsedMs / 260.0 + i * Math.PI;
                    int kneeWobble = (int)(Math.Sin(phase) * 2);
                    int kneeX = hipX + side * 2;
                    int kneeY = hipY + legLen / 2 + kneeWobble;
                    int footX = hipX + side * 3;
                    int footY = groundY;
                    using (Pen leg = new Pen(plate, 7f)) {
                        leg.StartCap = LineCap.Round;
                        leg.EndCap = LineCap.Round;
                        g.DrawLine(leg, hipX, hipY, kneeX, kneeY);
                        g.DrawLine(leg, kneeX, kneeY, footX, footY);
                    }
                    g.FillRectangle(plateBrush, footX - 6, footY - 2, 12, 5);
                    g.DrawRectangle(outline, footX - 6, footY - 2, 12, 5);
                }

                Rectangle torsoRect = new Rectangle(cx - 15, torsoTopY, 30, torsoH);
                using (GraphicsPath tp = RoundedRect(torsoRect, 5)) {
                    g.FillPath(plateBrush, tp);
                    g.DrawPath(outline, tp);
                }
                if (ChestCoreEnabled) {
                    double corePulse = 0.5 + 0.5 * Math.Sin(elapsedMs / 180.0);
                    int coreAlpha = (int)(120 + corePulse * 135);
                    using (Brush core = new SolidBrush(Color.FromArgb(coreAlpha, glow))) {
                        g.FillEllipse(core, cx - 5, torsoTopY + torsoH / 2 - 5, 10, 10);
                    }
                }

                for (int i = 0; i < 2; i++) {
                    int side = (i == 0) ? -1 : 1;
                    bool isLead = side > 0;
                    int sx = cx + side * 14;
                    int ex, ey, hx, hy;
                    GetArmOffsets(State, happy, isLead, out ex, out ey, out hx, out hy);
                    int elbowX = sx + side * ex, elbowY = shoulderY + ey;
                    int handX = sx + side * hx, handY = shoulderY + hy;
                    using (Pen arm = new Pen(plate, 6f)) {
                        arm.StartCap = LineCap.Round;
                        arm.EndCap = LineCap.Round;
                        g.DrawLine(arm, sx, shoulderY, elbowX, elbowY);
                        g.DrawLine(arm, elbowX, elbowY, handX, handY);
                    }
                    using (Brush jointBrush = new SolidBrush(plateDark)) {
                        g.FillEllipse(jointBrush, sx - 3, shoulderY - 3, 6, 6);
                        g.FillEllipse(jointBrush, handX - 3, handY - 3, 6, 6);
                    }
                    if (ShoulderLightsEnabled) {
                        using (Brush sl = new SolidBrush(glow)) {
                            g.FillEllipse(sl, sx - 2, shoulderY - 2, 4, 4);
                        }
                    }
                }

                Rectangle headRect = new Rectangle(cx - headW / 2, headTopY, headW, headH);
                using (GraphicsPath hp = RoundedRect(headRect, 6)) {
                    g.FillPath(plateLightBrush, hp);
                    g.DrawPath(outline, hp);
                }

                double visorAlpha = thinking ? (0.55 + 0.45 * Math.Sin(elapsedMs / 150.0)) : 1.0;
                Rectangle visorRect = new Rectangle(headRect.Left + 4, headCenterY - 3, headW - 8, 6);
                using (Brush visorBrush = new SolidBrush(Color.FromArgb((int)(255 * visorAlpha), glow))) {
                    g.FillRectangle(visorBrush, visorRect);
                }
                using (Pen seg = new Pen(plateDark, 1f)) {
                    int mid = visorRect.Left + visorRect.Width / 2;
                    g.DrawLine(seg, mid, visorRect.Top, mid, visorRect.Bottom);
                }

                if (AntennaEnabled) {
                    int antX = cx;
                    int antTopY = headTopY - 10;
                    using (Pen antPen = new Pen(plateDark, 2f)) {
                        g.DrawLine(antPen, antX, headTopY, antX, antTopY);
                    }
                    double tipPulse = thinking ? (0.4 + 0.6 * (0.5 + 0.5 * Math.Sin(elapsedMs / 150.0))) : 1.0;
                    using (Brush tip = new SolidBrush(Color.FromArgb((int)(255 * tipPulse), glow))) {
                        g.FillEllipse(tip, antX - 3, antTopY - 3, 6, 6);
                    }
                }
            }

            if (thinking) {
                DrawThoughtBubble(g, cx + 20, headTopY - 4);
            }
        }
    }
}
"@
}

function Get-EyesAvatarDefaultPoint {
    # Where the avatar shows up for actions with no on-screen target coordinates
    # (type_text, send_keys, focus_window, set_clipboard, task start/denial).
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return @{ x = $screen.Right - 190; y = $screen.Bottom - 190 }
}

function ConvertFrom-EyesHexColor {
    param([string]$Hex, [System.Drawing.Color]$FallbackColor)
    try {
        $h = $Hex.TrimStart('#')
        if ($h.Length -eq 6) {
            $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
            $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
            $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
            return [System.Drawing.Color]::FromArgb($r, $g, $b)
        }
    } catch {}
    return $FallbackColor
}

function Get-EyesAvatarConfig {
    # Customization source of truth: assets/avatar.config.json, read fresh on every call
    # (each action is a separate process anyway) so edits apply immediately, no restart needed.
    $cfg = @{
        primaryColor   = "#4696FF"
        accentColor    = "#FFD166"
        antenna        = $true
        shoulderLights = $true
        chestCore      = $true
    }
    $path = Join-Path $PSScriptRoot "avatar.config.json"
    if (Test-Path $path) {
        try {
            $raw = Get-Content -Raw -Path $path | ConvertFrom-Json
            foreach ($k in @("primaryColor", "accentColor")) {
                if ($raw.PSObject.Properties.Name -contains $k -and $raw.$k) { $cfg[$k] = $raw.$k }
            }
            foreach ($k in @("antenna", "shoulderLights", "chestCore")) {
                if ($raw.PSObject.Properties.Name -contains $k) { $cfg[$k] = [bool]$raw.$k }
            }
        } catch {
            # malformed config: fall back to defaults rather than failing the action
        }
    }
    return $cfg
}

function Show-EyesAvatar {
    # state: thinking | acting | happy | denied
    param([int]$X, [int]$Y, [string]$State = "acting", [int]$DurationMs = 650)

    $cfg = Get-EyesAvatarConfig

    # Width is wider than the character itself (cx is fixed at 60 in AvatarForm) to leave
    # room for the thought bubble and outstretched arms without clipping.
    $w = 170; $h = 150
    $form = New-Object ClaudeEyes.AvatarForm
    $form.FormBorderStyle = "None"
    $form.StartPosition = "Manual"
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.Location = New-Object System.Drawing.Point(($X - 60), ($Y - ($h - 14)))
    $form.BackColor = [System.Drawing.Color]::Magenta
    $form.TransparencyKey = [System.Drawing.Color]::Magenta
    $form.State = $State
    $form.StartTicks = [DateTime]::Now.Ticks
    $form.TotalMs = $DurationMs
    $form.PrimaryColor = ConvertFrom-EyesHexColor -Hex $cfg.primaryColor -FallbackColor ([System.Drawing.Color]::FromArgb(70, 160, 255))
    $form.AccentColor = ConvertFrom-EyesHexColor -Hex $cfg.accentColor -FallbackColor ([System.Drawing.Color]::FromArgb(255, 209, 102))
    $form.AntennaEnabled = [bool]$cfg.antenna
    $form.ShoulderLightsEnabled = [bool]$cfg.shoulderLights
    $form.ChestCoreEnabled = [bool]$cfg.chestCore

    $form.Show()
    $deadline = (Get-Date).AddMilliseconds($DurationMs)
    while ((Get-Date) -lt $deadline) {
        $form.Invalidate()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $form.Close()
    $form.Dispose()
}

function Write-EyesLog {
    param([string]$Message)
    $entry = @{ ts = (Get-Date).ToString("o"); message = $Message } | ConvertTo-Json -Compress
    Add-Content -Path $EyesLogPath -Value $entry -Encoding utf8
}

function Hide-EyesConsoleWindow {
    # Hides THIS process's own console window via a direct Win32 call, as opposed to
    # launching powershell.exe with -WindowStyle Hidden (which was found to also suppress
    # GUI windows created later in the same process - not just the console) or a shortcut's
    # WindowStyle=Minimized (which causes windows shown afterward to inherit a minimized
    # state). Calling this after the console exists but before showing any Forms gives a
    # clean console-free start without affecting the HUD/avatar windows at all.
    $hwnd = [ClaudeEyes.Native]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        [ClaudeEyes.Native]::ShowWindowAsync($hwnd, 0) | Out-Null  # SW_HIDE
    }
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
