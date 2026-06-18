#!/usr/bin/env bash
#
# nd_net_install.sh — umbrella installer for the Jetson's resilient networking.
#
# Installs the WiFi client/hotspot + Ethernet DHCP-fallback manager, the
# nd-net-status command, and the supporting NetworkManager profiles. Also fixes
# the ZTE dispatcher so LTE is the preferred uplink.
#
# (The ZTE LTE modem half is installed separately via zte_install_script.sh.)
#
# Usage:
#   sudo ./nd_net_install.sh --dry-run
#   sudo ./nd_net_install.sh --install
#        ./nd_net_install.sh --status
#
set -Eeuo pipefail

### --- config ---------------------------------------------------------------
ND_DIR="/opt/nd-net"
MANAGER_SRC="./nd-net-manager.sh"
STATUS_SRC="./nd-net-status.sh"
LIB_SRC="./nd-net-lib.sh"
SERVICE_SRC="./nd-net-manager.service"
DISPATCHER_SRC="./00-nd-nm-dispatcher-zte-modem.sh"
UI_SRC="./nd-net-ui.py"
UI_SERVICE_SRC="./nd-net-ui.service"
UI_ENV_SRC="./nd-net-ui.env.example"

MANAGER_DST="$ND_DIR/nd-net-manager.sh"
STATUS_DST="$ND_DIR/nd-net-status.sh"
LIB_DST="$ND_DIR/nd-net-lib.sh"
STATUS_LINK="/usr/local/bin/nd-net-status"
SERVICE_DST="/etc/systemd/system/nd-net-manager.service"
UI_DST="$ND_DIR/nd-net-ui.py"
UI_ENV_DST="$ND_DIR/nd-net-ui.env"
UI_SERVICE_DST="/etc/systemd/system/nd-net-ui.service"

HOTSPOT_CON="nd-hotspot"
ETH_CLIENT_CON="Wired connection 1"
ETH_SERVER_CON="nd-eth-dhcp-server"
ETH_SERVER_ADDR="10.42.1.1/24"      # fixed gateway/subnet for the eth DHCP server

# Route metrics (lower = preferred): LTE preferred over WiFi.
LTE_METRIC=50
WIFI_METRIC=600

### --- colors / helpers -----------------------------------------------------
c_green="\033[1;32m"; c_red="\033[1;31m"; c_yellow="\033[1;33m"; c_blue="\033[1;34m"; c_reset="\033[0m"
msg() { echo -e "${c_blue}[*]${c_reset} $*"; }
ok()  { echo -e "${c_green}[OK]${c_reset} $*"; }
warn(){ echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err() { echo -e "${c_red}[ERR]${c_reset} $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This action needs root. Re-run with sudo."
    exit 1
  fi
}

### --- device detection -----------------------------------------------------
detect_wifi_dev() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
}
# Onboard ethernet = ethernet device named en*/eth* but NOT a USB enx* NIC (ZTE).
detect_eth_dev() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null \
    | awk -F: '$2=="ethernet" && $1 ~ /^(en|eth)/ && $1 !~ /^enx/ {print $1; exit}'
}

### --- dependency check -----------------------------------------------------
check_deps() {
  local mode="${1:-dry-run}"
  msg "Checking required tools…"
  local deps=(nmcli dnsmasq iw wpa_supplicant flock logger curl awk sed python3)
  local missing=()
  for d in "${deps[@]}"; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
  if (( ${#missing[@]} == 0 )); then
    ok "All required tools present."
    return 0
  fi
  warn "Missing: ${missing[*]}"
  if [[ "$mode" == "install" ]] && command -v apt-get >/dev/null 2>&1; then
    msg "Attempting apt-get install…"
    apt-get update -qq && apt-get install -y "${missing[@]}" || warn "Automatic install failed — install manually."
  fi
}

### --- dry run --------------------------------------------------------------
preflight() {
  msg "Running dry-run checks…"
  check_deps dry-run

  local wifi eth
  wifi="$(detect_wifi_dev || true)"; eth="$(detect_eth_dev || true)"
  [[ -n "$wifi" ]] && ok "WiFi device: $wifi" || err "No WiFi device found"
  [[ -n "$eth"  ]] && ok "Onboard ethernet device: $eth" || err "No onboard ethernet device found"

  if [[ -n "$wifi" ]]; then
    if iw list 2>/dev/null | grep -A8 "Supported interface modes" | grep -qw AP; then
      ok "WiFi adapter supports AP mode (hotspot capable)"
    else
      err "WiFi adapter does NOT advertise AP mode — hotspot will not work"
    fi
  fi

  systemctl is-active --quiet NetworkManager && ok "NetworkManager active" \
    || err "NetworkManager not active — required"

  if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$ETH_CLIENT_CON"; then
    ok "DHCP-client probe profile '$ETH_CLIENT_CON' exists (will set autoconnect=no, timeout 8s)"
  else
    warn "Profile '$ETH_CLIENT_CON' not found — a manager-driven probe profile will be created"
  fi

  for f in "$MANAGER_SRC" "$STATUS_SRC" "$LIB_SRC" "$SERVICE_SRC" \
           "$UI_SRC" "$UI_SERVICE_SRC" "$UI_ENV_SRC"; do
    [[ -f "$f" ]] && ok "Found $f" || err "Missing $f"
  done

  command -v python3 >/dev/null 2>&1 && ok "python3 present (required by nd-net-ui)" \
    || err "python3 not found — required by the nd-net-ui control panel"

  # Hygiene preview: report (do not kill) any foreign dnsmasq/hostapd on our ifaces.
  if [[ -r "$LIB_SRC" ]]; then
    # shellcheck source=/dev/null
    . "$LIB_SRC"
    msg "Managed interfaces: $(nd_managed_ifaces | paste -sd' ' -)"
    local lte_now; lte_now="$(nd_lte_iface)"
    msg "LTE interface now: ${lte_now:-<not present>}"
    local foreign; foreign="$(nd_foreign_dhcp 2>/dev/null || true)"
    if [[ -z "$foreign" ]]; then
      ok "No foreign dnsmasq/hostapd on managed interfaces (nothing to reap)"
    else
      while IFS='|' read -r pid iface comm args; do
        [[ -z "$pid" ]] && continue
        warn "Would reap foreign $comm (pid $pid) on $iface"
      done <<<"$foreign"
    fi
  fi

  msg "Would create NM profiles: $HOTSPOT_CON (AP/shared), $ETH_SERVER_CON (eth shared=DEFAULT)"
  msg "Ethernet default role: SERVE DHCP+NAT; probe upstream on link-up (client only if found)"
  msg "Would install: $LIB_DST, $MANAGER_DST, $STATUS_DST, $SERVICE_DST, symlink $STATUS_LINK"
  msg "Would install control UI: $UI_DST + $UI_SERVICE_DST (LAN-bound, no auth — see $UI_ENV_DST)"
  msg "Would set LTE preferred (metric $LTE_METRIC) over WiFi (metric $WIFI_METRIC) in the ZTE dispatcher"
  msg "Would enforce STRICT LTE-only egress for LAN clients (tagged ND_FWD chain)"
  msg "Cleanup scope: only foreign DHCP/AP daemons on our ifaces — usb0/BlueOS/Docker untouched"
  msg "Dry-run complete. No changes made."
}

### --- NM profile creation --------------------------------------------------
recreate_con() {
  # recreate_con <name>  — delete any existing connection with this id
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
  # The DEFAULT ethernet role: serve DHCP + NAT downstream devices to LTE.
  # Pin the subnet to a FIXED gateway so the address is predictable for anyone
  # reconnecting over ethernet (10.42.1.1; the WiFi hotspot uses 10.42.0.x).
  nmcli con add type ethernet ifname "$eth" con-name "$ETH_SERVER_CON" \
        autoconnect yes ipv4.method shared >/dev/null
  nmcli con modify "$ETH_SERVER_CON" \
        connection.autoconnect-priority 10 \
        ipv4.addresses "${ETH_SERVER_ADDR}" \
        ipv6.method ignore >/dev/null
  ok "Ethernet DHCP-server is the default role: gateway ${ETH_SERVER_ADDR%/*}, devices egress via LTE."
}

tune_eth_client() {
  # The DHCP-client profile is manager-driven: it is only brought up on a
  # link-up probe to detect an upstream DHCP server. autoconnect=no so NM never
  # races it against the server default; short dhcp-timeout for a quick probe.
  if nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "$ETH_CLIENT_CON"; then
    msg "Tuning DHCP-client profile '$ETH_CLIENT_CON' (manager-driven probe, timeout 8s)…"
    nmcli con modify "$ETH_CLIENT_CON" \
          connection.autoconnect no \
          ipv4.dhcp-timeout 8 \
          connection.autoconnect-retries 1 >/dev/null
    ok "DHCP-client profile set to manager-driven upstream probe."
  else
    warn "'$ETH_CLIENT_CON' not found — creating a probe profile on $1…"
    nmcli con add type ethernet ifname "$1" con-name "$ETH_CLIENT_CON" \
          autoconnect no ipv4.method auto >/dev/null
    nmcli con modify "$ETH_CLIENT_CON" ipv4.dhcp-timeout 8 connection.autoconnect-retries 1 >/dev/null
    ok "Created manager-driven DHCP-client probe profile '$ETH_CLIENT_CON'."
  fi
}

fix_dispatcher_metrics() {
  # Deploy the LTE-preferred ZTE dispatcher (this repo's copy already sets
  # LTE metric ${LTE_METRIC} < WiFi metric ${WIFI_METRIC}). Only act when the
  # ZTE dispatcher is already installed, so we don't deploy it in isolation.
  local disp="/etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh"
  if [[ ! -f "$disp" ]]; then
    warn "ZTE dispatcher not installed yet — run zte_install_script.sh, then re-run --install."
    return
  fi
  if [[ ! -f "$DISPATCHER_SRC" ]]; then
    warn "Dispatcher source $DISPATCHER_SRC missing — leaving installed dispatcher unchanged."
    return
  fi
  msg "Deploying LTE-preferred dispatcher (LTE ${LTE_METRIC} < WiFi ${WIFI_METRIC})…"
  install -m 0755 "$DISPATCHER_SRC" "$disp"
  ok "Dispatcher updated."
}

### --- install --------------------------------------------------------------
perform_install() {
  require_root
  check_deps install

  # Load shared helpers (used for the hygiene note + reap subcommand).
  if [[ -r "$LIB_SRC" ]]; then
    # shellcheck source=/dev/null
    . "$LIB_SRC"
  else
    err "Missing $LIB_SRC — cannot continue."; exit 1
  fi

  local wifi eth
  wifi="$(detect_wifi_dev || true)"; eth="$(detect_eth_dev || true)"
  [[ -n "$wifi" ]] || { err "No WiFi device found — aborting."; exit 1; }
  [[ -n "$eth"  ]] || { err "No onboard ethernet device found — aborting."; exit 1; }
  ok "WiFi=$wifi  Ethernet=$eth"

  # --- hotspot credentials ---
  local ssid psk psk2
  read -rp "Hotspot SSID [ND-JETSON]: " ssid; ssid="${ssid:-ND-JETSON}"
  while :; do
    read -rsp "Hotspot passphrase (min 8 chars): " psk;  echo
    read -rsp "Repeat passphrase: "               psk2; echo
    [[ "$psk" != "$psk2" ]] && { warn "Passphrases differ — try again."; continue; }
    (( ${#psk} < 8 )) && { warn "Too short (WPA needs >= 8) — try again."; continue; }
    break
  done

  # --- NM profiles ---
  create_hotspot "$wifi" "$ssid" "$psk"
  create_eth_server "$eth"
  tune_eth_client "$eth"
  fix_dispatcher_metrics

  # --- scripts ---
  msg "Installing scripts to $ND_DIR…"
  mkdir -p "$ND_DIR"
  install -m 0644 "$LIB_SRC"     "$LIB_DST"
  install -m 0755 "$MANAGER_SRC" "$MANAGER_DST"
  install -m 0755 "$STATUS_SRC"  "$STATUS_DST"
  ln -sf "$STATUS_DST" "$STATUS_LINK"
  ok "Installed lib + manager + status; '$STATUS_LINK' → status command."

  # --- control UI ---
  msg "Installing control UI (nd-net-ui)…"
  install -m 0755 "$UI_SRC" "$UI_DST"
  # Seed the UI's env file only if absent, so we never clobber a tuned bind list.
  if [[ -f "$UI_ENV_DST" ]]; then
    ok "UI config '$UI_ENV_DST' exists — leaving it unchanged."
  else
    install -m 0644 "$UI_ENV_SRC" "$UI_ENV_DST"
    ok "Seeded UI config '$UI_ENV_DST' (LAN/hotspot-bound, no auth)."
  fi
  install -m 0644 "$UI_SERVICE_SRC" "$UI_SERVICE_DST"
  ok "Installed control UI to $UI_DST + $UI_SERVICE_DST."

  # --- one-shot hygiene pass (reap foreign daemons on our ifaces) ---
  msg "Running initial hygiene pass…"
  "$MANAGER_DST" reap || warn "Hygiene pass reported an issue (continuing)"
  ok "Hygiene pass done (see 'journalctl -t nd-net' for any reaped daemons)."

  # --- service ---
  msg "Installing systemd service…"
  install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
  systemctl daemon-reload
  systemctl enable --now nd-net-manager.service
  ok "nd-net-manager.service enabled and started."
  systemctl enable --now nd-net-ui.service
  ok "nd-net-ui.service enabled and started."

  # --- one-shot firewall pass (install ND_FWD immediately) ---
  msg "Applying LTE-only egress firewall…"
  "$MANAGER_DST" fw-apply || warn "Firewall pass reported an issue (continuing)"
  ok "LTE-only firewall applied (ND_FWD)."

  echo
  ok "Installation complete."
  echo
  msg "Firewall / egress note (STRICT LTE-only):"
  echo "  • LAN clients (WiFi hotspot + Ethernet-served devices) reach the internet"
  echo "    ONLY via the LTE stick. A tagged 'ND_FWD' chain (FORWARD #1) drops any"
  echo "    LAN→internet traffic that is not egressing the LTE interface."
  echo "  • If the LTE stick is absent/down, LAN clients have NO internet (by design)."
  echo "  • NM 'shared' provides each LAN's DHCP + NAT + IPv4 forwarding."
  echo "  • Scope is our subnets only (-s 10.42.x.0/24); Docker/BlueOS chains untouched."
  echo "  • The Jetson's own traffic (INPUT/OUTPUT) is unaffected — it still prefers LTE"
  echo "    by route metric and stays reachable."
  echo
  msg "Hygiene / BlueOS coexistence note:"
  echo "  • nd-net-manager continuously reaps ONLY foreign dnsmasq/hostapd daemons"
  echo "    bound to our interfaces ($(nd_managed_ifaces 2>/dev/null | paste -sd'/' -))."
  echo "  • BlueOS Cable Guy (usb0), Docker NAT, interface IPs/routes and NM profiles"
  echo "    are left untouched."
  echo "  • IMPORTANT: do NOT configure Cable Guy to manage these interfaces — leave"
  echo "    them unmanaged in BlueOS, or it will fight nd-net-manager."
  echo
  msg "Check status any time with:  nd-net-status"
  msg "Watch decisions live with:   journalctl -t nd-net -f"
  echo
  msg "Control UI (status + .env editor + service start/stop/restart):"
  echo "  • Reachable from the hotspot/LAN at  http://10.42.0.1:8088  (WiFi clients)"
  echo "    or  http://10.42.1.1:8088  (ethernet-served devices)."
  echo "  • NO authentication — protected only by binding to LAN/hotspot IPs."
  echo "    Edit the bind list / port in  $UI_ENV_DST  (do NOT add 0.0.0.0)."
  echo "  • Edits to the .env files take effect after restarting nd-net-manager"
  echo "    (there's a restart button in the UI)."
  echo "  • Logs:  journalctl -u nd-net-ui -f"
}

### --- status ---------------------------------------------------------------
run_status() {
  if [[ -x "$STATUS_DST" ]]; then exec "$STATUS_DST"
  elif [[ -x "$STATUS_SRC" ]]; then exec "$STATUS_SRC"
  else err "status script not found"; exit 1; fi
}

### --- main -----------------------------------------------------------------
case "${1:-}" in
  --dry-run) preflight ;;
  --install) perform_install ;;
  --status)  run_status ;;
  *) echo "Usage: $0 --dry-run | --install | --status"; exit 1 ;;
esac
