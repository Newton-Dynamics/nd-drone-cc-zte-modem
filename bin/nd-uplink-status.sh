#!/usr/bin/env bash
#
# nd-uplink-status — one-screen operational status for the Jetson's networking
# and ZTE modem. Installed to: /opt/nd-uplink/bin/nd-uplink-status.sh
# (symlinked as /usr/local/bin/nd-uplink-status)
#
# Shows, at a glance:
#   - ZTE LTE     : USB present? interface up? is LTE the active default route?
#   - WiFi        : client (joined SSID) / hotspot (AP SSID) / down
#   - Ethernet    : DHCP client (lease) / DHCP server (shared, serving subnet)
#   - Uplink      : effective default interface + metric, ping/DNS/HTTPS tests
#   - LAN egress  : LTE-only firewall policy state
#   - Hygiene     : foreign DHCP/AP daemons on our managed interfaces
#
# Pass -v/--verbose for a per-connection NM route-metric dump.
# Pass --json for a machine-readable dump instead (used by nd-modem-webui) —
# same underlying detection, just rendered as JSON instead of printed.
#
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

VERBOSE=0
JSON_MODE=0
case "${1:-}" in
  -v|--verbose) VERBOSE=1 ;;
  --json) JSON_MODE=1 ;;
esac

HOTSPOT_CON="nd-hotspot"
ETH_CLIENT_CON="Wired connection 1"
ETH_SERVER_CON="nd-eth-dhcp-server"

# Shared helpers (read-only device detection + foreign-daemon check). Prefer
# the repo-relative sibling, fall back to the fixed install path.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_LIB="$_SELF_DIR/../lib/nd-common.sh"
[[ -r "$_LIB" ]] || _LIB="/opt/nd-uplink/lib/nd-common.sh"
# shellcheck source=/dev/null
[[ -r "$_LIB" ]] && . "$_LIB"

# colors (disabled when not a tty, and unused entirely in --json mode) — reuse
# lib's if loaded, else define locally.
if ! declare -f ok >/dev/null 2>&1; then
  if [[ -t 1 ]]; then
    cG="\033[1;32m"; cR="\033[1;31m"; cY="\033[1;33m"; c0="\033[0m"
  else
    cG=""; cR=""; cY=""; c0=""
  fi
fi
cB_hdr="\033[1;34m"; c0_hdr="\033[0m"
[[ -t 1 ]] || { cB_hdr=""; c0_hdr=""; }
hdr(){ echo -e "${cB_hdr}== $* ==${c0_hdr}"; }
line_ok(){  echo -e "  ${cG:-}●${c0:-} $*"; }
line_no(){  echo -e "  ${cR:-}●${c0:-} $*"; }
line_mb(){  echo -e "  ${cY:-}●${c0:-} $*"; }

# ============================================================================
# Detection — computed once, rendered below either as text or as JSON.
# ============================================================================

# --- ZTE LTE -----------------------------------------------------------------
lte_usb_present=0
lte_usb_id=""
if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi "19d2"; then
  lte_usb_present=1
  lte_usb_id=$(lsusb | grep -i 19d2 | head -1 | sed 's/^.*ID //')
fi
lte_iface=$(declare -f nd_lte_iface >/dev/null 2>&1 && nd_lte_iface || true)
# Distinct physical modems attached — >1 means they collide on 192.168.0.1.
lte_modem_count=""
declare -f nd_lte_modem_count >/dev/null 2>&1 && lte_modem_count=$(nd_lte_modem_count 2>/dev/null || echo "")
lte_operstate=""
[[ -n "$lte_iface" ]] && lte_operstate=$(cat "/sys/class/net/$lte_iface/operstate" 2>/dev/null || echo unknown)

# effective default route (lowest metric wins)
best_iface=""; best_metric=99999
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  m=$(awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}' <<<"$line"); m="${m:-0}"
  d=$(awk '{for(i=1;i<=NF;i++) if($i=="dev")    print $(i+1)}' <<<"$line")
  if (( m < best_metric )); then best_metric=$m; best_iface="$d"; fi
done < <(ip route show default 2>/dev/null)
lte_is_active_uplink=0
[[ -n "$lte_iface" && "$best_iface" == "$lte_iface" ]] && lte_is_active_uplink=1

# Does the modem itself have working data, independent of whether it's
# currently the system's default route? Bound to the LTE interface directly
# (curl --interface) rather than testing whatever happens to be active, so
# this stays meaningful even when Ethernet/WiFi is the current uplink.
# Binding to an interface by name needs root (SO_BINDTODEVICE) — reported as
# unknown (null) rather than guessed at when not root.
#
# Target is a fixed IP (Cloudflare's 1.1.1.1, already trusted below for the
# ping check), not a hostname: --interface binds EVERY socket for the
# transfer to that physical device, including the one that would otherwise
# query the local systemd-resolved stub at 127.0.0.53 — a loopback address,
# unreachable once forced onto a non-loopback interface. Any hostname lookup
# through this check fails for that reason alone, regardless of whether the
# modem's data path is actually fine. See https_ok below for why the generic
# (unbound) check moved off hostnames too.
#
# Backgrounded (see "wait for backgrounded network checks" below) — this,
# the ping, and the HTTPS check are the only slow parts of this script, and
# running them one after another rather than in parallel is what made every
# call take 6+ seconds.
lte_data_ok=""
_lte_data_tmp=""
if [[ -n "$lte_iface" && "$(id -u)" == "0" ]]; then
  _lte_data_tmp=$(mktemp)
  ( curl -sSo /dev/null -w "%{http_code}" --interface "$lte_iface" --max-time 5 \
      https://1.1.1.1/ 2>/dev/null > "$_lte_data_tmp" ) &
  _lte_data_pid=$!
fi

# --- WiFi --------------------------------------------------------------------
con_active(){ nmcli -t -f NAME con show --active 2>/dev/null | grep -Fxq -- "$1"; }

wifi_dev=$(declare -f nd_wifi_dev >/dev/null 2>&1 && nd_wifi_dev || nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
wifi_radio_enabled=0
wifi_mode="no-device"
wifi_ssid=""; wifi_ip=""; wifi_clients=""; wifi_signal=""

if [[ -n "$wifi_dev" ]]; then
  if [[ "$(nmcli -t -f WIFI radio 2>/dev/null)" == "enabled" ]]; then
    wifi_radio_enabled=1
    wcon=$(nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null \
          | awk -F: -v d="$wifi_dev" '$3=="802-11-wireless" && $2==d {print $1; exit}')
    if [[ "$wcon" == "$HOTSPOT_CON" ]]; then
      wifi_mode="hotspot"
      wifi_ssid=$(nmcli -g 802-11-wireless.ssid con show "$HOTSPOT_CON" 2>/dev/null)
      wifi_ip=$(nmcli -g IP4.ADDRESS dev show "$wifi_dev" 2>/dev/null | head -1)
      wifi_clients=$(iw dev "$wifi_dev" station dump 2>/dev/null | grep -c '^Station' || echo 0)
    elif [[ -n "$wcon" ]]; then
      wifi_mode="client"
      wifi_ssid=$(nmcli -g 802-11-wireless.ssid con show "$wcon" 2>/dev/null)
      wifi_ip=$(nmcli -g IP4.ADDRESS dev show "$wifi_dev" 2>/dev/null | head -1)
      wifi_signal=$(nmcli -t -f IN-USE,SIGNAL dev wifi list ifname "$wifi_dev" 2>/dev/null \
            | awk -F: '$1=="*"{print $2; exit}')
    else
      wifi_mode="disconnected"
    fi
  else
    wifi_mode="radio-off"
  fi
fi

# --- Ethernet ----------------------------------------------------------------
eth_mode="inactive"; eth_dev_name=""; eth_ip=""; eth_leases=""
if con_active "$ETH_SERVER_CON"; then
  eth_mode="server"
  eth_dev_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | awk -F: -v n="$ETH_SERVER_CON" '$1==n{print $2; exit}')
  eth_ip=$(nmcli -g IP4.ADDRESS dev show "$eth_dev_name" 2>/dev/null | head -1)
  leases_file="/var/lib/NetworkManager/dnsmasq-${eth_dev_name}.leases"
  [[ -f "$leases_file" ]] && eth_leases=$(wc -l <"$leases_file")
elif con_active "$ETH_CLIENT_CON"; then
  eth_mode="client"
  eth_dev_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | awk -F: -v n="$ETH_CLIENT_CON" '$1==n{print $2; exit}')
  eth_ip=$(nmcli -g IP4.ADDRESS dev show "$eth_dev_name" 2>/dev/null | head -1)
fi

# --- Uplink + connectivity ---------------------------------------------------
uplink_label=""
if [[ -n "$best_iface" ]]; then
  uplink_label="$best_iface"
  [[ "$best_iface" == "$lte_iface" ]] && uplink_label="$best_iface (LTE)"
  [[ "$best_iface" == "$wifi_dev"  ]] && uplink_label="$best_iface (WiFi)"
fi
# Backgrounded alongside the LTE-data check above — collected in "wait for
# backgrounded network checks" below.
_ping_tmp=$(mktemp)
( ping -c 2 -W 3 -q 1.1.1.1 2>/dev/null > "$_ping_tmp" ) &
_ping_pid=$!

dns_ok=0
getent hosts google.com >/dev/null 2>&1 && dns_ok=1

# Fixed IP target (not a hostname): on at least one network we've seen this
# run on, the local DNS server flat-out refuses to resolve Google's
# captive-portal-check hostnames (connectivity.gstatic.com) — a real NXDOMAIN
# from that network's resolver, not a script bug (deliberate filtering of
# exactly these domains is common on managed/corporate networks, to suppress
# "sign in to network" prompts). A hostname-based check is at the mercy of
# whatever DNS policy the current network enforces; testing a fixed IP this
# script already trusts for the ping check above sidesteps that entirely.
_https_tmp=$(mktemp)
( curl -sSo /dev/null -w "%{http_code}" --max-time 5 \
    https://1.1.1.1/ 2>/dev/null > "$_https_tmp" ) &
_https_pid=$!

# --- LAN egress (LTE-only policy) --------------------------------------------
fw_lib_loaded=0; declare -f nd_shared_subnets >/dev/null 2>&1 && fw_lib_loaded=1
subnets=""; fw_installed=""
if (( fw_lib_loaded )); then
  subnets="$(nd_shared_subnets | paste -sd' ' -)"
  if iptables -t filter -C FORWARD -j ND_FWD 2>/dev/null; then fw_installed=1
  elif [[ "$(id -u)" == "0" ]]; then fw_installed=0
  fi # else leave empty: "unknown, needs root"
fi

# --- Hygiene -----------------------------------------------------------------
hygiene_lib_loaded=0; declare -f nd_foreign_dhcp >/dev/null 2>&1 && hygiene_lib_loaded=1
managed_ifaces=""; foreign=""
if (( hygiene_lib_loaded )); then
  managed_ifaces=$(nd_managed_ifaces 2>/dev/null | paste -sd' ' -)
  foreign="$(nd_foreign_dhcp 2>/dev/null)"
fi

# --- wait for backgrounded network checks ------------------------------------
# ping, HTTPS, and (when applicable) the LTE-bound check all ran in parallel
# above — worst case is now max(ping, https, lte) instead of their sum.
wait "$_ping_pid" 2>/dev/null
rtt=$(awk -F'/' '/rtt|round-trip/{print $5}' "$_ping_tmp" 2>/dev/null)
rm -f "$_ping_tmp"

wait "$_https_pid" 2>/dev/null
https_code=$(cat "$_https_tmp" 2>/dev/null)
rm -f "$_https_tmp"
# Any real HTTP response (not curl's "000" no-response sentinel) is proof of
# a genuine, un-intercepted TLS path to a real internet host — a captive
# portal or transparent proxy can't complete a valid TLS handshake for an IP
# it doesn't hold a certificate for, so we don't need to match one specific
# status code the way the old generate_204 check did.
https_ok=0
[[ -n "$https_code" && "$https_code" != "000" ]] && https_ok=1

if [[ -n "$_lte_data_tmp" ]]; then
  wait "$_lte_data_pid" 2>/dev/null
  lte_data_code=$(cat "$_lte_data_tmp" 2>/dev/null)
  [[ -n "$lte_data_code" && "$lte_data_code" != "000" ]] && lte_data_ok=1 || lte_data_ok=0
  rm -f "$_lte_data_tmp"
fi

# ============================================================================
# Render — JSON or human text
# ============================================================================

if (( JSON_MODE )); then
  foreign_json="[]"
  if [[ -n "$foreign" ]]; then
    foreign_json=$(while IFS='|' read -r pid iface comm args; do
      [[ -z "$pid" ]] && continue
      jq -n --arg pid "$pid" --arg iface "$iface" --arg comm "$comm" --arg args "$args" \
        '{pid: $pid, iface: $iface, comm: $comm, args: $args}'
    done <<<"$foreign" | jq -s '.')
  fi
  managed_ifaces_json=$(printf '%s\n' $managed_ifaces | jq -R -s 'split("\n") | map(select(length>0))')
  subnets_json=$(printf '%s\n' $subnets | jq -R -s 'split("\n") | map(select(length>0))')

  jq -n \
    --argjson lte_usb_present "$lte_usb_present" \
    --arg lte_usb_id "$lte_usb_id" \
    --arg lte_modem_count "$lte_modem_count" \
    --arg lte_iface "$lte_iface" \
    --arg lte_operstate "$lte_operstate" \
    --argjson lte_active_uplink "$lte_is_active_uplink" \
    --arg lte_data_ok "$lte_data_ok" \
    --arg wifi_device "$wifi_dev" \
    --argjson wifi_radio_enabled "$wifi_radio_enabled" \
    --arg wifi_mode "$wifi_mode" \
    --arg wifi_ssid "$wifi_ssid" \
    --arg wifi_ip "$wifi_ip" \
    --arg wifi_clients "$wifi_clients" \
    --arg wifi_signal "$wifi_signal" \
    --arg eth_mode "$eth_mode" \
    --arg eth_device "$eth_dev_name" \
    --arg eth_ip "$eth_ip" \
    --arg eth_leases "$eth_leases" \
    --arg uplink_iface "$best_iface" \
    --arg uplink_label "$uplink_label" \
    --argjson uplink_metric "${best_metric/99999/null}" \
    --arg ping_ms "$rtt" \
    --argjson dns_ok "$dns_ok" \
    --argjson https_ok "$https_ok" \
    --arg https_code "$https_code" \
    --argjson served_subnets "$subnets_json" \
    --arg fw_lte_iface "$lte_iface" \
    --arg fw_installed "$fw_installed" \
    --argjson managed_ifaces "$managed_ifaces_json" \
    --argjson foreign "$foreign_json" \
    '{
      lte: {
        usb_present: ($lte_usb_present == 1),
        usb_id: ($lte_usb_id | if length > 0 then . else null end),
        modem_count: ($lte_modem_count | if length > 0 then tonumber else null end),
        iface: ($lte_iface | if length > 0 then . else null end),
        operstate: ($lte_operstate | if length > 0 then . else null end),
        active_uplink: ($lte_active_uplink == 1),
        data_ok: (if $lte_data_ok == "1" then true elif $lte_data_ok == "0" then false else null end)
      },
      wifi: {
        device: ($wifi_device | if length > 0 then . else null end),
        radio_enabled: ($wifi_radio_enabled == 1),
        mode: $wifi_mode,
        ssid: ($wifi_ssid | if length > 0 then . else null end),
        ip: ($wifi_ip | if length > 0 then . else null end),
        clients: ($wifi_clients | if length > 0 then tonumber else null end),
        signal: ($wifi_signal | if length > 0 then . else null end)
      },
      ethernet: {
        mode: $eth_mode,
        device: ($eth_device | if length > 0 then . else null end),
        ip: ($eth_ip | if length > 0 then . else null end),
        leases: ($eth_leases | if length > 0 then tonumber else null end)
      },
      uplink: {
        iface: ($uplink_iface | if length > 0 then . else null end),
        label: ($uplink_label | if length > 0 then . else null end),
        metric: $uplink_metric,
        ping_ms: ($ping_ms | if length > 0 then . else null end),
        dns_ok: ($dns_ok == 1),
        https_ok: ($https_ok == 1),
        https_code: ($https_code | if length > 0 then . else null end)
      },
      firewall: {
        served_subnets: $served_subnets,
        lte_iface: ($fw_lte_iface | if length > 0 then . else null end),
        chain_installed: (if $fw_installed == "1" then true elif $fw_installed == "0" then false else null end)
      },
      hygiene: {
        managed_ifaces: $managed_ifaces,
        foreign: $foreign
      }
    }'
  exit 0
fi

echo
hdr "ZTE LTE"
if (( lte_usb_present )); then
  line_ok "USB modem present ($lte_usb_id)"
else
  line_no "USB modem not detected (vendor 19d2)"
fi
if [[ "$lte_modem_count" =~ ^[0-9]+$ ]] && (( lte_modem_count > 1 )); then
  line_no "MULTIPLE modems attached ($lte_modem_count) — all ZTE sticks share 192.168.0.1 and cannot be told apart; keep only one plugged in (routing, firewall and modem reads are unreliable otherwise)."
fi
if [[ -n "$lte_iface" ]]; then
  line_ok "Interface $lte_iface is ${lte_operstate:-unknown}"
  if (( lte_is_active_uplink )); then
    line_ok "LTE is the ACTIVE uplink (default route, metric $best_metric)"
  else
    line_mb "LTE up but standby (active uplink is ${best_iface:-none})"
  fi
  case "$lte_data_ok" in
    1) line_ok "Mobile data reachable via $lte_iface (checked directly, independent of the current default route)" ;;
    0) line_no "Mobile data NOT reachable via $lte_iface" ;;
    *) line_mb "Mobile data check needs root (run: sudo nd-uplink-status)" ;;
  esac
else
  line_mb "No LTE interface present"
fi

echo
hdr "WiFi  (${wifi_dev:-none})"
case "$wifi_mode" in
  no-device)   line_no "No WiFi device" ;;
  radio-off)   line_no "Radio disabled" ;;
  hotspot)     line_mb "HOTSPOT mode — SSID '${wifi_ssid}'  ${wifi_ip:+(${wifi_ip})}  clients: ${wifi_clients:-0}" ;;
  client)      line_ok "CLIENT mode — joined '${wifi_ssid}'  ${wifi_ip:+(${wifi_ip})}  ${wifi_signal:+signal ${wifi_signal}%}" ;;
  disconnected) line_no "Disconnected (no client, no hotspot)" ;;
esac

echo
hdr "Ethernet"
case "$eth_mode" in
  server) line_mb "DHCP SERVER mode on ${eth_dev_name:-?} — serving ${eth_ip:-10.42.x.1} (no upstream DHCP)"
          [[ -n "$eth_leases" ]] && line_ok "Active leases: $eth_leases" ;;
  client) line_ok "DHCP CLIENT mode on ${eth_dev_name:-?} — lease ${eth_ip:-none}" ;;
  *)      line_no "'$ETH_CLIENT_CON' / '$ETH_SERVER_CON' not active — check 'nmcli device'" ;;
esac

echo
hdr "Uplink & Internet"
if [[ -n "$best_iface" ]]; then
  line_ok "Default route via $uplink_label (metric $best_metric)"
else
  line_no "No default route"
fi
[[ -n "$rtt" ]] && line_ok "Ping 1.1.1.1 — avg ${rtt} ms" || line_no "Ping 1.1.1.1 — unreachable"
(( dns_ok )) && line_ok "DNS resolution OK" || line_no "DNS resolution FAILED"
(( https_ok )) && line_ok "HTTPS connectivity OK (${https_code})" || line_no "HTTPS connectivity FAILED (${https_code:-timeout})"

if (( VERBOSE )); then
  echo
  hdr "NetworkManager connections (verbose)"
  nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null \
    | while IFS=: read -r name dev type; do
        metric=$(nmcli -g ipv4.route-metric con show "$name" 2>/dev/null || echo "?")
        printf "  %-30s dev=%-10s type=%-16s metric=%s\n" "$name" "$dev" "$type" "$metric"
      done
fi

echo
hdr "LAN egress (LTE-only)"
if (( ! fw_lib_loaded )); then
  line_mb "nd-common.sh not loaded — LAN-egress check unavailable"
else
  if [[ -z "$subnets" ]]; then
    line_ok "No LAN currently served (no hotspot / eth-server subnet active)"
  elif [[ -n "$lte_iface" ]]; then
    line_ok "Serving ${subnets} → internet via LTE ($lte_iface)"
  else
    line_no "Serving ${subnets} → internet CUT (no LTE stick; strict LTE-only)"
  fi
  if [[ "$fw_installed" == "1" ]]; then
    line_ok "ND_FWD chain installed (FORWARD → ND_FWD)"
  elif [[ "$fw_installed" == "0" ]]; then
    line_no "ND_FWD chain NOT installed — run: sudo systemctl restart nd-uplink-manager"
  else
    line_mb "ND_FWD check needs root (run: sudo nd-uplink-status)"
  fi
fi

echo
hdr "Hygiene"
if (( ! hygiene_lib_loaded )); then
  line_mb "nd-common.sh not loaded — foreign-daemon check unavailable"
else
  if [[ -z "$foreign" ]]; then
    line_ok "No foreign DHCP/AP daemons on managed interfaces (${managed_ifaces:-none})"
  else
    while IFS='|' read -r pid iface comm args; do
      [[ -z "$pid" ]] && continue
      line_no "Foreign $comm (pid $pid) on $iface — will be reaped by nd-uplink-manager"
    done <<<"$foreign"
  fi
fi
echo
msg_hint() { echo -e "  $*"; }
hdr "Modem control"
msg_hint "Manually re-trigger ZTE login/unlock:  sudo nd-zte-activate"
msg_hint "Watch modem activation logs:            journalctl -t nd-zte -n 50"
echo
