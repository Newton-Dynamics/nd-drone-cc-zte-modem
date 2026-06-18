#!/usr/bin/env python3
# nd-net-ui — lightweight operational UI for the Jetson networking stack.
#
# Installed to: /opt/nd-net/nd-net-ui.py  (run by nd-net-ui.service)
#
# Serves a single-page dashboard that:
#   - shows nd-net-status output, the nd-net-manager service state, recent
#     journal logs, and the last known modem/SIM state;
#   - lets you view and edit the two .env files (/opt/zte/.env and
#     /opt/nd-net/.env). Secret keys are masked in the form with a reveal
#     toggle; values are written back atomically;
#   - lets you start / stop / restart nd-net-manager.service.
#
# Design constraints (match the rest of this repo):
#   - Python 3 standard library ONLY. No pip dependencies.
#   - No auth by design — bind to the LAN/hotspot gateway IPs only (10.42.x.1),
#     never 0.0.0.0. The bind addresses are configurable via the UI's own .env.
#
# Config (env, or /opt/nd-net/nd-net-ui.env):
#   ND_UI_BIND        space/comma-separated IPs to bind (default: 10.42.0.1 10.42.1.1 127.0.0.1)
#   ND_UI_PORT        TCP port (default: 8088)
#   ZTE_ENV_FILE      path to the ZTE .env  (default: /opt/zte/.env)
#   ND_NET_ENV_FILE   path to the nd-net .env (default: /opt/nd-net/.env)
#   ND_NET_SERVICE    systemd unit to control (default: nd-net-manager.service)
#   ND_UI_STATUS_CMD  status command to run (default: nd-net-status)
#
import html
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote

# --- configuration -----------------------------------------------------------

def _env(name, default):
    v = os.environ.get(name)
    return v if v not in (None, "") else default

ZTE_ENV_FILE    = _env("ZTE_ENV_FILE", "/opt/zte/.env")
ND_NET_ENV_FILE = _env("ND_NET_ENV_FILE", "/opt/nd-net/.env")
SERVICE         = _env("ND_NET_SERVICE", "nd-net-manager.service")
STATUS_CMD      = _env("ND_UI_STATUS_CMD", "nd-net-status")
PORT            = int(_env("ND_UI_PORT", "8088"))
BIND_RAW        = _env("ND_UI_BIND", "10.42.0.1 10.42.1.1 127.0.0.1")

# Files the UI is allowed to read/write. Anything not in this map is rejected,
# so a crafted request can never point the editor at an arbitrary path.
ENV_FILES = {
    "zte":    {"label": "ZTE modem (/opt/zte/.env)",    "path": ZTE_ENV_FILE},
    "nd_net": {"label": "nd-net manager (/opt/nd-net/.env)", "path": ND_NET_ENV_FILE},
}

# Device registry module (sticks/SIMs). Loaded from a sibling file (repo) or the
# installed path. If it can't be loaded the device panel degrades gracefully.
def _load_registry_module():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, "nd-modem-registry.py"),
                 "/opt/nd-net/nd-modem-registry.py"):
        if os.path.exists(cand):
            try:
                spec = importlib.util.spec_from_file_location("nd_modem_registry", cand)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                return mod
            except Exception as e:  # noqa: BLE001
                print(f"[nd-net-ui] registry module load failed ({cand}): {e}", flush=True)
    return None

REG = _load_registry_module()

# Keys whose values are secret: masked in the form, only written when changed.
SECRET_KEY_RE = re.compile(r"(PASSWORD|PASSWD|PSK|PIN|SECRET|TOKEN|KEY)$", re.I)

# A conservative .env key matcher (KEY=VALUE; KEY is shell-ish).
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# --- .env parsing / writing --------------------------------------------------
# We preserve the file's existing line order, comments, and blank lines. Editing
# a key rewrites only that line's value; adding a key appends it. This keeps the
# hand-maintained .env files readable rather than serializing a flat dict.

def is_secret(key):
    return bool(SECRET_KEY_RE.search(key))

def _strip_quotes(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v

def parse_env(path):
    """Return (ordered list of (key, value) for assignment lines, raw_lines)."""
    pairs = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read().splitlines()
    except FileNotFoundError:
        return [], []
    for line in raw:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        body = s[len("export "):] if s.startswith("export ") else s
        if "=" not in body:
            continue
        key, val = body.split("=", 1)
        key = key.strip()
        if not KEY_RE.match(key):
            continue
        pairs.append((key, _strip_quotes(val)))
    return pairs, raw

def _needs_quoting(v):
    return v == "" or re.search(r"[\s#'\"$`\\]", v) is not None

def _format_value(v):
    if _needs_quoting(v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
    return v

def write_env(path, updates):
    """Apply {key: value} updates to the file at `path`, preserving layout.

    Lines that assign a known key are rewritten in place; keys not already
    present are appended. Comments/blanks/unrelated lines are untouched.
    Written atomically (temp file + rename) with 0600 perms (secrets inside).
    """
    _, raw = parse_env(path)
    remaining = dict(updates)
    out = []
    for line in raw:
        s = line.strip()
        if not s or s.startswith("#"):
            out.append(line)
            continue
        prefix = "export " if s.startswith("export ") else ""
        body = s[len("export "):] if prefix else s
        if "=" in body:
            key = body.split("=", 1)[0].strip()
            if key in remaining:
                out.append(f"{prefix}{key}={_format_value(remaining.pop(key))}")
                continue
        out.append(line)
    for key, val in remaining.items():
        out.append(f"{key}={_format_value(val)}")

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".env.", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + "\n")
        os.chmod(tmp, 0o600)
        # Preserve existing ownership if we can (we may run as root).
        try:
            st = os.stat(path)
            os.chown(tmp, st.st_uid, st.st_gid)
        except FileNotFoundError:
            pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

# --- system probes -----------------------------------------------------------

def run(cmd, timeout=15):
    """Run a command, return (rc, combined_output). Never raises."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True)
        return p.returncode, p.stdout
    except FileNotFoundError:
        return 127, f"command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s: {' '.join(cmd)}"
    except Exception as e:  # noqa: BLE001 — surface anything to the UI
        return 1, f"error running {' '.join(cmd)}: {e}"

# Strip ANSI color codes (nd-net-status emits them when it thinks it's a tty).
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

def status_text():
    rc, out = run([STATUS_CMD], timeout=30)
    if rc == 127:
        # Fall back to the in-repo path if the symlink isn't installed.
        for cand in ("/opt/nd-net/nd-net-status.sh", "./nd-net-status.sh"):
            if os.path.exists(cand):
                rc, out = run([cand], timeout=30)
                break
    return ANSI_RE.sub("", out)

def service_active():
    rc, out = run(["systemctl", "is-active", SERVICE], timeout=10)
    return out.strip()

def service_status():
    rc, out = run(["systemctl", "status", "--no-pager", "-n", "0", SERVICE], timeout=10)
    return out

def journal_tail(lines=60, tag="nd-net"):
    rc, out = run(["journalctl", "-t", tag, "-n", str(lines), "--no-pager", "-o", "short-iso"],
                  timeout=15)
    return out

# Last modem/SIM state, parsed from the ZTE handler's journal tag (nd-nm-zte-modem).
def modem_state():
    rc, out = run(["journalctl", "-t", "nd-nm-zte-modem", "-n", "200", "--no-pager",
                   "-o", "short-iso"], timeout=15)
    fields = {}
    patterns = {
        "ZTE_HOST":         re.compile(r"ZTE_HOST=(\S+)"),
        "MODEM_MAIN_STATE": re.compile(r"MODEM_MAIN_STATE:(\S+)"),
        "Login":            re.compile(r"Login (successful|failed[^\n]*)"),
        "SIM":              re.compile(r"SIM (unlocked|unlocking failed)"),
    }
    for line in out.splitlines():
        for name, pat in patterns.items():
            m = pat.search(line)
            if m:
                fields[name] = m.group(1) if m.lastindex else m.group(0)
    return fields, out

# --- HTML --------------------------------------------------------------------

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nd-net control</title>
<style>
  :root {{ --bg:#0d1117; --panel:#161b22; --line:#30363d; --fg:#e6edf3;
           --muted:#8b949e; --ok:#3fb950; --warn:#d29922; --bad:#f85149;
           --accent:#388bfd; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg);
          font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }}
  header {{ padding:14px 18px; border-bottom:1px solid var(--line);
            display:flex; align-items:center; gap:14px; flex-wrap:wrap; }}
  header h1 {{ font-size:16px; margin:0; }}
  .wrap {{ max-width:980px; margin:0 auto; padding:18px; }}
  .grid {{ display:grid; gap:18px; grid-template-columns:1fr; }}
  @media(min-width:760px) {{ .grid {{ grid-template-columns:1fr 1fr; }}
                             .grid .full {{ grid-column:1 / -1; }} }}
  .panel {{ background:var(--panel); border:1px solid var(--line);
            border-radius:8px; padding:14px 16px; }}
  .panel h2 {{ font-size:13px; text-transform:uppercase; letter-spacing:.06em;
               color:var(--muted); margin:0 0 10px; }}
  pre {{ margin:0; white-space:pre-wrap; word-break:break-word;
         max-height:360px; overflow:auto; font-size:12.5px; }}
  .pill {{ display:inline-block; padding:2px 9px; border-radius:999px;
           font-size:12px; font-weight:600; }}
  .pill.ok {{ background:rgba(63,185,80,.15); color:var(--ok); }}
  .pill.bad {{ background:rgba(248,81,73,.15); color:var(--bad); }}
  .pill.warn {{ background:rgba(210,153,34,.15); color:var(--warn); }}
  form.act {{ display:inline; }}
  button {{ font:inherit; cursor:pointer; border:1px solid var(--line);
            background:#21262d; color:var(--fg); padding:6px 12px;
            border-radius:6px; }}
  button:hover {{ border-color:var(--accent); }}
  button.bad {{ color:var(--bad); }}
  table.env {{ width:100%; border-collapse:collapse; }}
  table.env td {{ padding:5px 6px; vertical-align:middle; }}
  table.env td.k {{ color:var(--accent); white-space:nowrap; padding-right:12px; }}
  table.env th {{ text-align:left; color:var(--muted); font-weight:600;
                  font-size:11px; text-transform:uppercase; letter-spacing:.05em;
                  border-bottom:1px solid var(--line); padding:4px 6px; }}
  .addform {{ margin-top:12px; padding-top:10px; border-top:1px solid var(--line); }}
  .active-ok {{ border-left:3px solid var(--ok); }}
  .active-warn {{ border-left:3px solid var(--warn); }}
  .active-bad {{ border-left:3px solid var(--bad); }}
  input[type=text], input[type=password] {{ width:100%; font:inherit;
            background:var(--bg); color:var(--fg); border:1px solid var(--line);
            border-radius:5px; padding:5px 8px; }}
  .reveal {{ background:none; border:none; color:var(--muted); padding:0 6px;
             cursor:pointer; }}
  .flash {{ padding:10px 14px; border-radius:6px; margin-bottom:14px; }}
  .flash.ok {{ background:rgba(63,185,80,.12); border:1px solid var(--ok); }}
  .flash.bad {{ background:rgba(248,81,73,.12); border:1px solid var(--bad); }}
  .muted {{ color:var(--muted); }}
  .row {{ display:flex; gap:8px; align-items:center; flex-wrap:wrap; }}
  a {{ color:var(--accent); }}
</style></head>
<body>
<header>
  <h1>nd-net control</h1>
  <span class="muted">{host}</span>
  <span style="margin-left:auto" class="row">
    service: {svc_pill}
    <form class="act" method="post" action="/svc">
      <input type="hidden" name="action" value="restart">
      <button>restart</button></form>
    <form class="act" method="post" action="/svc">
      <input type="hidden" name="action" value="start">
      <button>start</button></form>
    <form class="act" method="post" action="/svc"
          onsubmit="return confirm('Stop {service}? LAN clients may lose networking.')">
      <input type="hidden" name="action" value="stop">
      <button class="bad">stop</button></form>
    <a href="/" title="refresh">↻</a>
  </span>
</header>
<div class="wrap">
  {flash}
  <div class="grid">
    {active_mode}
    {devices}
    {env_panels}
    <div class="panel full">
      <h2>nd-net-status</h2>
      <pre>{status}</pre>
    </div>
    <div class="panel">
      <h2>service · {service}</h2>
      <pre>{svc_status}</pre>
    </div>
    <div class="panel">
      <h2>modem / SIM (last known)</h2>
      {modem}
    </div>
    <div class="panel full">
      <h2>journal · nd-net (last 60)</h2>
      <pre>{journal}</pre>
    </div>
    <div class="panel full">
      <h2>journal · modem handler (last 60)</h2>
      <pre>{modem_log}</pre>
    </div>
  </div>
  <p class="muted" style="margin-top:18px">
    Read-only viewer + .env editor. Secret values are masked; toggle the eye to
    reveal. Editing an .env then restarting the service applies changes.
  </p>
</div>
<script>
function tog(btn){{ var i=btn.previousElementSibling;
  i.type = i.type==='password' ? 'text':'password';
  btn.textContent = i.type==='password' ? '👁' : '🙈'; }}
</script>
</body></html>"""

def esc(s):
    return html.escape(s if s is not None else "")

def render_env_panel(slug, meta):
    pairs, _ = parse_env(meta["path"])
    rows = []
    if not pairs and not os.path.exists(meta["path"]):
        rows.append(f'<tr><td colspan="2" class="muted">file not found: {esc(meta["path"])} — '
                    f'saving will create it</td></tr>')
    for key, val in pairs:
        secret = is_secret(key)
        # For secrets we render an empty password field with a placeholder; a
        # blank submit leaves the stored value untouched (see handler).
        if secret:
            field = (f'<input type="password" name="v_{esc(key)}" value="{esc(val)}" '
                     f'autocomplete="off">'
                     f'<button type="button" class="reveal" onclick="tog(this)">👁</button>')
            cell = f'<div class="row">{field}</div>'
        else:
            cell = f'<input type="text" name="v_{esc(key)}" value="{esc(val)}">'
        rows.append(f'<tr><td class="k">{esc(key)}</td><td>{cell}</td></tr>')
    body = "\n".join(rows) if rows else '<tr><td class="muted">(no keys)</td></tr>'
    return f"""
    <div class="panel">
      <h2>.env · {esc(meta['label'])}</h2>
      <form method="post" action="/env">
        <input type="hidden" name="file" value="{esc(slug)}">
        <table class="env"><tbody>{body}</tbody></table>
        <div class="row" style="margin-top:10px">
          <button>save</button>
          <span class="muted">→ then restart the service to apply</span>
        </div>
      </form>
    </div>"""

def render_modem(fields):
    if not fields:
        return '<span class="muted">no modem-handler log entries found</span>'
    rows = []
    for k in ("ZTE_HOST", "Login", "SIM", "MODEM_MAIN_STATE"):
        if k in fields:
            rows.append(f'<tr><td class="k">{esc(k)}</td><td>{esc(str(fields[k]))}</td></tr>')
    return f'<table class="env"><tbody>{"".join(rows)}</tbody></table>'

def _env_fallback_active():
    """True if /opt/zte/.env still carries a single-device ZTE_PASSWORD/ZTE_PIN
    that the unlock would fall back to when the registry has no match."""
    try:
        pairs = dict(parse_env(ENV_FILES["zte"]["path"])[0])  # (pairs, raw)
    except Exception:  # noqa: BLE001
        return False
    return bool(pairs.get("ZTE_PASSWORD")) or bool(pairs.get("ZTE_PIN"))


def render_active_mode():
    """A banner stating, in plain terms, which unlock secret-source is in effect:
    the multi-device registry, or the legacy single-device .env fallback."""
    if REG is None:
        return ''
    try:
        view = REG.public_view(reveal=False)
        n_sticks, n_sims = len(view["sticks"]), len(view["sims"])
    except Exception:  # noqa: BLE001
        n_sticks = n_sims = 0
    env_fb = _env_fallback_active()

    if n_sticks or n_sims:
        title = "MULTI-DEVICE mode active"
        detail = (f"The unlock matches each modem against the registry "
                  f"({n_sticks} stick(s), {n_sims} SIM(s)) — the login password "
                  f"by the stick's IMEI, the PIN by the inserted SIM's IMSI.")
        if env_fb:
            detail += (" The legacy ZTE_PASSWORD/ZTE_PIN in /opt/zte/.env are "
                       "kept only as a fallback for a modem with no registry match.")
        cls = "ok"
    elif env_fb:
        title = "SINGLE-DEVICE mode active (.env fallback)"
        detail = ("The registry is empty, so the unlock uses the single "
                  "ZTE_PASSWORD / ZTE_PIN from /opt/zte/.env — exactly as before. "
                  "Add a stick + SIM below to switch to multi-device matching.")
        cls = "warn"
    else:
        title = "NO unlock secrets configured"
        detail = ("The registry is empty and /opt/zte/.env has no ZTE_PASSWORD / "
                  "ZTE_PIN — the modem cannot be unlocked. Add a stick + SIM below, "
                  "or set the .env fallback.")
        cls = "bad"

    return (f'<div class="panel full active-{cls}">'
            f'<h2>unlock mode</h2>'
            f'<div class="row"><span class="pill {cls}">{esc(title)}</span></div>'
            f'<p class="muted" style="margin-top:8px">{esc(detail)}</p></div>')


def _stick_table(view):
    rows = []
    for s in view["sticks"]:
        rows.append(
            f'<tr><td class="k">{esc(s["imei"])}</td>'
            f'<td>{esc(s["password"])}</td>'
            f'<td>{esc(s["label"])}</td>'
            f'<td class="muted">{esc(str(s["last_seen"] or "—"))}</td>'
            f'<td><form class="act" method="post" action="/device" '
            f'onsubmit="return confirm(\'Remove stick {esc(s["imei"])}?\')">'
            f'<input type="hidden" name="op" value="rm-stick">'
            f'<input type="hidden" name="imei" value="{esc(s["imei"])}">'
            f'<button class="bad">remove</button></form></td></tr>')
    if not rows:
        rows.append('<tr><td colspan="5" class="muted">no LTE sticks registered</td></tr>')
    return ''.join(rows)


def _sim_table(view):
    rows = []
    for s in view["sims"]:
        rows.append(
            f'<tr><td class="k">{esc(s["imsi"])}</td>'
            f'<td>{esc(s["pin"])}</td>'
            f'<td>{esc(s["label"])}</td>'
            f'<td class="muted">{esc(str(s["last_seen"] or "—"))}</td>'
            f'<td><form class="act" method="post" action="/device" '
            f'onsubmit="return confirm(\'Remove SIM {esc(s["imsi"])}?\')">'
            f'<input type="hidden" name="op" value="rm-sim">'
            f'<input type="hidden" name="imsi" value="{esc(s["imsi"])}">'
            f'<button class="bad">remove</button></form></td></tr>')
    if not rows:
        rows.append('<tr><td colspan="5" class="muted">no SIM cards registered</td></tr>')
    return ''.join(rows)


def render_devices():
    if REG is None:
        return ('<div class="panel full"><h2>LTE sticks</h2>'
                '<span class="muted">registry module not available '
                '(nd-modem-registry.py not found)</span></div>')
    try:
        view = REG.public_view(reveal=False)
    except Exception as e:  # noqa: BLE001
        return (f'<div class="panel full"><h2>LTE sticks</h2>'
                f'<span class="muted">registry error: {esc(str(e))}</span></div>')

    # Four distinct panels: a list + a separate "add" section for sticks, and the
    # same for SIM cards. Add-forms are visually separated from the lists.
    return f"""
    <div class="panel full">
      <h2>LTE sticks — registered</h2>
      <table class="env"><thead><tr>
        <th>IMEI</th><th>password</th><th>label</th><th>last seen</th><th></th>
      </tr></thead><tbody>{_stick_table(view)}</tbody></table>
    </div>
    <div class="panel full">
      <h2>add an LTE stick</h2>
      <p class="muted" style="margin:0 0 10px">
        The modem login password belongs to the stick hardware, matched by its IMEI.
      </p>
      <form method="post" action="/device">
        <input type="hidden" name="op" value="add-stick">
        <table class="env"><tbody>
          <tr><td class="k">IMEI</td><td>
            <input type="text" name="imei" placeholder="14-16 digits" required></td></tr>
          <tr><td class="k">password</td><td><div class="row">
            <input type="password" name="password" placeholder="modem login password" required>
            <button type="button" class="reveal" onclick="tog(this)">👁</button></div></td></tr>
          <tr><td class="k">label</td><td>
            <input type="text" name="label" placeholder="optional (e.g. stick-A)"></td></tr>
        </tbody></table>
        <div class="row" style="margin-top:10px"><button>add stick</button></div>
      </form>
    </div>
    <div class="panel full">
      <h2>SIM cards — registered</h2>
      <table class="env"><thead><tr>
        <th>IMSI</th><th>PIN</th><th>label</th><th>last seen</th><th></th>
      </tr></thead><tbody>{_sim_table(view)}</tbody></table>
    </div>
    <div class="panel full">
      <h2>add a SIM card</h2>
      <p class="muted" style="margin:0 0 10px">
        The PIN belongs to the SIM card, matched by its IMSI. A SIM keeps its PIN
        when moved into another stick.
      </p>
      <form method="post" action="/device">
        <input type="hidden" name="op" value="add-sim">
        <table class="env"><tbody>
          <tr><td class="k">IMSI</td><td>
            <input type="text" name="imsi" placeholder="6-15 digits" required></td></tr>
          <tr><td class="k">PIN</td><td><div class="row">
            <input type="password" name="pin" placeholder="4-8 digits" required>
            <button type="button" class="reveal" onclick="tog(this)">👁</button></div></td></tr>
          <tr><td class="k">label</td><td>
            <input type="text" name="label" placeholder="optional (e.g. carrier name)"></td></tr>
        </tbody></table>
        <div class="row" style="margin-top:10px"><button>add SIM</button></div>
      </form>
    </div>"""


def svc_pill(state):
    cls = {"active": "ok", "failed": "bad"}.get(state, "warn")
    return f'<span class="pill {cls}">{esc(state or "unknown")}</span>'

def render_page(flash=None):
    state = service_active()
    mfields, mlog = modem_state()
    env_panels = "\n".join(render_env_panel(s, m) for s, m in ENV_FILES.items())
    flash_html = ""
    if flash:
        kind, text = flash
        flash_html = f'<div class="flash {kind}">{esc(text)}</div>'
    return PAGE.format(
        host=esc(socket.gethostname()),
        service=esc(SERVICE),
        svc_pill=svc_pill(state),
        flash=flash_html,
        active_mode=render_active_mode(),
        devices=render_devices(),
        env_panels=env_panels,
        status=esc(status_text()),
        svc_status=esc(service_status()),
        modem=render_modem(mfields),
        journal=esc(journal_tail()),
        modem_log=esc(mlog or "(none)"),
    )

# --- HTTP handler ------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "nd-net-ui"

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _flash_redirect(self, kind, message):
        # kind is "ok" or "err"; message is URL-encoded so non-ASCII (em dash,
        # systemctl output) is safe in the latin-1-only Location header. The
        # value is HTML-escaped on the way back out in render_page().
        self._redirect("/?%s=%s" % (kind, quote(message, safe="")))

    def _read_form(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        return parse_qs(raw, keep_blank_values=True)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            q = parse_qs(urlparse(self.path).query)
            flash = None
            if "ok" in q:
                flash = ("ok", q["ok"][0])
            elif "err" in q:
                flash = ("bad", q["err"][0])
            self._send(200, render_page(flash))
        elif path == "/healthz":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        elif path == "/api/status":
            payload = {
                "service": service_active(),
                "status": status_text(),
                "modem": modem_state()[0],
            }
            self._send(200, json.dumps(payload, indent=2),
                       "application/json; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    do_HEAD = do_GET

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/svc":
            self._handle_svc()
        elif path == "/env":
            self._handle_env()
        elif path == "/device":
            self._handle_device()
        else:
            self._send(404, "not found\n", "text/plain; charset=utf-8")

    def _handle_svc(self):
        form = self._read_form()
        action = (form.get("action", [""])[0]).strip()
        if action not in ("start", "stop", "restart"):
            self._flash_redirect("err", "invalid service action")
            return
        rc, out = run(["systemctl", action, SERVICE], timeout=30)
        if rc == 0:
            self._flash_redirect("ok", f"service {action} ok")
        else:
            msg = (out or "").strip().splitlines()
            tail = msg[-1] if msg else f"rc={rc}"
            self._flash_redirect("err", f"{action} failed: {tail}")

    def _handle_env(self):
        form = self._read_form()
        slug = form.get("file", [""])[0]
        meta = ENV_FILES.get(slug)
        if not meta:
            self._flash_redirect("err", "unknown env file")
            return
        existing = dict(parse_env(meta["path"])[0])
        updates = {}
        for field, vals in form.items():
            if not field.startswith("v_"):
                continue
            key = field[2:]
            if not KEY_RE.match(key):
                continue
            new = vals[0]
            if is_secret(key) and new == "":
                # Blank secret field => keep the stored value unchanged.
                continue
            # Only write keys we already know, or genuinely new non-empty ones.
            if key in existing or new != "":
                updates[key] = new
        try:
            write_env(meta["path"], updates)
        except Exception as e:  # noqa: BLE001
            self._flash_redirect("err", f"write failed: {e}")
            return
        self._flash_redirect("ok", f"saved {os.path.basename(meta['path'])} "
                                   f"({len(updates)} key(s)) — restart to apply")

    def _handle_device(self):
        if REG is None:
            self._flash_redirect("err", "registry module not available")
            return
        form = self._read_form()
        op = form.get("op", [""])[0]
        g = lambda k: (form.get(k, [""])[0] or "").strip()  # noqa: E731
        try:
            if op == "add-stick":
                imei = REG.add_stick(g("imei"), g("password"), g("label"))
                self._flash_redirect("ok", f"added/updated stick {imei}")
            elif op == "add-sim":
                imsi = REG.add_sim(g("imsi"), g("pin"), g("label"))
                self._flash_redirect("ok", f"added/updated SIM {imsi}")
            elif op == "rm-stick":
                n = REG.rm_stick(g("imei"))
                self._flash_redirect("ok" if n else "err",
                                     f"removed stick {g('imei')}" if n else "stick not found")
            elif op == "rm-sim":
                n = REG.rm_sim(g("imsi"))
                self._flash_redirect("ok" if n else "err",
                                     f"removed SIM {g('imsi')}" if n else "SIM not found")
            else:
                self._flash_redirect("err", f"unknown device op: {op}")
        except REG.RegistryError as e:
            self._flash_redirect("err", str(e))
        except Exception as e:  # noqa: BLE001
            self._flash_redirect("err", f"device op failed: {e}")

    def log_message(self, fmt, *args):  # quieter; one line to stderr
        import sys
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

# --- bootstrap ---------------------------------------------------------------

def parse_binds(raw):
    return [b for b in re.split(r"[,\s]+", raw.strip()) if b]

def main():
    binds = parse_binds(BIND_RAW)
    servers = []
    for addr in binds:
        try:
            srv = ThreadingHTTPServer((addr, PORT), Handler)
        except OSError as e:
            # An address we don't currently hold (e.g. hotspot not up yet) is
            # not fatal — bind the ones we can and log the rest.
            print(f"[nd-net-ui] skip bind {addr}:{PORT} — {e}", flush=True)
            continue
        servers.append(srv)
        print(f"[nd-net-ui] listening on http://{addr}:{PORT}", flush=True)
    if not servers:
        # Last resort so the service doesn't crash-loop with nothing bound.
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        servers.append(srv)
        print(f"[nd-net-ui] fallback listening on http://127.0.0.1:{PORT}", flush=True)

    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        for s in servers:
            s.shutdown()

if __name__ == "__main__":
    main()
