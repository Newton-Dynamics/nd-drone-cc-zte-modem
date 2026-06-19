# Install procedure — nd-drone-cc-zte-modem

Complete, self-contained install runbook for the Jetson's resilient networking
+ ZTE LTE modem unlock. **No AI/Claude step is required.** Everything below is
plain `ssh` + `sudo` on the device.

There are **two halves**, installed by two scripts:

| Half | Script | Installs to | What it does |
|------|--------|-------------|--------------|
| **Modem unlock** | `zte_install_script.sh` | `/opt/zte`, NM dispatcher | Logs into the ZTE stick + enters the SIM PIN when the LTE iface comes up. |
| **Failover networking** | `nd_net_install.sh` | `/opt/nd-net`, systemd | WiFi client/hotspot, Ethernet DHCP server/client, LTE-only egress firewall, control UI, device registry. |

**Order matters: install the ZTE half first, then nd-net.** The nd-net installer
only sets the LTE-preferred route metrics in the dispatcher if the dispatcher is
already present. (If you do it the other way round, just re-run the nd-net
installer afterward — see [Step 5](#step-5-if-you-installed-out-of-order).)

---

## 0. Prerequisites

- Ubuntu-based Jetson (or any Debian/Ubuntu box) with **NetworkManager** active.
- Root via `sudo`.
- The repo checked out on the device (e.g. `~/nd-drone-cc-zte-modem`).
- Internet access for the **first** install only (apt fetches missing tools).

```bash
cd ~/nd-drone-cc-zte-modem        # wherever the repo lives
systemctl is-active NetworkManager # must print: active
```

### Required tools (both installers can apt-install these for you)

`curl jq awk sed grep coreutils(sha256sum/md5sum) logger nmcli dnsmasq iw
wpa_supplicant flock python3`

> **Gotcha — `jq` is mandatory.** `zte_login.sh` parses all modem JSON with
> `jq`; without it the unlock silently fails (login succeeds but IMEI/IMSI come
> back empty). Both installers now list it as a dependency and will install it.
> To check by hand: `command -v jq || sudo apt-get install -y jq`.

---

## 1. Pre-flight (both halves, no changes made)

Dry-runs make **no** modifications. Run both and read the output:

```bash
sudo ./zte_install_script.sh --dry-run
sudo ./nd_net_install.sh   --dry-run
```

What to look for:

- **ZTE dry-run:** "ZTE USB device detected via lsusb (vendor 19d2)" if the
  stick is plugged in. If not, you can still install — the dispatcher just
  triggers later when the modem appears.
- **nd-net dry-run:** confirms WiFi device, onboard ethernet, NM active, all
  source files present, and "All required tools present."
  - **No WiFi adapter?** That's fine — the installer will warn and **skip the
    hotspot**, still configuring ethernet + LTE. (The dry-run prints a cosmetic
    `[ERR] No WiFi device found`; the actual install treats it as a warning.)

Optional but recommended — run the offline test suite (needs `jq`):

```bash
sudo apt-get install -y jq        # if missing
./nd_net_install.sh --test        # expect: 12 unit + 7 e2e = all pass
```

---

## 2. Install the ZTE modem half

```bash
sudo ./zte_install_script.sh --install
```

This copies the dispatcher + `zte_http.sh` + `zte_login.sh` into place and, if
no `/opt/zte/.env` exists, **interactively prompts** you to create one:

| Prompt | Enter | Notes |
|--------|-------|-------|
| ZTE modem host/IP | `192.168.0.1` | The stick's admin IP (default usually fine). |
| ZTE modem username | `admin` | |
| ZTE modem password | *(the stick's login password)* | Hidden in the summary. |
| SIM PIN | *(PIN, or empty if disabled)* | |
| IMEI | *(optional)* | Used for the AD hash calc; usually leave blank. |
| APN profile index | `1` | |

The `.env` is written `0600 root` to `/opt/zte/.env` and is **gitignored** —
never commit it.

> **Single-device vs multi-device:** the values above are the *single-device
> fallback*. If you run multiple sticks/SIMs, prefer the **device registry**
> (Step 4) — it keeps the login password keyed by stick IMEI and the PIN keyed
> by SIM IMSI, so SIMs can move between sticks. The `.env` then only needs to
> exist (it's the fallback); registry entries take precedence.

---

## 3. Install the failover-networking half

```bash
sudo ./nd_net_install.sh --install
```

This will:

1. Create NM profiles: `nd-hotspot` (AP, **only if WiFi present**) and
   `nd-eth-dhcp-server` (ethernet shared/NAT, gateway `10.42.1.1`).
2. Tune `Wired connection 1` into a manager-driven upstream-probe profile.
3. Set the LTE-preferred metrics in the now-present ZTE dispatcher
   (LTE metric 50 < WiFi metric 600).
4. Install scripts to `/opt/nd-net`, the `nd-net-status` + `nd-modem-registry`
   commands, the control UI, and the `devices.json` registry (empty, `0600`).
5. Enable + start `nd-net-manager.service` and `nd-net-ui.service`.
6. Apply the strict LTE-only egress firewall (`ND_FWD` chain).

**If WiFi is present**, it prompts for hotspot SSID + passphrase (≥ 8 chars).
**If not**, it skips that prompt and the hotspot entirely.

> **Gotcha — port 8088 may be taken.** The control UI defaults to port 8088,
> which **BlueOS / `ttyd` web terminals commonly squat**. If the UI service
> crash-loops with `Address already in use`, change the port:
> ```bash
> sudo sed -i 's/^ND_UI_PORT=.*/ND_UI_PORT=8089/' /opt/nd-net/nd-net-ui.env
> sudo systemctl restart nd-net-ui.service
> ```
> Check first with: `sudo ss -tlnp | grep ':8088'`.

---

## 4. Register sticks + SIMs (multi-device unlock)

Secrets live **only** in `/opt/nd-net/devices.json` (`0600 root`). The registry
CLI must be run as **root** (the DB is unreadable otherwise — that's by design).

```bash
# A stick = its IMEI → login password
sudo nd-modem-registry add-stick --imei <IMEI> --password <pw> --label "stick-A"

# A SIM = its IMSI → PIN
sudo nd-modem-registry add-sim   --imsi <IMSI> --pin <pin>     --label "sim-1"

# Review (PINs/passwords masked unless --secrets)
sudo nd-modem-registry list
sudo nd-modem-registry list --secrets        # reveal
sudo nd-modem-registry list --json           # machine-readable

# Remove
sudo nd-modem-registry rm-stick --imei <IMEI>
sudo nd-modem-registry rm-sim   --imsi <IMSI>
```

On modem-up the dispatcher picks the password by the stick's IMEI and the PIN by
the inserted SIM's IMSI. You can also manage all of this in the control UI
"devices" panel.

> Don't know the IMEI/IMSI yet? Plug the stick in, let it come up once, then run
> `sudo nd-net-status` and `journalctl -t nd-nm-zte-modem -n 50` — the unlock
> logs the IMEI/IMSI it read.

---

## 5. If you installed out of order

The nd-net installer only writes LTE-preferred metrics when the dispatcher is
already present. If you installed nd-net **before** the ZTE half, just re-run it:

```bash
sudo ./nd_net_install.sh --install     # safe to re-run; recreates profiles cleanly
```

Re-running is idempotent: it deletes + recreates its NM profiles, leaves an
existing `devices.json` / `nd-net-ui.env` in place, and re-applies the firewall.

---

## 6. Verify

```bash
# Services up?
systemctl is-active nd-net-manager.service nd-net-ui.service   # both: active

# Full operational snapshot (run as root to see the firewall chain)
sudo nd-net-status

# Modem-specific status + routing verdict
sudo ./zte_install_script.sh --status

# Control UI reachable (port per Step 3)
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8089/   # expect 200
```

Expected once an LTE stick + SIM are present and unlocked:

- `nd-net-status` → "USB modem" detected, an LTE interface present, default
  route via LTE (metric 50), HTTPS connectivity OK.
- LAN clients (hotspot `10.42.0.1` / eth-served `10.42.1.1`) reach the internet
  **only** via LTE (the `ND_FWD` chain drops anything else).

Manually trigger an unlock without waiting for an interface event:

```bash
sudo ./zte_install_script.sh --activate
journalctl -t nd-nm-zte-modem -n 50    # unlock log (dispatcher path also tags 'nd_zte')
```

---

## 7. Control UI

- **No authentication** — protected solely by binding to LAN/hotspot gateway
  IPs. Reachable at `http://10.42.0.1:<port>` (WiFi clients),
  `http://10.42.1.1:<port>` (ethernet-served), or `http://127.0.0.1:<port>`
  via SSH port-forward. **Never add `0.0.0.0`** to the bind list.
- Config: `/opt/nd-net/nd-net-ui.env` (`ND_UI_BIND`, `ND_UI_PORT`).
- The `10.42.x.1` binds are skipped until those subnets are actually up — that's
  normal; the UI still serves on `127.0.0.1`.

---

## 8. Where everything lives

| Path | What |
|------|------|
| `/opt/zte/zte_login.sh`, `zte_http.sh` | Modem unlocker. |
| `/opt/zte/.env` | Single-device fallback secrets (`0600`, gitignored). |
| `/etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh` | Dispatcher (route metrics + unlock trigger). |
| `/opt/nd-net/nd-net-manager.sh` | Failover daemon. |
| `/opt/nd-net/devices.json` | Multi-device registry secrets (`0600`, gitignored). |
| `/opt/nd-net/nd-net-ui.env` | UI bind/port config. |
| `/etc/systemd/system/nd-net-manager.service`, `nd-net-ui.service` | systemd units. |
| `/usr/local/bin/nd-net-status`, `nd-modem-registry` | CLI symlinks. |

Logs:

```bash
journalctl -t nd-net -f            # failover decisions
journalctl -t nd-nm-zte-modem -f   # modem unlock (zte_login.sh)
journalctl -t nd_zte -f            # modem unlock via dispatcher/--activate path
journalctl -t nd-nm-dispatcher -f  # dispatcher (route metrics + trigger)
journalctl -u nd-net-ui -f         # control UI
```

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Unlock logs `IMEI= IMSI=` empty after "Login successful" | `jq` not installed | `sudo apt-get install -y jq` |
| `nd-net-ui.service` crash-loops, `Address already in use` | Port 8088 taken (ttyd/BlueOS) | Change `ND_UI_PORT` (Step 3 gotcha) |
| `nd-modem-registry: Permission denied: devices.json` | Ran as non-root | Use `sudo` (DB is `0600 root` by design) |
| nd-net `--install` aborts "No onboard ethernet device" | No `en*/eth*` NIC found | Real blocker — onboard ethernet is required |
| LTE not preferred / dispatcher warning at install | ZTE half not installed yet | Install ZTE first, then re-run nd-net (Step 5) |
| LAN clients have no internet | LTE stick absent/down | By design — STRICT LTE-only egress. Restore LTE. |
| Foreign DHCP/AP fighting our ifaces | Cable Guy/Docker managing our NICs | Leave our ifaces unmanaged in BlueOS; manager reaps foreign daemons. |

---

## 10. Uninstall / disable

```bash
sudo /opt/nd-net/nd-net-manager.sh fw-clear        # flush ND_FWD while script still present
sudo systemctl disable --now nd-net-manager.service nd-net-ui.service
sudo nmcli con delete nd-hotspot nd-eth-dhcp-server 2>/dev/null
sudo rm -f /etc/systemd/system/nd-net-manager.service /etc/systemd/system/nd-net-ui.service
sudo rm -f /etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh
sudo rm -rf /opt/nd-net /opt/zte
sudo rm -f /usr/local/bin/nd-net-status /usr/local/bin/nd-modem-registry
sudo systemctl daemon-reload
sudo systemctl reload NetworkManager
```

> The `ND_FWD` chain is re-applied on every manager start, so flush it (first
> line above) **before** removing the scripts. Once the service is disabled it
> won't be reinstalled on the next boot.
