# Serves the activity dashboard over plain HTTP on localhost (System.Net.HttpListener - no
# admin rights needed since the prefix is "localhost", not a wildcard). Replaces the old
# always-on-top WinForms HUD panel: no floating window, no WinForms event-handler crashes,
# just a page you open in a browser when you want to look at it. Polled from a browser tab via
# fetch(), not pushed - simplest thing that works without adding WebSocket/SSE complexity.

$EyesDashboardHtml = @'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Periscope Activity</title>
<style>
  :root { color-scheme: dark; }
  body { background:#18181c; color:#d2d2d2; font-family: "Segoe UI", sans-serif; margin:0; padding:0; }
  header { padding: 14px 18px; border-bottom: 1px solid #2a2a30; display:flex; align-items:center; justify-content:space-between; position:sticky; top:0; background:#18181c; }
  .status { font-weight:600; font-size:15px; }
  .status.idle { color:#9a9aa0; }
  .status.auto { color:#78dc8c; }
  .status.lost { color:#e07070; }
  button#stopBtn { background:#8c2828; color:#fff; border:none; padding:8px 14px; border-radius:4px; cursor:pointer; display:none; font-size:13px; }
  button#stopBtn:hover { background:#a83232; }
  #log { font-family: Consolas, monospace; font-size:13px; padding: 14px 18px; white-space:pre-wrap; }
  .line { padding: 1px 0; }
  .time { color:#6a6a72; margin-right:8px; }
</style>
</head>
<body>
<header>
  <div class="status idle" id="status">* Idle</div>
  <button id="stopBtn">Stop autonomous task</button>
</header>
<div id="log"></div>
<script>
const statusEl = document.getElementById('status');
const stopBtn = document.getElementById('stopBtn');
const logEl = document.getElementById('log');

stopBtn.onclick = async () => {
  await fetch('/api/task/stop', { method: 'POST' });
  refresh();
};

function escapeHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

async function refresh() {
  try {
    const [logRes, statusRes] = await Promise.all([fetch('/api/log'), fetch('/api/status')]);
    const log = await logRes.json();
    const status = await statusRes.json();

    if (status.active) {
      statusEl.className = 'status auto';
      statusEl.textContent = '* AUTO: ' + status.description + (status.indefinite ? ' (indefinite)' : '');
      stopBtn.style.display = 'inline-block';
    } else {
      statusEl.className = 'status idle';
      statusEl.textContent = '* Idle';
      stopBtn.style.display = 'none';
    }

    const atBottom = (window.innerHeight + window.scrollY) >= (document.body.offsetHeight - 40);
    logEl.innerHTML = log.map(function (e) {
      const t = new Date(e.ts).toLocaleTimeString();
      return '<div class="line"><span class="time">[' + t + ']</span>' + escapeHtml(e.message) + '</div>';
    }).join('');
    if (atBottom) window.scrollTo(0, document.body.scrollHeight);
  } catch (err) {
    statusEl.className = 'status lost';
    statusEl.textContent = 'Connection lost - is Periscope still running?';
  }
}

refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>
'@

function Write-EyesHttpResponse {
    param($Response, [string]$Body, [string]$ContentType, [int]$StatusCode = 200)
    try {
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally {
        try { $Response.OutputStream.Close() } catch {}
    }
}

function Invoke-EyesDashboardRequest {
    param($Context)
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath

    try {
        if ($req.HttpMethod -eq "GET" -and $path -eq "/") {
            Write-EyesHttpResponse -Response $res -Body $EyesDashboardHtml -ContentType "text/html; charset=utf-8"
        } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/api/log") {
            $entries = @()
            if (Test-Path $EyesLogPath) {
                $lines = Get-Content -Path $EyesLogPath -Tail 300 -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    try { $entries += ($line | ConvertFrom-Json) } catch {}
                }
            }
            Write-EyesHttpResponse -Response $res -Body (ConvertTo-Json -InputObject @($entries) -Depth 4 -Compress) -ContentType "application/json"
        } elseif ($req.HttpMethod -eq "GET" -and $path -eq "/api/status") {
            if (Test-EyesAutoTaskActive) {
                $info = Get-EyesTaskInfo
                $body = @{ active = $true; description = $info.description; indefinite = [bool]$info.indefinite } | ConvertTo-Json -Compress
            } else {
                $body = @{ active = $false } | ConvertTo-Json -Compress
            }
            Write-EyesHttpResponse -Response $res -Body $body -ContentType "application/json"
        } elseif ($req.HttpMethod -eq "POST" -and $path -eq "/api/task/stop") {
            Stop-EyesAutoTask | Out-Null
            Write-EyesLog -Message "AUTO-TASK STOPPED from dashboard"
            Write-EyesHttpResponse -Response $res -Body (@{ ended = $true } | ConvertTo-Json -Compress) -ContentType "application/json"
        } else {
            Write-EyesHttpResponse -Response $res -Body "Not found" -ContentType "text/plain" -StatusCode 404
        }
    } catch {
        try { Write-EyesHttpResponse -Response $res -Body "Server error" -ContentType "text/plain" -StatusCode 500 } catch {}
    }
}
