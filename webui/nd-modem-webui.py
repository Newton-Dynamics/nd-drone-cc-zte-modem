#!/usr/bin/env python3
"""nd-modem-webui — minimal local config UI + JSON API for the ZTE modem/SIM
lookup tables and a glance at uplink status.

Installed to: /opt/nd-uplink/webui/nd-modem-webui.py, run by
nd-modem-webui.service — independent of NetworkManager/nd-uplink-manager, so
it's reachable to fix things even if the rest of the stack is broken.

Stdlib only, no framework, no build step, no CDN assets (fully self
contained/offline — this is literally the uplink-configuration tool).

Data files (shared with modem/nd-zte-modem.sh, same lock discipline):
  <MODEM_DIR>/modems.json  [{"imei","password","label"}, ...]
  <MODEM_DIR>/sims.json    [{"imsi","pin","label"}, ...]
  <MODEM_DIR>/active.json  {"modem_imei","sim_imsi"}
  <MODEM_DIR>/db.lock      flock guard around any read-modify-write

Never echoes a stored password/PIN back over the API — list endpoints report
password_set/pin_set booleans only.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEM_DIR = os.environ.get("ND_MODEM_DIR", "/opt/nd-uplink/modem")
MODEMS_DB = os.path.join(MODEM_DIR, "modems.json")
SIMS_DB = os.path.join(MODEM_DIR, "sims.json")
ACTIVE_DB = os.path.join(MODEM_DIR, "active.json")
DB_LOCK = os.path.join(MODEM_DIR, "db.lock")

ZTE_HOST = os.environ.get("ND_ZTE_HOST", "192.168.0.1")
STATUS_CMD = os.environ.get("ND_STATUS_CMD", "nd-uplink-status")
ACTIVATE_CMD = os.environ.get("ND_ACTIVATE_CMD", "nd-zte-activate")
MODEM_SCRIPT = os.environ.get("ND_MODEM_SCRIPT", os.path.join(MODEM_DIR, "nd-zte-modem.sh"))

# Allowlist for /api/service-log — never let the query string pick an
# arbitrary journalctl unit.
SERVICE_LOG_UNITS = ("nd-uplink-manager.service", "nd-modem-webui.service")

PORT = int(os.environ.get("ND_WEBUI_PORT", "7077"))


# --- tiny JSON "database" helpers, flock-guarded like the bash side ---------

class LockedFile:
    def __init__(self, lock_path):
        self._lock_path = lock_path
        self._fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self._lock_path), exist_ok=True)
        self._fh = open(self._lock_path, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()


def _read_list(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f)


def _write_list(path, items):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=2)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def read_modems():
    return _read_list(MODEMS_DB)


def read_sims():
    return _read_list(SIMS_DB)


def read_active():
    if not os.path.exists(ACTIVE_DB):
        return {}
    with open(ACTIVE_DB) as f:
        return json.load(f)


def write_active(patch):
    with LockedFile(DB_LOCK):
        active = read_active()
        active.update(patch)
        tmp = f"{ACTIVE_DB}.tmp"
        with open(tmp, "w") as f:
            json.dump(active, f, indent=2)
        os.replace(tmp, ACTIVE_DB)
        os.chmod(ACTIVE_DB, 0o600)
    return active


def modem_public(m):
    return {"imei": m["imei"], "label": m.get("label", ""), "password_set": bool(m.get("password"))}


def sim_public(s):
    return {"imsi": s["imsi"], "label": s.get("label", ""), "pin_set": bool(s.get("pin"))}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def run_modem_script(args, timeout=25):
    """Run nd-zte-modem.sh in one of its test modes and parse its one-line
    JSON result. Never raises — any failure to run/parse becomes
    {"ok": False, "error": ...} so callers can always just look at "ok"."""
    try:
        proc = subprocess.run(
            [MODEM_SCRIPT, *args], capture_output=True, text=True, timeout=timeout,
        )
        out = (proc.stdout or "").strip().splitlines()
        if not out:
            return {"ok": False, "error": (proc.stderr or "no output from modem script").strip()[:300]}
        return json.loads(out[-1])
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timed out talking to the modem"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def test_modem_login(password):
    return run_modem_script(["--test-login", password])


def test_modem_pin(pin):
    return run_modem_script(["--test-pin", pin])


def add_modem(payload):
    imei = str(payload.get("imei", "")).strip()
    password = str(payload.get("password", ""))
    label = str(payload.get("label", "")).strip()
    if not imei:
        raise ApiError(400, "imei is required")
    if not re.fullmatch(r"\d{6,20}", imei):
        raise ApiError(400, "imei must be 6-20 digits")
    if not password:
        raise ApiError(400, "password is required")

    # One real login attempt against whatever's plugged in right now, so a
    # typo is caught immediately instead of surfacing later during a real
    # unlock. Never blocks the save — you may be pre-registering a modem
    # that isn't physically connected yet.
    login_test = test_modem_login(password)
    if login_test.get("ok") and login_test.get("imei") and login_test["imei"] != imei:
        login_test["imei_mismatch"] = True

    with LockedFile(DB_LOCK):
        modems = read_modems()
        modems = [m for m in modems if m["imei"] != imei]
        modems.append({"imei": imei, "password": password, "label": label})
        _write_list(MODEMS_DB, modems)
    result = modem_public({"imei": imei, "password": password, "label": label})
    result["login_test"] = login_test
    return result


def delete_modem(imei):
    with LockedFile(DB_LOCK):
        modems = read_modems()
        remaining = [m for m in modems if m["imei"] != imei]
        if len(remaining) == len(modems):
            raise ApiError(404, "modem not found")
        _write_list(MODEMS_DB, remaining)


def activate_modem(imei):
    modems = read_modems()
    if not any(m["imei"] == imei for m in modems):
        raise ApiError(404, "modem not found")
    return write_active({"modem_imei": imei})


def add_sim(payload):
    imsi = str(payload.get("imsi", "")).strip()
    pin = str(payload.get("pin", ""))
    label = str(payload.get("label", "")).strip()
    if not imsi:
        raise ApiError(400, "imsi is required")
    if not re.fullmatch(r"\d{6,20}", imsi):
        raise ApiError(400, "imsi must be 6-20 digits")

    with LockedFile(DB_LOCK):
        sims = read_sims()
        sims = [s for s in sims if s["imsi"] != imsi]
        sims.append({"imsi": imsi, "pin": pin, "label": label})
        _write_list(SIMS_DB, sims)

    # One real ENTER_PIN attempt against the config UI's active modem, right
    # now — never repeated. A wrong SIM PIN counts toward the carrier's PUK
    # lockout, so this is intentionally a single try, same as the real flow.
    if pin:
        pin_test = test_modem_pin(pin)
    else:
        pin_test = {"ok": False, "skipped": True, "error": "no PIN provided — skipped (SIM may not need one)"}

    result = sim_public({"imsi": imsi, "pin": pin, "label": label})
    result["pin_test"] = pin_test
    return result


def delete_sim(imsi):
    with LockedFile(DB_LOCK):
        sims = read_sims()
        remaining = [s for s in sims if s["imsi"] != imsi]
        if len(remaining) == len(sims):
            raise ApiError(404, "sim not found")
        _write_list(SIMS_DB, remaining)


def activate_sim(imsi):
    sims = read_sims()
    if not any(s["imsi"] == imsi for s in sims):
        raise ApiError(404, "sim not found")
    return write_active({"sim_imsi": imsi})


# --- best-effort unauthenticated modem IMEI probe (mirrors nd-zte-modem.sh) -

def detect_modem_imei(timeout=4):
    url = f"http://{ZTE_HOST}/goform/goform_get_cmd_process?cmd=imei"
    req = urllib.request.Request(url, headers={"Referer": f"http://{ZTE_HOST}/index.html"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
        m = re.search(r'"imei"\s*:\s*"([^"]+)"', body)
        return m.group(1) if m else None
    except Exception:
        return None


# --- HTTP handler ------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "nd-modem-webui/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, body: bytes, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            raise ApiError(400, "invalid JSON body")

    def _route(self, method):
        split = urllib.parse.urlsplit(self.path)
        path = split.path
        query = urllib.parse.parse_qs(split.query)
        try:
            if method == "GET" and path == "/":
                self._send_html(INDEX_HTML.encode())
                return
            if method == "GET" and path == "/api/status":
                self._api_status()
                return
            if path == "/api/modems":
                if method == "GET":
                    self._send_json(200, [modem_public(m) for m in read_modems()])
                    return
                if method == "POST":
                    self._send_json(201, add_modem(self._read_json_body()))
                    return
            m = re.fullmatch(r"/api/modems/([^/]+)", path)
            if m and method == "DELETE":
                delete_modem(m.group(1))
                self._send_json(200, {"deleted": m.group(1)})
                return
            m = re.fullmatch(r"/api/modems/([^/]+)/activate", path)
            if m and method == "POST":
                self._send_json(200, activate_modem(m.group(1)))
                return
            if path == "/api/sims":
                if method == "GET":
                    self._send_json(200, [sim_public(s) for s in read_sims()])
                    return
                if method == "POST":
                    self._send_json(201, add_sim(self._read_json_body()))
                    return
            m = re.fullmatch(r"/api/sims/([^/]+)", path)
            if m and method == "DELETE":
                delete_sim(m.group(1))
                self._send_json(200, {"deleted": m.group(1)})
                return
            m = re.fullmatch(r"/api/sims/([^/]+)/activate", path)
            if m and method == "POST":
                self._send_json(200, activate_sim(m.group(1)))
                return
            if method == "GET" and path == "/api/active":
                self._send_json(200, read_active())
                return
            if method == "GET" and path == "/api/detect":
                self._send_json(200, {"imei": detect_modem_imei()})
                return
            if method == "POST" and path == "/api/unlock":
                subprocess.Popen(
                    [ACTIVATE_CMD],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                self._send_json(202, {"started": True})
                return
            if method == "GET" and path == "/api/unlock/log":
                out = subprocess.run(
                    ["journalctl", "-t", "nd-zte", "-n", "50", "--no-pager"],
                    capture_output=True, text=True, timeout=5,
                ).stdout
                self._send_json(200, {"log": out})
                return
            if method == "GET" and path == "/api/service-log":
                unit = (query.get("unit") or [""])[0]
                if unit not in SERVICE_LOG_UNITS:
                    raise ApiError(400, f"unknown unit: {unit}")
                out = subprocess.run(
                    ["journalctl", "-u", unit, "-n", "100", "--no-pager"],
                    capture_output=True, text=True, timeout=5,
                ).stdout
                self._send_json(200, {"log": out})
                return
            self._send_json(404, {"error": "not found"})
        except ApiError as e:
            self._send_json(e.status, {"error": e.message})
        except Exception as e:  # never let one bad request kill the service
            self._send_json(500, {"error": str(e)})

    def _api_status(self):
        try:
            out = subprocess.run(
                [STATUS_CMD, "--json"], capture_output=True, text=True, timeout=15,
            )
            self._send_json(200, json.loads(out.stdout))
        except Exception as e:
            self._send_json(200, {"error": f"status unavailable: {e}"})

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_DELETE(self):
        self._route("DELETE")


# --- self-contained page: no external CSS/JS/fonts, works fully offline ----

INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nd-uplink config</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; line-height: 1.4; }
  h1 { font-size: 1.3rem; }
  h2 { font-size: 1.05rem; margin-top: 2rem; border-bottom: 1px solid #8884; padding-bottom: .3rem; }
  table { width: 100%; border-collapse: collapse; margin: .5rem 0; }
  th, td { text-align: left; padding: .35rem .5rem; border-bottom: 1px solid #8882; font-size: .92rem; }
  .pill { display: inline-block; padding: .1rem .5rem; border-radius: 1rem; font-size: .8rem; }
  .ok { background: #1a7f3722; color: #1a7f37; }
  .bad { background: #cf222e22; color: #cf222e; }
  .warn { background: #9a670022; color: #9a6700; }
  form.inline { display: flex; gap: .4rem; flex-wrap: wrap; margin: .5rem 0 1rem; }
  form.inline input { flex: 1 1 8rem; min-width: 6rem; }
  input, button { font: inherit; padding: .35rem .5rem; }
  button { cursor: pointer; }
  button.danger { color: #cf222e; }
  .muted { color: #8888; font-size: .85rem; }
  #unlockLog, #serviceLog { white-space: pre-wrap; font-family: ui-monospace, monospace; font-size: .8rem; max-height: 12rem; overflow: auto; background: #8881; padding: .5rem; border-radius: .3rem; color: #000; }
  .spinner { display: inline-block; width: 1rem; height: 1rem; border: 2px solid #8886; border-top-color: #666; border-radius: 50%; animation: nd-spin .8s linear infinite; vertical-align: -2px; margin-right: .4rem; }
  @keyframes nd-spin { to { transform: rotate(360deg); } }
  .test-result { margin: .3rem 0 .8rem; font-size: .85rem; }
  .test-result.ok { color: #1a7f37; }
  .test-result.bad { color: #cf222e; }
</style>
</head>
<body>
<h1>nd-uplink config</h1>
<p class="muted">Modem/SIM lookup tables and uplink status for this drone's ZTE MF79U + NetworkManager stack.</p>

<h2>Uplink status</h2>
<table id="statusTable"><tbody><tr><td colspan="2"><span class="spinner"></span>Loading…</td></tr></tbody></table>

<h2>Modems</h2>
<table id="modemsTable"><thead><tr><th>Label</th><th>IMEI</th><th>Password</th><th>Active</th><th></th></tr></thead><tbody></tbody></table>
<form class="inline" id="addModemForm">
  <input name="label" placeholder="Label (e.g. Modem A)">
  <input name="imei" placeholder="IMEI" required>
  <button type="button" id="detectImei">Detect</button>
  <input name="password" type="password" placeholder="WebUI password" required>
  <button type="submit">Add modem</button>
</form>
<div id="modemTestResult" class="test-result"></div>

<h2>SIM cards</h2>
<table id="simsTable"><thead><tr><th>Label</th><th>IMSI</th><th>PIN</th><th>Active</th><th></th></tr></thead><tbody></tbody></table>
<form class="inline" id="addSimForm">
  <input name="label" placeholder="Label (e.g. Carrier X)">
  <input name="imsi" placeholder="IMSI" required>
  <input name="pin" placeholder="PIN (blank if none)">
  <button type="submit">Add SIM</button>
</form>
<div id="simTestResult" class="test-result"></div>
<p class="muted">Adding a SIM immediately attempts ONE real PIN unlock against the config UI's active modem — a wrong PIN counts toward the carrier's PUK lockout (usually 3 tries), so double-check it first. IMSI isn't readable until a registered modem has logged in once — run "unlock now" after adding a modem, then check the logs below for the detected IMSI.</p>

<h2>Actions</h2>
<button id="runUnlock">Run modem unlock now</button>
<div id="unlockLog" class="muted">(no log fetched yet)</div>

<h2>Service logs</h2>
<form class="inline">
  <select id="serviceSelect">
    <option value="nd-uplink-manager.service">nd-uplink-manager (network failover)</option>
    <option value="nd-modem-webui.service">nd-modem-webui (this config UI)</option>
  </select>
  <button type="button" id="refreshServiceLog">Refresh</button>
</form>
<div id="serviceLog" class="muted">(no log fetched yet)</div>

<script>
async function api(path, opts) {
  const res = await fetch(path, opts);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || res.statusText);
  return body;
}
function pill(ok, text) { return `<span class="pill ${ok ? 'ok' : 'bad'}">${text}</span>`; }

function uplinkType(s) {
  if (!s.uplink.iface) return '';
  if (s.lte.iface && s.uplink.iface === s.lte.iface) return 'Mobile Network';
  if (s.wifi.device && s.uplink.iface === s.wifi.device) return 'Wifi';
  if (s.ethernet.device && s.uplink.iface === s.ethernet.device) return 'Wired Network';
  return '';
}

function mobileDataValue(s) {
  // Independent of whatever the current default route is — checked directly
  // against the LTE interface, so this reflects the modem/SIM's own data
  // connectivity even when Ethernet/WiFi is actually carrying traffic.
  // No network interface at all is normal while the modem is present but
  // still SIM/PIN-locked — that's a different state from no modem being
  // plugged in, so don't collapse the two into the same wording.
  if (!s.lte.usb_present) return pill(false, 'no modem');
  if (!s.lte.iface) return pill(false, 'locked / no data interface');
  if (s.lte.data_ok === true) return pill(true, 'reachable');
  if (s.lte.data_ok === false) return pill(false, 'unreachable');
  return pill(false, 'unknown (needs root)');
}

let statusInFlight = false;
async function refreshStatus() {
  // /api/status can take several seconds (ping/HTTPS checks) — never let a
  // slow call overlap with the next 15s tick, or requests just pile up.
  if (statusInFlight) return;
  statusInFlight = true;
  const tbody = document.querySelector('#statusTable tbody');
  try {
    const s = await api('/api/status');
    const type = uplinkType(s);
    const routeValue = s.uplink.iface ? (s.uplink.iface + (type ? ` (${type})` : '')) : 'none';
    const rows = [
      ['Mobile Network', s.lte.usb_present ? pill(true, 'modem present') : pill(false, 'no modem found')],
      ['Onboard WiFi Module', s.wifi.mode + (s.wifi.ssid ? ' — ' + s.wifi.ssid : '')],
      ['Wired Network', s.ethernet.mode + (s.ethernet.ip ? ' — ' + s.ethernet.ip : '')],
      ['Default route', routeValue],
      ['Mobile Data', mobileDataValue(s)],
    ];
    tbody.innerHTML = rows.map(([k, v]) => `<tr><td>${k}</td><td>${v}</td></tr>`).join('');
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="2">status unavailable: ${e.message}</td></tr>`;
  } finally {
    statusInFlight = false;
  }
}

async function refreshModems() {
  const tbody = document.querySelector('#modemsTable tbody');
  try {
    const [modems, active] = await Promise.all([api('/api/modems'), api('/api/active')]);
    tbody.innerHTML = modems.map(m => `
      <tr>
        <td>${m.label || ''}</td>
        <td>${m.imei}</td>
        <td>${m.password_set ? pill(true, 'set') : pill(false, 'missing')}</td>
        <td>${active.modem_imei === m.imei ? pill(true, 'active') : `<button data-imei="${m.imei}" class="activateModem">make active</button>`}</td>
        <td><button data-imei="${m.imei}" class="danger deleteModem">delete</button></td>
      </tr>`).join('') || '<tr><td colspan="5" class="muted">No modems registered yet.</td></tr>';
    tbody.querySelectorAll('.deleteModem').forEach(b => b.onclick = async () => { await api(`/api/modems/${b.dataset.imei}`, {method: 'DELETE'}); refreshModems(); });
    tbody.querySelectorAll('.activateModem').forEach(b => b.onclick = async () => { await api(`/api/modems/${b.dataset.imei}/activate`, {method: 'POST'}); refreshModems(); });
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="5">modems unavailable: ${e.message}</td></tr>`;
  }
}

async function refreshSims() {
  const tbody = document.querySelector('#simsTable tbody');
  try {
    const [sims, active] = await Promise.all([api('/api/sims'), api('/api/active')]);
    tbody.innerHTML = sims.map(s => `
      <tr>
        <td>${s.label || ''}</td>
        <td>${s.imsi}</td>
        <td>${s.pin_set ? pill(true, 'set') : pill(false, 'none')}</td>
        <td>${active.sim_imsi === s.imsi ? pill(true, 'active') : `<button data-imsi="${s.imsi}" class="activateSim">make active</button>`}</td>
        <td><button data-imsi="${s.imsi}" class="danger deleteSim">delete</button></td>
      </tr>`).join('') || '<tr><td colspan="5" class="muted">No SIMs registered yet.</td></tr>';
    tbody.querySelectorAll('.deleteSim').forEach(b => b.onclick = async () => { await api(`/api/sims/${b.dataset.imsi}`, {method: 'DELETE'}); refreshSims(); });
    tbody.querySelectorAll('.activateSim').forEach(b => b.onclick = async () => { await api(`/api/sims/${b.dataset.imsi}/activate`, {method: 'POST'}); refreshSims(); });
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="5">SIMs unavailable: ${e.message}</td></tr>`;
  }
}

document.getElementById('detectImei').onclick = async () => {
  const btn = document.getElementById('detectImei');
  btn.textContent = 'Detecting…';
  try {
    const r = await api('/api/detect');
    document.querySelector('#addModemForm input[name=imei]').value = r.imei || '';
    btn.textContent = r.imei ? 'Detect' : 'Not available';
  } catch (e) { btn.textContent = 'Detect'; alert(e.message); }
  setTimeout(() => btn.textContent = 'Detect', 2000);
};

function showTestResult(elId, ok, text) {
  const el = document.getElementById(elId);
  el.className = 'test-result ' + (ok ? 'ok' : 'bad');
  el.textContent = text;
}

document.getElementById('addModemForm').onsubmit = async (ev) => {
  ev.preventDefault();
  const f = new FormData(ev.target);
  showTestResult('modemTestResult', true, 'Testing login…');
  try {
    const r = await api('/api/modems', {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(Object.fromEntries(f))});
    const t = r.login_test || {};
    if (t.ok && t.imei_mismatch) {
      showTestResult('modemTestResult', false, `Saved, but login test's modem (IMEI ${t.imei}) doesn't match what you entered — wrong modem plugged in?`);
    } else if (t.ok) {
      showTestResult('modemTestResult', true, 'Saved — login test succeeded.');
    } else {
      showTestResult('modemTestResult', false, `Saved, but login test failed: ${t.error || 'unknown error'} (modem may not be plugged in yet)`);
    }
    ev.target.reset();
    refreshModems();
  } catch (e) {
    showTestResult('modemTestResult', false, 'Not saved: ' + e.message);
  }
};

document.getElementById('addSimForm').onsubmit = async (ev) => {
  ev.preventDefault();
  const pin = ev.target.pin.value;
  if (pin && !confirm(
    'This will attempt ONE real PIN unlock against the currently active modem right now.\n\n' +
    'A wrong PIN counts toward the SIM’s PUK lockout (usually 3 tries total). Continue?'
  )) {
    return;
  }
  const f = new FormData(ev.target);
  showTestResult('simTestResult', true, pin ? 'Testing PIN…' : 'Saving…');
  try {
    const r = await api('/api/sims', {method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(Object.fromEntries(f))});
    const t = r.pin_test || {};
    if (t.ok) {
      showTestResult('simTestResult', true, `Saved — SIM unlocked (IMSI ${t.imsi}).`);
    } else if (t.skipped) {
      showTestResult('simTestResult', true, 'Saved (no PIN provided, so no unlock was attempted).');
    } else {
      showTestResult('simTestResult', false, `Saved, but PIN test failed: ${t.error || 'unknown error'}`);
    }
    ev.target.reset();
    refreshSims();
  } catch (e) {
    showTestResult('simTestResult', false, 'Not saved: ' + e.message);
  }
};

document.getElementById('runUnlock').onclick = async () => {
  await api('/api/unlock', {method: 'POST'});
  setTimeout(refreshUnlockLog, 2000);
};
async function refreshUnlockLog() {
  const r = await api('/api/unlock/log');
  document.getElementById('unlockLog').textContent = r.log || '(no log entries yet)';
}

async function refreshServiceLog() {
  const unit = document.getElementById('serviceSelect').value;
  const el = document.getElementById('serviceLog');
  try {
    const r = await api('/api/service-log?unit=' + encodeURIComponent(unit));
    el.textContent = r.log || '(no log entries yet)';
  } catch (e) {
    el.textContent = 'error: ' + e.message;
  }
}
document.getElementById('refreshServiceLog').onclick = refreshServiceLog;
document.getElementById('serviceSelect').onchange = refreshServiceLog;

refreshStatus(); refreshModems(); refreshSims(); refreshUnlockLog(); refreshServiceLog();
setInterval(refreshStatus, 15000);
</script>
</body>
</html>
"""


# --- bind: localhost + this device's LAN-facing (hotspot/eth-server)      --
# addresses only — deliberately not 0.0.0.0, so the config UI isn't exposed
# on any external network the Jetson might join as a WiFi client.

NDCOMMON_LIB = os.environ.get("ND_COMMON_LIB", "/opt/nd-uplink/lib/nd-common.sh")
BIND_RETRIES = int(os.environ.get("ND_WEBUI_BIND_RETRIES", "10"))
BIND_DELAY = float(os.environ.get("ND_WEBUI_BIND_DELAY", "3"))


def _managed_lan_addresses(retries=BIND_RETRIES, delay=BIND_DELAY):
    """Best-effort: ask lib/nd-common.sh which interfaces it manages, and
    return their current IPv4 addresses. Retries briefly at boot since the
    hotspot/eth-server may still be coming up when this service starts."""
    script = (
        f"_LIB={NDCOMMON_LIB}; "
        "[ -r \"$_LIB\" ] && . \"$_LIB\" && nd_managed_ifaces"
    )
    for attempt in range(retries):
        try:
            out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=5).stdout
            ifaces = [l.strip() for l in out.splitlines() if l.strip()]
        except Exception:
            ifaces = []
        addrs = []
        for iface in ifaces:
            try:
                out = subprocess.run(
                    ["ip", "-4", "-o", "addr", "show", "dev", iface],
                    capture_output=True, text=True, timeout=5,
                ).stdout
                for line in out.splitlines():
                    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", line)
                    if m:
                        addrs.append(m.group(1))
            except Exception:
                continue
        if addrs or attempt == retries - 1:
            return addrs
        time.sleep(delay)
    return []


def main():
    addresses = ["127.0.0.1"] + _managed_lan_addresses()
    servers = []
    for addr in dict.fromkeys(addresses):  # de-dup, preserve order
        try:
            srv = ThreadingHTTPServer((addr, PORT), Handler)
            servers.append(srv)
            print(f"nd-modem-webui: listening on http://{addr}:{PORT}", file=sys.stderr)
        except OSError as e:
            print(f"nd-modem-webui: could not bind {addr}:{PORT} ({e}) — skipping", file=sys.stderr)

    if not servers:
        print("nd-modem-webui: no addresses could be bound — exiting", file=sys.stderr)
        sys.exit(1)

    import threading
    for srv in servers[1:]:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
