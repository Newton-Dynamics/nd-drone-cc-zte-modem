#!/usr/bin/env python3
# mock_zte_modem.py — offline stand-in for a ZTE LTE stick's web API.
#
# Emulates just enough of the goform endpoints that zte_login.sh exercises so
# the full unlock flow can be tested on a dev box with no hardware:
#
#   GET  /goform/goform_get_cmd_process?cmd=LD            -> {"LD": "<hex>"}
#   GET  /goform/goform_get_cmd_process?cmd=RD            -> {"RD": "<hex>"}
#   GET  /goform/goform_get_cmd_process?cmd=imei[,...]    -> {"imei": "...", ...}
#   POST /goform/goform_set_cmd_process  goformId=LOGIN   -> {"result":"0|3|1"}
#   POST /goform/goform_set_cmd_process  goformId=ENTER_PIN -> {"result":"success|failure"}
#
# The login + ENTER_PIN crypto matches the real device so the script's hashing
# is genuinely tested (not stubbed):
#   LOGIN:     LD; login = SHA256( upper(SHA256(password)) + upper(LD) )
#   ENTER_PIN: RD; AD = MD5( MD5(wa_inner_version + cr_version) + RD )
#
# Configure the emulated device via env (so tests can vary it):
#   MOCK_IMEI            default 350000000000001
#   MOCK_IMSI            default 262011234567890
#   MOCK_PASSWORD        default StickPwOne   (the correct login password)
#   MOCK_PIN             default 1234         (the correct SIM PIN)
#   MOCK_WA_INNER_VERSION default BD_MOCKV1.0.0B01
#   MOCK_CR_VERSION       default CR_MOCK1.0
#   MOCK_IMEI_PREAUTH    "1" (default) exposes IMEI before login; "0" hides it
#                        (returns empty) to exercise the last-good fallback path
#   MOCK_PORT            default 0 (ephemeral; printed as "PORT <n>" on stdout)
#   MOCK_BIND            default 127.0.0.1
#
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


def _env(name, default):
    v = os.environ.get(name)
    return v if v not in (None, "") else default


CFG = {
    "imei": _env("MOCK_IMEI", "350000000000001"),
    "imsi": _env("MOCK_IMSI", "262011234567890"),
    "password": _env("MOCK_PASSWORD", "StickPwOne"),
    "pin": _env("MOCK_PIN", "1234"),
    "wa_inner_version": _env("MOCK_WA_INNER_VERSION", "BD_MOCKV1.0.0B01"),
    "cr_version": _env("MOCK_CR_VERSION", "CR_MOCK1.0"),
    "imei_preauth": _env("MOCK_IMEI_PREAUTH", "1") == "1",
}

# Fixed challenge values. Real devices rotate these; fixed is fine for the test
# because the script reads them fresh each run and recomputes the hashes.
LD_VALUE = "ABCDEF0123456789ABCDEF0123456789"
RD_VALUE = "0011223344556677889900aabbccddee"

# Per-process state: authenticated session + SIM locked/unlocked.
STATE = {"logged_in": False, "sim_unlocked": False}


def expected_login_hash():
    pre = hashlib.sha256(CFG["password"].encode()).hexdigest().upper()
    return hashlib.sha256((pre + LD_VALUE.upper()).encode()).hexdigest().upper()


def expected_ad():
    pre = hashlib.md5((CFG["wa_inner_version"] + CFG["cr_version"]).encode()).hexdigest()
    return hashlib.md5((pre + RD_VALUE).encode()).hexdigest()


# All cmd-readable fields the script may ask for. IMEI visibility pre-auth is
# governed by imei_preauth; everything else is returned regardless (the real
# device is laxer on reads than writes, and the script only relies on these
# post-login anyway).
def cmd_value(cmd, logged_in):
    if cmd == "LD":
        return LD_VALUE
    if cmd == "RD":
        return RD_VALUE
    if cmd == "imei":
        if logged_in or CFG["imei_preauth"]:
            return CFG["imei"]
        return ""  # hidden pre-auth → exercises the last-good fallback
    table = {
        "imsi": CFG["imsi"],
        "sim_imsi": CFG["imsi"],
        "wa_inner_version": CFG["wa_inner_version"],
        "cr_version": CFG["cr_version"],
        "modem_main_state": "modem_init_complete" if STATE["sim_unlocked"] else "modem_sim_undetected",
        "pin_status": "0" if STATE["sim_unlocked"] else "1",
        "sim_status": "modem_sim_ready" if STATE["sim_unlocked"] else "modem_waiting_pin",
        "network_type": "LTE" if STATE["sim_unlocked"] else "",
        "network_provider": "MockNet",
        "msisdn": "+490000000000",
    }
    return table.get(cmd, "")


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        # Compact, no spaces — real ZTE devices emit {"key":"val"} which the
        # unlock script's grep patterns (?<="key":") depend on.
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path != "/goform/goform_get_cmd_process":
            self._json({"error": "not found"}, 404)
            return
        q = parse_qs(u.query)
        cmds = q.get("cmd", [""])[0]
        out = {}
        for c in cmds.split(","):
            c = c.strip()
            if c:
                out[c] = cmd_value(c, STATE["logged_in"])
        self._json(out)

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/goform/goform_set_cmd_process":
            self._json({"error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        form = parse_qs(body)
        gid = form.get("goformId", [""])[0]

        if gid == "LOGIN":
            supplied = form.get("password", [""])[0]
            if supplied.upper() == expected_login_hash():
                STATE["logged_in"] = True
                self._json({"result": "0"})
            else:
                self._json({"result": "3"})  # bad password
            return

        if gid == "ENTER_PIN":
            if not STATE["logged_in"]:
                self._json({"result": "failure"})
                return
            pin = form.get("PinNumber", [""])[0]
            ad = form.get("AD", [""])[0]
            if pin == CFG["pin"] and ad == expected_ad():
                STATE["sim_unlocked"] = True
                self._json({"result": "success"})
            else:
                self._json({"result": "failure"})
            return

        self._json({"result": "failure", "note": f"unhandled goformId {gid}"})

    def log_message(self, *a):  # keep test output clean
        pass


def main():
    bind = _env("MOCK_BIND", "127.0.0.1")
    port = int(_env("MOCK_PORT", "0"))
    srv = ThreadingHTTPServer((bind, port), Handler)
    actual = srv.server_address[1]
    print(f"PORT {actual}", flush=True)
    print(f"[mock-zte] imei={CFG['imei']} imsi={CFG['imsi']} "
          f"preauth_imei={CFG['imei_preauth']} on {bind}:{actual}", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
