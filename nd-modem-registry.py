#!/usr/bin/env python3
# nd-modem-registry — device registry for the ZTE LTE unlock flow.
#
# Installed to: /opt/nd-net/nd-modem-registry.py
#               symlinked as /usr/local/bin/nd-modem-registry
#
# The unlock problem has TWO independent secrets:
#   - the modem login PASSWORD belongs to the STICK (hardware), keyed by IMEI;
#   - the SIM PIN belongs to the CARD, keyed by IMSI.
# A SIM can move between sticks and a stick can take different SIMs, so we keep
# two tables and match each secret on its own identity.
#
# Storage: a single JSON file (default /opt/nd-net/devices.json), 0600, root.
# Schema (version 1):
#   {
#     "version": 1,
#     "sticks": [ {"imei": "35...", "password": "....", "label": "...",
#                  "last_seen": "<iso8601 or null>"} ],
#     "sims":   [ {"imsi": "26...", "pin": "1234", "label": "...",
#                  "last_seen": "<iso8601 or null>"} ],
#     "last_login": { "<host>": {"imei": "35...", "ts": "<iso>"} }
#   }
# `last_login` caches the IMEI that last logged in successfully per host, so the
# unlock script can fall back to that stick's password when the modem won't
# reveal the IMEI before authentication.
#
# This module is imported by nd-net-ui.py and also runs as a CLI consumed by
# zte_login.sh:
#
#   nd-modem-registry lookup-stick --imei 35...      -> prints password (rc 0) or rc 3
#   nd-modem-registry lookup-sim   --imsi 26...       -> prints PIN (rc 0) or rc 3
#   nd-modem-registry last-imei    --host 192.168.0.1 -> prints cached IMEI or rc 3
#   nd-modem-registry record-login --host H --imei I  -> updates last_login + last_seen
#   nd-modem-registry seen-sim     --imsi 26...        -> bumps SIM last_seen
#   nd-modem-registry list [--json]                    -> human/JSON dump (secrets masked unless --secrets)
#   nd-modem-registry add-stick --imei .. --password .. [--label ..]
#   nd-modem-registry add-sim   --imsi .. --pin .. [--label ..]
#   nd-modem-registry rm-stick  --imei ..
#   nd-modem-registry rm-sim    --imsi ..
#
import json
import os
import re
import sys
import tempfile

REGISTRY_PATH = os.environ.get("ND_MODEM_REGISTRY", "/opt/nd-net/devices.json")

IMEI_RE = re.compile(r"^\d{14,16}$")     # 15 digits typical; allow 14-16
IMSI_RE = re.compile(r"^\d{6,15}$")
PIN_RE  = re.compile(r"^\d{4,8}$")        # SIM PIN is numeric, 4-8 digits


class RegistryError(Exception):
    pass


# --- load / save -------------------------------------------------------------

def _empty():
    return {"version": 1, "sticks": [], "sims": [], "last_login": {}}

def load(path=None):
    path = path or REGISTRY_PATH
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return _empty()
    except (json.JSONDecodeError, OSError) as e:
        raise RegistryError(f"cannot read registry {path}: {e}")
    # Normalize shape so callers can rely on the keys existing.
    data.setdefault("version", 1)
    data.setdefault("sticks", [])
    data.setdefault("sims", [])
    data.setdefault("last_login", {})
    return data

def save(data, path=None):
    path = path or REGISTRY_PATH
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".devices.", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=False)
            fh.write("\n")
        os.chmod(tmp, 0o600)
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


# --- validation --------------------------------------------------------------

def _norm(s):
    return (s or "").strip()

def validate_stick(imei, password):
    imei = _norm(imei)
    if not IMEI_RE.match(imei):
        raise RegistryError(f"invalid IMEI {imei!r} (expect 14-16 digits)")
    if not password:
        raise RegistryError("stick password must not be empty")
    return imei

def validate_sim(imsi, pin):
    imsi = _norm(imsi)
    if not IMSI_RE.match(imsi):
        raise RegistryError(f"invalid IMSI {imsi!r} (expect 6-15 digits)")
    pin = _norm(pin)
    if not PIN_RE.match(pin):
        raise RegistryError(f"invalid PIN (expect 4-8 digits)")
    return imsi, pin


# --- mutations (load → modify → save) ----------------------------------------

def _find(rows, key, val):
    for r in rows:
        if r.get(key) == val:
            return r
    return None

def add_stick(imei, password, label="", path=None):
    imei = validate_stick(imei, password)
    data = load(path)
    row = _find(data["sticks"], "imei", imei)
    if row:
        row["password"] = password
        if label:
            row["label"] = label
    else:
        data["sticks"].append({"imei": imei, "password": password,
                               "label": _norm(label), "last_seen": None})
    save(data, path)
    return imei

def add_sim(imsi, pin, label="", path=None):
    imsi, pin = validate_sim(imsi, pin)
    data = load(path)
    row = _find(data["sims"], "imsi", imsi)
    if row:
        row["pin"] = pin
        if label:
            row["label"] = label
    else:
        data["sims"].append({"imsi": imsi, "pin": pin,
                             "label": _norm(label), "last_seen": None})
    save(data, path)
    return imsi

def rm_stick(imei, path=None):
    data = load(path)
    n = len(data["sticks"])
    data["sticks"] = [s for s in data["sticks"] if s.get("imei") != _norm(imei)]
    save(data, path)
    return n - len(data["sticks"])

def rm_sim(imsi, path=None):
    data = load(path)
    n = len(data["sims"])
    data["sims"] = [s for s in data["sims"] if s.get("imsi") != _norm(imsi)]
    save(data, path)
    return n - len(data["sims"])

def record_login(host, imei, ts, path=None):
    """Cache the IMEI that just logged in on `host`, and bump that stick's
    last_seen. `ts` is supplied by the caller (the script knows the clock)."""
    data = load(path)
    data["last_login"][_norm(host)] = {"imei": _norm(imei), "ts": ts}
    row = _find(data["sticks"], "imei", _norm(imei))
    if row:
        row["last_seen"] = ts
    save(data, path)

def seen_sim(imsi, ts, path=None):
    data = load(path)
    row = _find(data["sims"], "imsi", _norm(imsi))
    if row:
        row["last_seen"] = ts
        save(data, path)


# --- lookups (read-only) -----------------------------------------------------

def lookup_stick_password(imei, path=None):
    row = _find(load(path)["sticks"], "imei", _norm(imei))
    return row["password"] if row else None

def lookup_sim_pin(imsi, path=None):
    row = _find(load(path)["sims"], "imsi", _norm(imsi))
    return row["pin"] if row else None

def last_imei_for_host(host, path=None):
    rec = load(path)["last_login"].get(_norm(host))
    return rec.get("imei") if rec else None


# --- presentation (for the UI / list command) -------------------------------

def _mask(_s):
    return "••••••"

def public_view(path=None, reveal=False):
    """Registry as plain dicts for display. Secrets masked unless reveal=True."""
    data = load(path)
    sticks = [{
        "imei": s.get("imei", ""),
        "label": s.get("label", ""),
        "password": s.get("password", "") if reveal else _mask(s.get("password")),
        "last_seen": s.get("last_seen"),
    } for s in data["sticks"]]
    sims = [{
        "imsi": s.get("imsi", ""),
        "label": s.get("label", ""),
        "pin": s.get("pin", "") if reveal else _mask(s.get("pin")),
        "last_seen": s.get("last_seen"),
    } for s in data["sims"]]
    return {"sticks": sticks, "sims": sims, "last_login": data["last_login"]}


# --- CLI ---------------------------------------------------------------------

def _arg(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default

def main(argv):
    if not argv:
        sys.stderr.write(__doc__ or "")
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "lookup-stick":
            pw = lookup_stick_password(_arg(rest, "--imei", ""))
            if pw is None:
                return 3
            sys.stdout.write(pw)
            return 0
        if cmd == "lookup-sim":
            pin = lookup_sim_pin(_arg(rest, "--imsi", ""))
            if pin is None:
                return 3
            sys.stdout.write(pin)
            return 0
        if cmd == "last-imei":
            imei = last_imei_for_host(_arg(rest, "--host", ""))
            if not imei:
                return 3
            sys.stdout.write(imei)
            return 0
        if cmd == "record-login":
            record_login(_arg(rest, "--host", ""), _arg(rest, "--imei", ""),
                         _arg(rest, "--ts", ""))
            return 0
        if cmd == "seen-sim":
            seen_sim(_arg(rest, "--imsi", ""), _arg(rest, "--ts", ""))
            return 0
        if cmd == "add-stick":
            add_stick(_arg(rest, "--imei", ""), _arg(rest, "--password", ""),
                      _arg(rest, "--label", ""))
            return 0
        if cmd == "add-sim":
            add_sim(_arg(rest, "--imsi", ""), _arg(rest, "--pin", ""),
                    _arg(rest, "--label", ""))
            return 0
        if cmd == "rm-stick":
            return 0 if rm_stick(_arg(rest, "--imei", "")) else 3
        if cmd == "rm-sim":
            return 0 if rm_sim(_arg(rest, "--imsi", "")) else 3
        if cmd == "list":
            reveal = "--secrets" in rest
            view = public_view(reveal=reveal)
            if "--json" in rest:
                sys.stdout.write(json.dumps(view, indent=2) + "\n")
            else:
                sys.stdout.write("Sticks (IMEI → login password):\n")
                for s in view["sticks"]:
                    sys.stdout.write(f"  {s['imei']}  pw={s['password']}  "
                                     f"label={s['label']!r}  last_seen={s['last_seen']}\n")
                sys.stdout.write("SIMs (IMSI → PIN):\n")
                for s in view["sims"]:
                    sys.stdout.write(f"  {s['imsi']}  pin={s['pin']}  "
                                     f"label={s['label']!r}  last_seen={s['last_seen']}\n")
            return 0
        sys.stderr.write(f"unknown command: {cmd}\n")
        return 2
    except RegistryError as e:
        sys.stderr.write(f"error: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
