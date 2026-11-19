"""Localhost activity dashboard - same page/API as the old assets/dashboard-lib.ps1, served by
Python's built-in http.server instead of System.Net.HttpListener. No admin rights needed either
way (binding to 127.0.0.1 is always allowed for a normal user)."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import state

PORT = 51823

_HTML = """<!doctype html>
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
"""


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence default stderr access logging

    def _send(self, body: str, content_type: str, status: int = 200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self._send(_HTML, "text/html; charset=utf-8")
        elif self.path == "/api/log":
            entries = state.read_log_tail(300)
            self._send(json.dumps(entries), "application/json")
        elif self.path == "/api/status":
            if state.is_auto_task_active():
                info = state.get_task_info() or {}
                body = {"active": True, "description": info.get("description"), "indefinite": bool(info.get("indefinite"))}
            else:
                body = {"active": False}
            self._send(json.dumps(body), "application/json")
        else:
            self._send("Not found", "text/plain", status=404)

    def do_POST(self):
        if self.path == "/api/task/stop":
            state.stop_auto_task()
            state.write_log("AUTO-TASK STOPPED from dashboard")
            self._send(json.dumps({"ended": True}), "application/json")
        else:
            self._send("Not found", "text/plain", status=404)


def start():
    server = ThreadingHTTPServer(("localhost", PORT), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server
