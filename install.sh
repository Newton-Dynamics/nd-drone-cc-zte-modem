#!/usr/bin/env bash
#
# install.sh — single installer for the Jetson's ZTE-modem + resilient
# networking stack (nd-drone-cc-zte-modem).
#
# Deploys:
#   - ZTE modem identify-then-unlock workflow (modem/nd-zte-modem.sh), driven
#     by modem/SIM lookup tables (IMEI -> password, IMSI -> PIN) instead of a
#     single fixed .env — a drone may see several modems/SIMs over its life
#   - NetworkManager dispatcher hook that prefers LTE and triggers the modem
#     workflow on interface-up (dispatcher/00-nd-nm-dispatcher-zte-modem.sh)
#   - WiFi hotspot/client + Ethernet DHCP-server/client failover daemon
#     (net/nd-uplink-manager.sh + systemd unit)
#   - LTE-only egress firewall (ND_FWD chain, via lib/nd-common.sh)
#   - Status tool (bin/nd-uplink-status.sh, symlinked as `nd-uplink-status`)
#   - Minimal config web UI (webui/nd-modem-webui.py + systemd unit) — manage
#     the modem/SIM tables and glance at uplink status from a browser; runs
#     independent of NetworkManager/nd-uplink-manager so it stays reachable
#     even if the rest of the stack is broken
#
# Usage:
#   sudo ./install.sh --dry-run     # preflight checks only, no changes
#   sudo ./install.sh --install     # deploy + verify + print instructions
#        ./install.sh --status      # run the status tool
#   sudo ./install.sh --uninstall   # remove the stack (leaves .env + NM profiles)
#
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

### --- source layout ---------------------------------------------------------
LIB_SRC="$SELF_DIR/lib/nd-common.sh"
MODEM_SRC="$SELF_DIR/modem/nd-zte-modem.sh"
DISPATCHER_SRC="$SELF_DIR/dispatcher/00-nd-nm-dispatcher-zte-modem.sh"
MANAGER_SRC="$SELF_DIR/net/nd-uplink-manager.sh"
SERVICE_SRC="$SELF_DIR/net/nd-uplink-manager.service"
STATUS_SRC="$SELF_DIR/bin/nd-uplink-status.sh"
WEBUI_SRC="$SELF_DIR/webui/nd-modem-webui.py"
WEBUI_SERVICE_SRC="$SELF_DIR/webui/nd-modem-webui.service"

### --- install layout ---------------------------------------------------------
ND_DIR="/opt/nd-uplink"
LIB_DST="$ND_DIR/lib/nd-common.sh"
MODEM_DST="$ND_DIR/modem/nd-zte-modem.sh"
MODEMS_DB="$ND_DIR/modem/modems.json"
SIMS_DB="$ND_DIR/modem/sims.json"
ACTIVE_DB="$ND_DIR/modem/active.json"
MANAGER_DST="$ND_DIR/net/nd-uplink-manager.sh"
STATUS_DST="$ND_DIR/bin/nd-uplink-status.sh"
WEBUI_DST="$ND_DIR/webui/nd-modem-webui.py"
DISPATCHER_DST="/etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh"
SERVICE_DST="/etc/systemd/system/nd-uplink-manager.service"
WEBUI_SERVICE_DST="/etc/systemd/system/nd-modem-webui.service"
STATUS_LINK="/usr/local/bin/nd-uplink-status"
ACTIVATE_LINK="/usr/local/bin/nd-zte-activate"
# Single source of truth for the UI port: the Python default in
# nd-modem-webui.py (ND_WEBUI_PORT env fallback). Derive it here so the verify
# curl and the printed URLs always match what the service actually binds,
# instead of drifting from a hard-coded constant.
WEBUI_PORT="$(sed -n 's/.*ND_WEBUI_PORT",[[:space:]]*"\([0-9]\{1,\}\)".*/\1/p' "$WEBUI_SRC" 2>/dev/null | head -1)"
WEBUI_PORT="${WEBUI_PORT:-7077}"
AVAHI_CONF="/etc/avahi/avahi-daemon.conf"

HOTSPOT_CON="nd-hotspot"
ETH_CLIENT_CON="Wired connection 1"
ETH_SERVER_CON="nd-eth-dhcp-server"
ETH_SERVER_ADDR="10.42.1.1/24"      # fixed gateway/subnet for the eth DHCP server

# Route metrics (lower = preferred): LTE preferred over WiFi. Informational
# here — actually applied by the dispatcher on interface-up.
LTE_METRIC=50
WIFI_METRIC=600

DEPS=(nmcli dnsmasq iw wpa_supplicant flock logger curl jq awk sed sha256sum md5sum python3)

### --- shared helpers ----------------------------------------------------------
if [[ -r "$LIB_SRC" ]]; then
  # shellcheck source=/dev/null
  . "$LIB_SRC"
else
  echo "[ERR] Missing $LIB_SRC — cannot continue." >&2
  exit 1
fi

### --- dry run -----------------------------------------------------------------
preflight() {
  msg "Running dry-run checks…"
  # Report-only, always — --dry-run must never change system state, even
  # when run as root. Missing tools are only installed by --install.
  nd_check_deps dry-run "${DEPS[@]}"

  for f in "$LIB_SRC" "$MODEM_SRC" "$DISPATCHER_SRC" "$MANAGER_SRC" "$SERVICE_SRC" "$STATUS_SRC" "$WEBUI_SRC" "$WEBUI_SERVICE_SRC"; do
    [[ -f "$f" ]] && ok "Found $(basename "$f")" || err "Missing $f"
  done

  if [[ $EUID -ne 0 ]]; then
    warn "Not running as root — --install will require sudo"
  else
    ok "Running as root"
  fi

  systemctl is-active --quiet NetworkManager && ok "NetworkManager active" \
    || err "NetworkManager not active — required"
  [[ -d /etc/NetworkManager/dispatcher.d ]] && ok "Dispatcher directory exists" \
    || err "Missing /etc/NetworkManager/dispatcher.d"

  local wifi eth
  wifi="$(nd_wifi_dev || true)"; eth="$(nd_eth_dev || true)"
  [[ -n "$wifi" ]] && ok "WiFi device: $wifi" || warn "No WiFi device found — hotspot setup will be skipped"
  [[ -n "$eth"  ]] && ok "Onboard ethernet device: $eth" || warn "No onboard ethernet device found — Ethernet DHCP-server setup will be skipped"
  if [[ -z "$wifi" && -z "$eth" ]]; then
    err "Neither WiFi nor onboard Ethernet present — nd-uplink-manager would have nothing to manage. --install will abort (LTE alone, via the modem/dispatcher, is not a substitute — it needs a stick plugged in and is independent of this check)."
  fi

  if [[ -n "$wifi" ]]; then
    if iw list 2>/dev/null | grep -A8 "Supported interface modes" | grep -qw AP; then
      ok "WiFi adapter supports AP mode (hotspot capable)"
    else
      err "WiFi adapter does NOT advertise AP mode — hotspot will not work"
    fi
  fi

  msg "Checking for ZTE USB modem…"
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb 2>/dev/null | grep -qi "19d2"; then
      ok "ZTE USB device detected via lsusb (vendor 19d2)"
    else
      warn "No ZTE USB device found via lsusb — modem may not be connected or is in storage mode"
    fi
  else
    warn "lsusb not available — install usbutils for USB-level detection"
  fi
  local lte_now; lte_now="$(nd_lte_iface)"
  msg "LTE interface now: ${lte_now:-<not present>}"

  if command -v netbird >/dev/null 2>&1; then
    ok "netbird is installed"
  else
    warn "netbird not found — 'netbird up' will be skipped at runtime"
  fi

  if [[ -f "$MODEMS_DB" ]]; then
    ok "Modem table already exists ($MODEMS_DB) — will not be overwritten"
  else
    msg "Would seed empty modem/SIM tables ($MODEMS_DB, $SIMS_DB) — add entries via the config UI"
  fi

  for name in "$ETH_CLIENT_CON" "$HOTSPOT_CON" "$ETH_SERVER_CON"; do
    if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$name"; then
      ok "NM profile '$name' exists"
    else
      warn "NM profile '$name' not found — will be created"
    fi
  done

  if [[ -f "$AVAHI_CONF" ]] && command -v avahi-daemon >/dev/null 2>&1; then
    ok "avahi-daemon config found — would scope allow-interfaces to managed iface(s) (${eth:-none}${wifi:+,$wifi}), avoiding Docker-bridge .local addresses"
  else
    warn "avahi-daemon not found — mDNS interface scoping will be skipped"
  fi

  msg "Hygiene preview (report only — nothing is killed in dry-run):"
  msg "Managed interfaces: $(nd_managed_ifaces | paste -sd' ' -)"
  local foreign; foreign="$(nd_foreign_dhcp 2>/dev/null || true)"
  if [[ -z "$foreign" ]]; then
    ok "No foreign dnsmasq/hostapd on managed interfaces (nothing to reap)"
  else
    while IFS='|' read -r pid iface comm args; do
      [[ -z "$pid" ]] && continue
      warn "Would reap foreign $comm (pid $pid) on $iface"
    done <<<"$foreign"
  fi

  echo
  msg "Would install under $ND_DIR: lib/, modem/, net/, bin/, webui/"
  msg "Would install dispatcher to $DISPATCHER_DST"
  msg "Would install systemd units to $SERVICE_DST and $WEBUI_SERVICE_DST"
  msg "Would symlink $STATUS_LINK and $ACTIVATE_LINK"
  msg "Would enable the config web UI on port $WEBUI_PORT (LAN-facing addresses + localhost only)"
  local would_create=()
  [[ -n "$wifi" ]] && would_create+=("$HOTSPOT_CON (AP/shared)")
  [[ -n "$eth"  ]] && would_create+=("$ETH_SERVER_CON (eth shared=DEFAULT)")
  if (( ${#would_create[@]} )); then
    msg "Would create NM profiles: $(IFS=', '; echo "${would_create[*]}")"
  else
    msg "No WiFi/Ethernet hardware detected — no NM profiles would be created (LTE-only setup)"
  fi
  msg "Would set LTE preferred (metric $LTE_METRIC) over WiFi (metric $WIFI_METRIC)"
  msg "Would enforce STRICT LTE-only egress for LAN clients (tagged ND_FWD chain)"
  msg "Cleanup scope: only foreign DHCP/AP daemons on our ifaces — usb0/BlueOS/Docker untouched"
  msg "Dry-run complete. No changes made."
}

### --- NM profile creation --------------------------------------------------
recreate_con() {
  local name="$1"
  if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$name"; then
    msg "Removing existing connection '$name' to recreate it cleanly…"
    nmcli con delete "$name" >/dev/null 2>&1 || true
  fi
}

create_hotspot() {
  local wifi="$1" ssid="$2" psk="$3"
  recreate_con "$HOTSPOT_CON"
  msg "Creating hotspot '$HOTSPOT_CON' (SSID '$ssid') on $wifi…"
  nmcli con add type wifi ifname "$wifi" con-name "$HOTSPOT_CON" \
        autoconnect no ssid "$ssid" >/dev/null
  nmcli con modify "$HOTSPOT_CON" \
        802-11-wireless.mode ap \
        802-11-wireless.band bg \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$psk" \
        ipv4.method shared \
        ipv6.method ignore >/dev/null
  ok "Hotspot profile ready (manager controls activation)."
}

create_eth_server() {
  local eth="$1"
  recreate_con "$ETH_SERVER_CON"
  msg "Creating ethernet DHCP-server (default) '$ETH_SERVER_CON' on $eth…"
  nmcli con add type ethernet ifname "$eth" con-name "$ETH_SERVER_CON" \
        autoconnect yes ipv4.method shared >/dev/null
  nmcli con modify "$ETH_SERVER_CON" \
        connection.autoconnect-priority 10 \
        ipv4.addresses "${ETH_SERVER_ADDR}" \
        ipv6.method ignore >/dev/null
  ok "Ethernet DHCP-server is the default role: gateway ${ETH_SERVER_ADDR%/*}, devices egress via LTE."
}

tune_eth_client() {
  local eth="$1"
  if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$ETH_CLIENT_CON"; then
    msg "Tuning DHCP-client profile '$ETH_CLIENT_CON' (manager-driven probe, timeout 8s)…"
    nmcli con modify "$ETH_CLIENT_CON" \
          connection.autoconnect no \
          ipv4.dhcp-timeout 8 \
          connection.autoconnect-retries 1 >/dev/null
    ok "DHCP-client profile set to manager-driven upstream probe."
  else
    warn "'$ETH_CLIENT_CON' not found — creating a probe profile on $eth…"
    nmcli con add type ethernet ifname "$eth" con-name "$ETH_CLIENT_CON" \
          autoconnect no ipv4.method auto >/dev/null
    nmcli con modify "$ETH_CLIENT_CON" ipv4.dhcp-timeout 8 connection.autoconnect-retries 1 >/dev/null
    ok "Created manager-driven DHCP-client probe profile '$ETH_CLIENT_CON'."
  fi
}

### --- avahi (mDNS) interface scoping ------------------------------------------
# By default avahi-daemon publishes .local addresses from every interface it
# sees — including Docker's docker0/br-*/veth* bridges. On a box running
# Docker (BlueOS), that means <hostname>.local can resolve to a
# container-only bridge address (e.g. 172.17.0.1) instead of the real LAN
# address, so `ping` by IP works but `ssh <hostname>.local` silently connects
# nowhere reachable. Scope avahi to just the interfaces this stack manages
# (onboard ethernet + WiFi, if present) so it only ever publishes a real,
# reachable LAN address.
configure_avahi() {
  local eth="$1" wifi="$2" ifaces
  [[ -f "$AVAHI_CONF" ]] || { warn "avahi-daemon.conf not found — skipping mDNS interface scoping"; return 0; }
  command -v avahi-daemon >/dev/null 2>&1 || { warn "avahi-daemon not installed — skipping mDNS interface scoping"; return 0; }

  ifaces="$eth"
  [[ -n "$wifi" ]] && ifaces="${ifaces:+$ifaces,}$wifi"
  [[ -n "$ifaces" ]] || { warn "No managed interface to scope avahi to — skipping"; return 0; }

  msg "Scoping avahi (mDNS) to managed interface(s): $ifaces (avoids publishing Docker bridge addresses)…"
  cp "$AVAHI_CONF" "${AVAHI_CONF}.bak-nd-uplink" 2>/dev/null || true
  if grep -q '^allow-interfaces=' "$AVAHI_CONF"; then
    sed -i "s|^allow-interfaces=.*|allow-interfaces=${ifaces}|" "$AVAHI_CONF"
  elif grep -q '^#allow-interfaces=' "$AVAHI_CONF"; then
    sed -i "s|^#allow-interfaces=.*|allow-interfaces=${ifaces}|" "$AVAHI_CONF"
  else
    sed -i "/^\[server\]/a allow-interfaces=${ifaces}" "$AVAHI_CONF"
  fi
  systemctl restart avahi-daemon 2>/dev/null \
    && ok "avahi-daemon restarted, now scoped to: $ifaces" \
    || warn "Could not restart avahi-daemon — scoping applied to $AVAHI_CONF but not yet active"
}

### --- file deployment ---------------------------------------------------------
deploy_files() {
  msg "Installing files under $ND_DIR…"
  mkdir -p "$ND_DIR/lib" "$ND_DIR/modem" "$ND_DIR/net" "$ND_DIR/bin" "$ND_DIR/webui"
  install -m 0644 "$LIB_SRC"      "$LIB_DST"
  install -m 0755 "$MODEM_SRC"    "$MODEM_DST"
  install -m 0755 "$MANAGER_SRC"  "$MANAGER_DST"
  install -m 0755 "$STATUS_SRC"   "$STATUS_DST"
  install -m 0755 "$WEBUI_SRC"    "$WEBUI_DST"
  ln -sf "$STATUS_DST" "$STATUS_LINK"
  ln -sf "$MODEM_DST"  "$ACTIVATE_LINK"
  ok "Installed lib + modem + manager + status + webui; symlinked nd-uplink-status and nd-zte-activate."

  msg "Seeding modem/SIM lookup tables (only if missing)…"
  for f in "$MODEMS_DB" "$SIMS_DB"; do
    [[ -f "$f" ]] || { echo '[]' > "$f"; chmod 600 "$f"; }
  done
  [[ -f "$ACTIVE_DB" ]] || { echo '{}' > "$ACTIVE_DB"; chmod 600 "$ACTIVE_DB"; }
  ok "Modem/SIM tables ready — add entries via the config UI."

  msg "Installing NetworkManager dispatcher hook…"
  install -m 0755 "$DISPATCHER_SRC" "$DISPATCHER_DST"
  ok "Dispatcher installed to $DISPATCHER_DST."

  msg "Installing systemd services…"
  install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
  install -m 0644 "$WEBUI_SERVICE_SRC" "$WEBUI_SERVICE_DST"
  systemctl daemon-reload
  ok "Systemd units installed."
}

### --- install --------------------------------------------------------------
# WIFI_DEV / ETH_DEV are set here and read again by verify() so it only checks
# for profiles this run actually meant to create.
WIFI_DEV=""
ETH_DEV=""

perform_install() {
  require_root
  nd_check_deps install "${DEPS[@]}"

  WIFI_DEV="$(nd_wifi_dev || true)"; ETH_DEV="$(nd_eth_dev || true)"

  # Either WiFi or onboard Ethernet is required — nd-uplink-manager needs at
  # least one local-LAN device to manage (hotspot and/or eth-server). LTE is
  # a separate, independent path (modem + dispatcher, installed below either
  # way) and depends on a stick being physically plugged in, so it can't
  # stand in for this check.
  [[ -n "$WIFI_DEV" || -n "$ETH_DEV" ]] \
    || { err "Neither WiFi nor onboard Ethernet found — aborting (LTE alone isn't a substitute here; see --dry-run)."; exit 1; }

  if [[ -n "$WIFI_DEV" ]]; then ok "WiFi device: $WIFI_DEV"
  else warn "No WiFi device found — skipping hotspot setup (no WiFi failover)"; fi
  if [[ -n "$ETH_DEV" ]]; then ok "Onboard ethernet device: $ETH_DEV"
  else warn "No onboard ethernet device found — skipping Ethernet DHCP-server setup"; fi

  # --- hotspot credentials (skip if already configured, unless reconfiguring) ---
  if [[ -n "$WIFI_DEV" ]]; then
    if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$HOTSPOT_CON"; then
      local reconf
      read -rp "Hotspot '$HOTSPOT_CON' already configured. Reconfigure SSID/passphrase? [y/N]: " reconf
      if [[ "$reconf" =~ ^[Yy] ]]; then
        _prompt_hotspot_creds "$WIFI_DEV"
      else
        ok "Keeping existing hotspot configuration."
      fi
    else
      _prompt_hotspot_creds "$WIFI_DEV"
    fi
  fi

  # --- NM profiles ---
  if [[ -n "$ETH_DEV" ]]; then
    create_eth_server "$ETH_DEV"
    tune_eth_client "$ETH_DEV"
  fi

  # --- avahi mDNS scoping (skip if neither managed iface is present) ---
  if [[ -n "$ETH_DEV" || -n "$WIFI_DEV" ]]; then
    configure_avahi "$ETH_DEV" "$WIFI_DEV"
  fi

  # --- files + dispatcher + service ---
  deploy_files

  # --- one-shot hygiene pass ---
  msg "Running initial hygiene pass…"
  "$MANAGER_DST" reap || warn "Hygiene pass reported an issue (continuing)"
  ok "Hygiene pass done (see 'journalctl -t nd-uplink' for any reaped daemons)."

  # enable (persist) then restart (not `enable --now`): --now is a no-op on an
  # already-running unit, so a reinstall would keep the OLD process — and the
  # freshly-deployed code would never take effect. restart picks up new code
  # whether the unit was running or stopped.
  msg "Enabling and (re)starting nd-uplink-manager.service…"
  systemctl enable nd-uplink-manager.service >/dev/null 2>&1 || true
  systemctl restart nd-uplink-manager.service
  ok "nd-uplink-manager.service enabled and (re)started."

  # Independent of WiFi/Ethernet presence — this must stay reachable even if
  # the rest of the stack is broken, so it can be used to fix it.
  # Same reasoning as above: restart so a redeployed webui (e.g. a changed
  # port default) is actually picked up, instead of the old process lingering.
  msg "Enabling and (re)starting nd-modem-webui.service (config UI, port $WEBUI_PORT)…"
  systemctl enable nd-modem-webui.service >/dev/null 2>&1 || true
  systemctl restart nd-modem-webui.service
  ok "nd-modem-webui.service enabled and (re)started."

  msg "Applying LTE-only egress firewall…"
  "$MANAGER_DST" fw-apply || warn "Firewall pass reported an issue (continuing)"
  ok "LTE-only firewall applied (ND_FWD)."

  msg "Reloading NetworkManager…"
  systemctl reload NetworkManager || warn "Could not reload NetworkManager"

  echo
  verify
  print_instructions
}

_prompt_hotspot_creds() {
  local wifi="$1" ssid psk psk2
  read -rp "Hotspot SSID [ND-JETSON]: " ssid; ssid="${ssid:-ND-JETSON}"
  while :; do
    read -rsp "Hotspot passphrase (min 8 chars): " psk;  echo
    read -rsp "Repeat passphrase: "               psk2; echo
    [[ "$psk" != "$psk2" ]] && { warn "Passphrases differ — try again."; continue; }
    (( ${#psk} < 8 )) && { warn "Too short (WPA needs >= 8) — try again."; continue; }
    break
  done
  create_hotspot "$wifi" "$ssid" "$psk"
}

### --- verify ------------------------------------------------------------------
# Post-install sanity sweep. Non-fatal: reports PASS/WARN so a partial
# success is visible instead of silently swallowed.
verify() {
  msg "Verifying installation…"
  local fail=0

  for f in "$LIB_DST" "$MODEM_DST" "$MANAGER_DST" "$STATUS_DST" "$DISPATCHER_DST"; do
    if bash -n "$f" 2>/dev/null; then ok "Syntax OK: $f"; else err "Syntax error in $f"; fail=1; fi
  done
  if python3 -m py_compile "$WEBUI_DST" 2>/dev/null; then ok "Syntax OK: $WEBUI_DST"
  else err "Syntax error in $WEBUI_DST"; fail=1; fi

  [[ -x "$DISPATCHER_DST" ]] && ok "Dispatcher installed and executable" \
    || { err "Dispatcher missing/not executable at $DISPATCHER_DST"; fail=1; }

  systemctl is-active --quiet nd-uplink-manager.service \
    && ok "nd-uplink-manager.service is active" \
    || { err "nd-uplink-manager.service is NOT active"; fail=1; }

  systemctl is-active --quiet nd-modem-webui.service \
    && ok "nd-modem-webui.service is active" \
    || { err "nd-modem-webui.service is NOT active"; fail=1; }
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${WEBUI_PORT}/"; then
    ok "Config UI responding on http://127.0.0.1:${WEBUI_PORT}"
  else
    warn "Config UI not responding yet on port ${WEBUI_PORT} (it may still be starting — check 'journalctl -u nd-modem-webui')"
  fi

  # Only check for profiles this run actually meant to create — a device
  # that was never present is a deliberate skip, not a failure.
  local -a expected_cons=()
  [[ -n "$WIFI_DEV" ]] && expected_cons+=("$HOTSPOT_CON")
  [[ -n "$ETH_DEV" ]] && expected_cons+=("$ETH_SERVER_CON" "$ETH_CLIENT_CON")
  for name in "${expected_cons[@]}"; do
    nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$name" \
      && ok "NM profile '$name' present" \
      || { warn "NM profile '$name' missing"; fail=1; }
  done

  [[ -L "$STATUS_LINK" && -e "$STATUS_LINK" ]] && ok "$STATUS_LINK resolves" \
    || { warn "$STATUS_LINK missing/broken"; fail=1; }
  [[ -L "$ACTIVATE_LINK" && -e "$ACTIVATE_LINK" ]] && ok "$ACTIVATE_LINK resolves" \
    || { warn "$ACTIVATE_LINK missing/broken"; fail=1; }

  for f in "$MODEMS_DB" "$SIMS_DB" "$ACTIVE_DB"; do
    if [[ -f "$f" ]]; then
      local perms; perms=$(stat -c '%a' "$f" 2>/dev/null || echo '?')
      [[ "$perms" == "600" ]] && ok "$f present, mode 600" \
        || warn "$f present but mode is $perms (expected 600)"
    else
      warn "$f missing — modem unlock will have nothing to look up until you add entries via the config UI"
      fail=1
    fi
  done

  if iptables -t filter -C FORWARD -j ND_FWD 2>/dev/null; then
    ok "ND_FWD firewall chain installed"
  else
    warn "ND_FWD chain not (yet) installed — check 'journalctl -t nd-uplink'"
  fi

  if [[ -f "$AVAHI_CONF" ]] && command -v avahi-daemon >/dev/null 2>&1; then
    if grep -q '^allow-interfaces=' "$AVAHI_CONF"; then
      ok "avahi scoped: $(grep '^allow-interfaces=' "$AVAHI_CONF")"
    else
      warn "avahi-daemon.conf has no allow-interfaces set — mDNS may publish Docker-bridge addresses"
    fi
    systemctl is-active --quiet avahi-daemon \
      && ok "avahi-daemon is active" \
      || warn "avahi-daemon is not active"
  fi

  if (( fail )); then
    warn "Verification found issues — see above. Installation is not fully clean."
  else
    ok "Verification passed."
  fi
}

### --- instructions --------------------------------------------------------
print_instructions() {
  echo
  ok "Installation complete."
  echo
  msg "Basic commands:"
  echo "  nd-uplink-status              — one-screen status (WiFi/Ethernet/LTE/firewall/hygiene)"
  echo "  nd-uplink-status -v            — same, plus a per-connection NM metric dump"
  echo "  sudo nd-zte-activate        — manually re-run the ZTE login/SIM-unlock workflow"
  echo "  journalctl -t nd-uplink -f     — watch failover-manager decisions live"
  echo "  journalctl -t nd-zte -n 50  — see the last modem activation run"
  echo "  sudo systemctl restart nd-uplink-manager   — restart the failover daemon"
  echo "  journalctl -u nd-modem-webui -f             — watch the config UI's own logs"
  echo "  sudo ./install.sh --uninstall           — remove the stack"
  echo
  msg "Modem/SIM config UI (add modems + SIMs, pick which is active, see status):"
  local -a webui_urls=()
  while IFS= read -r addr; do
    [[ -n "$addr" ]] && webui_urls+=("http://$addr:${WEBUI_PORT}")
  done < <(nd_managed_ifaces 2>/dev/null | while read -r ifc; do
             ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1
           done)
  webui_urls+=("http://127.0.0.1:${WEBUI_PORT}  (from this device, e.g. over SSH)")
  if (( ${#webui_urls[@]} > 1 )); then
    for u in "${webui_urls[@]}"; do echo "  $u"; done
  else
    echo "  ${webui_urls[0]}"
    echo "  (no hotspot/eth-server address up yet — it'll also be reachable there once one is)"
  fi
  echo "  No login (LAN-facing addresses + localhost only, never 0.0.0.0)."
  echo "  Add each modem's IMEI + WebUI password, each SIM's IMSI + PIN there — the"
  echo "  unlock workflow identifies what's plugged in and looks up credentials itself."
  echo
  msg "The modem's own stock web interface is still there if you'd rather use it directly:"
  echo "  http://192.168.0.1 (port 80) — reachable from this device (SSH in, then browse"
  echo "  there, or tunnel: ssh -L 8080:192.168.0.1:80 <user>@<this-host>) or by joining"
  echo "  the modem's own WiFi hotspot directly. Not needed if you use the config UI above."
  echo
  msg "Config files:"
  echo "  /opt/nd-uplink/.env — optional nd-uplink-manager tunables (poll interval, etc.)"
  echo
  msg "Firewall / egress note (STRICT LTE-only):"
  echo "  • LAN clients (WiFi hotspot + Ethernet-served devices) reach the internet"
  echo "    ONLY via the LTE stick. A tagged 'ND_FWD' chain (FORWARD #1) drops any"
  echo "    LAN→internet traffic that is not egressing the LTE interface."
  echo "  • If the LTE stick is absent/down, LAN clients have NO internet (by design)."
  echo
  msg "Hygiene / BlueOS coexistence note:"
  echo "  • nd-uplink-manager continuously reaps ONLY foreign dnsmasq/hostapd daemons"
  echo "    bound to our interfaces ($(nd_managed_ifaces 2>/dev/null | paste -sd'/' -))."
  echo "  • BlueOS Cable Guy (usb0), Docker NAT, and unrelated NM profiles are untouched."
  echo "  • IMPORTANT: do NOT configure Cable Guy to manage these interfaces — leave"
  echo "    them unmanaged in BlueOS, or it will fight nd-uplink-manager."
  echo
  if [[ -f "$AVAHI_CONF" ]] && command -v avahi-daemon >/dev/null 2>&1; then
    msg "mDNS (.local) note:"
    echo "  • avahi-daemon is scoped to this stack's managed interface(s) only, so"
    echo "    <hostname>.local resolves to the real LAN address instead of a Docker"
    echo "    bridge address (docker0/br-*)."
    echo "  • Backup of the previous config: ${AVAHI_CONF}.bak-nd-uplink"
  fi
}

### --- status ---------------------------------------------------------------
run_status() {
  if [[ -x "$STATUS_DST" ]]; then exec "$STATUS_DST" "${@:2}"
  elif [[ -x "$STATUS_SRC" ]]; then exec "$STATUS_SRC" "${@:2}"
  else err "status script not found"; exit 1; fi
}

### --- uninstall --------------------------------------------------------------
perform_uninstall() {
  require_root
  msg "Stopping and disabling nd-uplink-manager.service and nd-modem-webui.service…"
  systemctl disable --now nd-uplink-manager.service 2>/dev/null || true
  systemctl disable --now nd-modem-webui.service 2>/dev/null || true
  nd_fw_clear
  msg "Removing dispatcher…"
  rm -f "$DISPATCHER_DST"
  msg "Removing installed files (including the modem/SIM tables under $ND_DIR)…"
  rm -rf "$ND_DIR"
  rm -f "$STATUS_LINK" "$ACTIVATE_LINK"
  rm -f "$SERVICE_DST" "$WEBUI_SERVICE_DST"
  systemctl daemon-reload
  systemctl reload NetworkManager || true
  ok "Uninstalled nd-uplink-manager, nd-modem-webui, dispatcher, and $ND_DIR."
  warn "Left untouched (remove manually if desired):"
  echo "  • NM connection profiles: $HOTSPOT_CON, $ETH_SERVER_CON, $ETH_CLIENT_CON"
  echo "    (nmcli con delete <name>)"
  echo "  • avahi-daemon interface scoping ($AVAHI_CONF) — restore from"
  echo "    ${AVAHI_CONF}.bak-nd-uplink if you want the original config back"
}

### --- main -----------------------------------------------------------------
case "${1:-}" in
  --dry-run)    preflight ;;
  --install)    perform_install ;;
  --status)     run_status "$@" ;;
  --uninstall)  perform_uninstall ;;
  *) echo "Usage: $0 --dry-run | --install | --status [-v] | --uninstall"; exit 1 ;;
esac
