# Standalone single-action runner, kept for manual testing (see README "Quick manual test")
# and as a fallback. The live MCP server does NOT use this path - it talks to the persistent
# host.ps1 over a named pipe instead, avoiding a fresh powershell.exe process per action.
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$ParamsFile
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "lib.ps1")
. (Join-Path $here "dispatch.ps1")

$p = @{}
if (Test-Path $ParamsFile) {
    $raw = Get-Content -Raw -Path $ParamsFile
    if ($raw.Trim().Length -gt 0) {
        $json = $raw | ConvertFrom-Json
        $json.PSObject.Properties | ForEach-Object { $p[$_.Name] = $_.Value }
    }
}

$result = Invoke-EyesAction -Action $Action -P $p
$result | ConvertTo-Json -Depth 6 -Compress
