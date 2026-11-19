# Periscope launcher: pick an app, make sure it's wired up to the periscope
# MCP server, and launch it. Claude Desktop actually gets working click/screenshot
# control. claude.ai in a browser cannot load a local MCP server at all (it only
# supports remote HTTPS+OAuth connectors), so that option is explicitly flagged.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$serverEntry = @{
    command = "node"
    args    = @((Join-Path $root "dist\index.js"))
}

function Ensure-DesktopConfig {
    $configPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
    $configDir = Split-Path -Parent $configPath

    $config = [ordered]@{}
    if (Test-Path $configPath) {
        $raw = Get-Content -Raw -Path $configPath
        if ($raw.Trim().Length -gt 0) {
            $parsed = $raw | ConvertFrom-Json
            $parsed.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
        }
    } elseif (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (-not $config.Contains("mcpServers")) {
        $config["mcpServers"] = [ordered]@{}
    }
    $mcpServers = [ordered]@{}
    if ($config["mcpServers"]) {
        $config["mcpServers"].PSObject.Properties | ForEach-Object { $mcpServers[$_.Name] = $_.Value }
    }
    $mcpServers["periscope"] = $serverEntry
    $config["mcpServers"] = $mcpServers

    if (Test-Path $configPath) {
        Copy-Item $configPath "$configPath.bak" -Force
    }
    ($config | ConvertTo-Json -Depth 10) | Out-File -Encoding utf8 $configPath
    return $configPath
}

function Find-ClaudeDesktopExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Claude\Claude.exe")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

    $found = Get-ChildItem -Path $env:LOCALAPPDATA -Filter "Claude.exe" -Recurse -ErrorAction SilentlyContinue -Depth 3 |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Periscope"
$form.Size = New-Object System.Drawing.Size(420, 220)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.TopMost = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Which app do you want to use with Periscope?"
$label.AutoSize = $false
$label.Size = New-Object System.Drawing.Size(380, 40)
$label.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($label)

$btnDesktop = New-Object System.Windows.Forms.Button
$btnDesktop.Text = "Launch Claude Desktop (full control)"
$btnDesktop.Size = New-Object System.Drawing.Size(360, 40)
$btnDesktop.Location = New-Object System.Drawing.Point(20, 65)
$form.Controls.Add($btnDesktop)

$btnWeb = New-Object System.Windows.Forms.Button
$btnWeb.Text = "Open claude.ai in browser (no laptop control)"
$btnWeb.Size = New-Object System.Drawing.Size(360, 40)
$btnWeb.Location = New-Object System.Drawing.Point(20, 115)
$form.Controls.Add($btnWeb)

$note = New-Object System.Windows.Forms.Label
$note.Text = "claude.ai web can't load a local MCP server - it won't be able to see your screen or click."
$note.ForeColor = [System.Drawing.Color]::DimGray
$note.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
$note.Size = New-Object System.Drawing.Size(380, 30)
$note.Location = New-Object System.Drawing.Point(20, 160)
$form.Controls.Add($note)

$btnDesktop.Add_Click({
    $configPath = Ensure-DesktopConfig
    $exe = Find-ClaudeDesktopExe
    if ($exe) {
        Start-Process $exe
        $form.Close()
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Updated $configPath with the periscope server, but Claude Desktop isn't installed on this machine.`n`nInstall it, then relaunch this picker (or just open Claude Desktop yourself - it will pick up the config automatically).",
            "Claude Desktop not found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

$btnWeb.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        $form,
        "claude.ai in a browser cannot use the periscope tools (screenshot/click/type) - that only works through a local MCP client like Claude Desktop or Claude Code.`n`nOpening claude.ai for a normal chat, without laptop control.",
        "No laptop control in web",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Start-Process "https://claude.ai"
    $form.Close()
})

[void]$form.ShowDialog()
