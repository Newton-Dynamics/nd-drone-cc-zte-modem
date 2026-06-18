# Multi-device modem unlock — design

One Jetson can serve many LTE sticks and many SIM cards. The unlock has **two
independent secrets with different owners**:

| Owner | Identity | Secret |
|-------|----------|--------|
| **Stick** (hardware) | IMEI | modem **login password** |
| **SIM card** | IMSI | SIM **PIN** |

A SIM moved into another stick keeps its PIN; a stick taking a different SIM
uses that SIM's PIN. This is why the registry has **two tables**, not one
per-IMEI row holding both secrets. (The single-table model was explicitly
rejected — it can't represent a SIM moving between sticks.)

## Registry

- `nd-modem-registry.py` — library + CLI. Tables `sticks` (IMEI→password) and
  `sims` (IMSI→PIN), plus a `last_login` cache (see below).
- Stored at `/opt/nd-net/devices.json`, **0600, root**. Atomic writes
  (temp file + rename), input validation (IMEI 14–16 digits, IMSI 6–15,
  PIN 4–8 digits).
- Symlinked to `/usr/local/bin/nd-modem-registry`.

CLI:
```
nd-modem-registry add-stick --imei <IMEI> --password <pw> [--label <name>]
nd-modem-registry add-sim   --imsi <IMSI> --pin <pin>     [--label <name>]
nd-modem-registry list [--json] [--secrets]
nd-modem-registry rm-stick --imei <IMEI>
nd-modem-registry rm-sim   --imsi <IMSI>
# consumed by zte_login.sh:
nd-modem-registry lookup-stick --imei <IMEI>     # prints password, rc 3 if miss
nd-modem-registry lookup-sim   --imsi <IMSI>     # prints PIN, rc 3 if miss
nd-modem-registry last-imei    --host <host>     # cached IMEI for fallback
nd-modem-registry record-login --host <h> --imei <i> --ts <iso>
```

## Login bootstrap (chicken-and-egg)

We need the password to log in, but want the IMEI to choose the password.
`zte_login.sh` resolves it in order:

1. **Read IMEI pre-auth** — if the modem exposes IMEI without authentication,
   look up that stick's password directly.
2. **Last-good fallback** — if the modem hides IMEI pre-auth, use the password
   of the stick that last logged in successfully on this host (the `last_login`
   cache, keyed by `ZTE_HOST`).
3. **.env fallback** — `ZTE_PASSWORD` / `ZTE_PIN` in `/opt/zte/.env` remain an
   optional single-device / bring-up fallback. Registry matches take priority.

Candidate passwords are de-duplicated and tried in order; attempts are capped
to avoid the modem's bad-password lockout. After a successful login the script
records the IMEI (so the next boot's fallback works) and resolves the PIN by the
**inserted SIM's IMSI**.

The ZTE protocol itself is unchanged: login = `SHA256(upper(SHA256(password)) +
upper(LD))`; ENTER_PIN AD = `MD5(MD5(wa_inner_version + cr_version) + RD)`.

## Trust model

Secrets are stored **plaintext, 0600, root** — by design. The device itself is
the trust boundary, the same decision as the LAN-bound, no-auth control UI.
Encryption-at-rest was considered and rejected: on a headless device the decrypt
key ends up beside the data, for marginal real-world gain.

## Status

Logic and ZTE protocol handling are covered by the offline test suite
([offline-testing.md](offline-testing.md)). **Real-hardware validation is still
pending** — the pre-auth-IMEI assumption and the exact modem JSON field names
should be confirmed against an actual stick.
