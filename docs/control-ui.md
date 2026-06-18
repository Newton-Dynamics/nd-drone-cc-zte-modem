# Control UI — design

`nd-net-ui.py` is a single-file, stdlib-only operational dashboard for the
Jetson networking stack. Installed to `/opt/nd-net/nd-net-ui.py`, run by
`nd-net-ui.service`.

## What it does

- **Status**: runs `nd-net-status` (ANSI-stripped), shows `systemctl status` of
  `nd-net-manager`, the last-known modem/SIM state (parsed from the
  `nd-nm-zte-modem` journal tag), and journal tails.
- **.env editor**: view + edit `/opt/zte/.env` and `/opt/nd-net/.env`. Secret
  keys (matched by `PASSWORD|PIN|PSK|SECRET|TOKEN|KEY` suffix) are masked with a
  reveal toggle; a blank secret field keeps the stored value. Writes preserve
  comments / `export` prefixes / line order, atomic, 0600.
- **Devices panel**: list/add/remove LTE sticks and SIM cards (the
  [registry](modem-device-registry.md)). Secrets masked, server-side
  validation, HTML-escaped output.
- **Service control**: start / stop / restart `nd-net-manager`.
- `/api/status` (JSON) and `/healthz`.

## Design constraints

- **Python 3 stdlib only** — no pip deps (matches the repo's plain-scripts
  ethos; the box is a minimal embedded device).
- **No authentication by design** — protected solely by binding to the
  LAN/hotspot gateway IPs (`10.42.0.1`, `10.42.1.1`), never `0.0.0.0`. Bind
  list / port configurable in `/opt/nd-net/nd-net-ui.env`.
- Runs as **root** (reads/writes 0600 secret files, controls systemd).

## Security posture

Anyone on the hotspot can edit the SIM PIN / modem password and stop
networking — that is the accepted trade-off of the no-auth + LAN-bound choice.
The write paths were reviewed for path traversal (allowlisted file slugs only),
.env key injection (`^[A-Za-z_][A-Za-z0-9_]*$`), shell-injection in values
(quote-escaped on write, never executed), and XSS (all output HTML-escaped).
If the hotspot passphrase is ever widely shared, switch to HTTP basic auth
(the handler structure supports adding it).
