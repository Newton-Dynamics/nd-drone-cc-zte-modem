# nd-drone-cc-zte-modem

Resilient networking for a Jetson on a drone, with an LTE uplink via a ZTE
modem stick. Plain shell + Python-stdlib scripts driven by systemd and
NetworkManager — **no pip / external runtime dependencies** (it's a minimal
embedded device; keep it that way).

## Components

| File | Role |
|------|------|
| `zte_login.sh` | ZTE modem unlocker: login + SIM PIN unlock. Multi-device (see below). Runs from the NM dispatcher via `zte_http.sh`. |
| `zte_http.sh` | Loads `/opt/zte/.env`, then runs `zte_login.sh`. |
| `00-nd-nm-dispatcher-zte-modem.sh` | NM dispatcher: on LTE iface up, set LTE-preferred route metrics + trigger the unlock. → `/etc/NetworkManager/dispatcher.d/`. |
| `nd-net-manager.sh` | Failover daemon: WiFi client/hotspot, ethernet DHCP server/client, LTE-only egress firewall. `nd-net-manager.service`. |
| `nd-net-status.sh` | One-screen operational status. → `nd-net-status`. |
| `nd-net-lib.sh` | Shared helpers (foreign-daemon reaper, LTE iface detection). |
| `nd-modem-registry.py` | Device registry: sticks (IMEI→password) + SIMs (IMSI→PIN). CLI + library. → `nd-modem-registry`. |
| `nd-net-ui.py` | LAN-bound control UI: status + .env editor + device management + service control. `nd-net-ui.service`. |
| `nd_net_install.sh` | Umbrella installer: `--dry-run` / `--install` / `--status` / `--test`. |
| `tests/` | Mock ZTE modem + registry unit tests + e2e unlock tests (offline). |

Everything installs under `/opt/nd-net` (and `/opt/zte` for the modem half).

## Key design decisions (read these before changing things)

- **[Multi-device unlock](docs/modem-device-registry.md)** — login password
  belongs to the **stick** (IMEI); SIM PIN belongs to the **card** (IMSI). Two
  tables, not one. Login bootstrap handles the IMEI/password chicken-and-egg.
- **[Control UI](docs/control-ui.md)** — stdlib-only, **no auth, LAN-bound**,
  runs as root. Trust boundary = the device + the hotspot.
- **[Docker DNS fix](docs/docker-dns-fix.md)** — plug-in USB NICs (`enx*`) can
  hand the host a hijacking resolver that poisons registry lookups
  (`auth.docker.io → 192.168.50.x → i/o timeout`). The installer disables DNS +
  default-route from `enx*` NICs and pins the docker daemon to public DNS.
- **[Offline testing](docs/offline-testing.md)** — `./nd_net_install.sh --test`
  runs the whole unlock flow against a mock modem with no hardware. **Note the
  compact-JSON gotcha documented there.**
- Secrets (passwords, PINs) are stored **plaintext 0600 root** by design;
  `devices.json` / `.env` / `nd-net-ui.env` are gitignored — never commit them.

## Conventions

- Bash: `set -Eeuo pipefail`, log via `logger -t <tag>` (tags: `nd-net`,
  `nd-nm-zte-modem`, `nd-zte`, `nd-nm-dispatcher`).
- Python: stdlib only, atomic writes for any secret file (temp + rename, chmod
  0600), keep it runnable as a plain `python3 file.py`.
- Don't add Cable Guy / Docker management of our interfaces — `nd-net-manager`
  reaps foreign DHCP/AP daemons on its ifaces and they'll fight.

## Status / next

Control UI + multi-device registry are built and pass the offline suite.
**Pending: real-hardware validation** of the unlock against an actual ZTE stick
(confirm pre-auth IMEI behavior and exact modem JSON field names). Current work
is on branch `feature/control-ui-and-multi-device`.
