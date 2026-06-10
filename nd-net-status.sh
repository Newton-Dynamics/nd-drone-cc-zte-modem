#!/usr/bin/env bash
#
# nd-net-status — one-screen operational status for the Jetson's networking.
# Installed to: /opt/nd-net/nd-net-status.sh  (symlinked as /usr/local/bin/nd-net-status)
#
# Shows, at a glance:
#   - ZTE LTE     : USB present? interface up? is LTE the active default route?
#   - WiFi        : client (joined SSID) / hotspot (AP SSID) / down
#   - Ethernet    : DHCP client (lease) / DHCP server (shared, serving subnet)
#   - Uplink      : effective default interface + metric, and an internet test
#
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

HOTSPOT_CON="nd-hotspot"
ETH_CLIENT_CON="Wired connection 1"
ETH_SERVER_CON="nd-eth-dhcp-server"

# Shared helpers (read-only foreign-daemon detection). Sibling copy first,
# then the installed location.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/nd-net-lib.sh"
[[ -r "$_LIB" ]] || _LIB="/opt/nd-net/nd-net-lib.sh"
# shellcheck source=/dev/null
[[ -r "$_LIB" ]] && . "$_LIB"

# colors (disabled when not a tty)
if [[ -t 1 ]]; then
  cG="\033[1;32m"; cR="\033[1;31m"; cY="\033[1;33m"; cB="\033[1;34m"; c0="\033[0m"
else
  cG=""; cR=""; cY=""; cB=""; c0=""
fi
hdr(){ echo -e "${cB}== $* ==${c0}"; }
ok(){  echo -e "  ${cG}●${c0} $*"; }
no(){  echo -e "  ${cR}●${c0} $*"; }
mb(){  echo -e "  ${cY}●${c0} $*"; }

# --- identify devices --------------------------------------------------------
wifi_dev=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')

# ZTE LTE interface = a net device whose USB vendor is 19d2 (enx*/eth1/usb0/wwan0)
lte_iface=""
for iface in eth1 wwan0 $(ls /sys/class/net 2>/dev/null | grep -E '^enx'); do
  vf="/sys/class/net/$iface/device/idVendor"
  [[ -f "$vf" && "$(cat "$vf" 2>/dev/null)" == "19d2" ]] && { lte_iface="$iface"; break; }
done

# effective default route (lowest metric wins)
best_iface=""; best_metric=99999
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  m=$(awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}' <<<"$line"); m="${m:-0}"
  d=$(awk '{for(i=1;i<=NF;i++) if($i=="dev")    print $(i+1)}' <<<"$line")
  if (( m < best_metric )); then best_metric=$m; best_iface="$d"; fi
done < <(ip route show default 2>/dev/null)

con_active(){ nmcli -t -f NAME con show --active 2>/dev/null | grep -Fxq -- "$1"; }

echo
# --- ZTE LTE -----------------------------------------------------------------
hdr "ZTE LTE"
if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi "19d2"; then
  ok "USB modem present ($(lsusb | grep -i 19d2 | head -1 | sed 's/^.*ID //'))"
else
  no "USB modem not detected (vendor 19d2)"
fi
if [[ -n "$lte_iface" ]]; then
  state=$(cat "/sys/class/net/$lte_iface/operstate" 2>/dev/null || echo unknown)
  ok "Interface $lte_iface is $state"
  if [[ "$best_iface" == "$lte_iface" ]]; then
    ok "LTE is the ACTIVE uplink (default route, metric $best_metric)"
  else
    mb "LTE up but standby (active uplink is ${best_iface:-none})"
  fi
else
  mb "No LTE interface present"
fi

echo
# --- WiFi --------------------------------------------------------------------
hdr "WiFi  (${wifi_dev:-none})"
if [[ -z "$wifi_dev" ]]; then
  no "No WiFi device"
elif [[ "$(nmcli -t -f WIFI radio 2>/dev/null)" != "enabled" ]]; then
  no "Radio disabled"
else
  wcon=$(nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null \
        | awk -F: -v d="$wifi_dev" '$3=="802-11-wireless" && $2==d {print $1; exit}')
  if [[ "$wcon" == "$HOTSPOT_CON" ]]; then
    ssid=$(nmcli -g 802-11-wireless.ssid con show "$HOTSPOT_CON" 2>/dev/null)
    ip=$(nmcli -g IP4.ADDRESS dev show "$wifi_dev" 2>/dev/null | head -1)
    clients=$(iw dev "$wifi_dev" station dump 2>/dev/null | grep -c '^Station' || echo 0)
    mb "HOTSPOT mode — SSID '${ssid}'  ${ip:+(${ip})}  clients: ${clients}"
  elif [[ -n "$wcon" ]]; then
    ssid=$(nmcli -g 802-11-wireless.ssid con show "$wcon" 2>/dev/null)
    ip=$(nmcli -g IP4.ADDRESS dev show "$wifi_dev" 2>/dev/null | head -1)
    sig=$(nmcli -t -f IN-USE,SIGNAL dev wifi list ifname "$wifi_dev" 2>/dev/null \
          | awk -F: '$1=="*"{print $2; exit}')
    ok "CLIENT mode — joined '${ssid}'  ${ip:+(${ip})}  ${sig:+signal ${sig}%}"
  else
    no "Disconnected (no client, no hotspot)"
  fi
fi

echo
# --- Ethernet ----------------------------------------------------------------
hdr "Ethernet"
if con_active "$ETH_SERVER_CON"; then
  edev=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | awk -F: -v n="$ETH_SERVER_CON" '$1==n{print $2; exit}')
  ip=$(nmcli -g IP4.ADDRESS dev show "$edev" 2>/dev/null | head -1)
  mb "DHCP SERVER mode on ${edev:-?} — serving ${ip:-10.42.x.1} (no upstream DHCP)"
  leases="/var/lib/NetworkManager/dnsmasq-${edev}.leases"
  [[ -f "$leases" ]] && ok "Active leases: $(wc -l <"$leases")"
elif con_active "$ETH_CLIENT_CON"; then
  edev=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | awk -F: -v n="$ETH_CLIENT_CON" '$1==n{print $2; exit}')
  ip=$(nmcli -g IP4.ADDRESS dev show "$edev" 2>/dev/null | head -1)
  ok "DHCP CLIENT mode on ${edev:-?} — lease ${ip:-none}"
else
  no "'$ETH_CLIENT_CON' / '$ETH_SERVER_CON' not active — check 'nmcli device'"
fi

echo
# --- Uplink + connectivity ---------------------------------------------------
hdr "Uplink & Internet"
if [[ -n "$best_iface" ]]; then
  label="$best_iface"
  [[ "$best_iface" == "$lte_iface" ]] && label="$best_iface (LTE)"
  [[ "$best_iface" == "$wifi_dev"  ]] && label="$best_iface (WiFi)"
  ok "Default route via $label (metric $best_metric)"
else
  no "No default route"
fi
rtt=$(ping -c 2 -W 3 -q 1.1.1.1 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
[[ -n "$rtt" ]] && ok "Ping 1.1.1.1 — avg ${rtt} ms" || no "Ping 1.1.1.1 — unreachable"
code=$(curl -sSo /dev/null -w "%{http_code}" --max-time 5 \
       https://connectivity.gstatic.com/generate_204 2>/dev/null)
[[ "$code" == "204" ]] && ok "HTTPS connectivity OK (204)" || no "HTTPS connectivity FAILED (${code:-timeout})"

echo
# --- LAN egress (LTE-only policy) --------------------------------------------
hdr "LAN egress (LTE-only)"
if ! declare -f nd_shared_subnets >/dev/null 2>&1; then
  mb "nd-net-lib.sh not loaded — LAN-egress check unavailable"
else
  lte_if="$(nd_lte_iface)"
  subnets="$(nd_shared_subnets | paste -sd' ' -)"
  if [[ -z "$subnets" ]]; then
    ok "No LAN currently served (no hotspot / eth-server subnet active)"
  elif [[ -n "$lte_if" ]]; then
    ok "Serving ${subnets} → internet via LTE ($lte_if)"
  else
    no "Serving ${subnets} → internet CUT (no LTE stick; strict LTE-only)"
  fi
  # Confirm the firewall chain is installed at the top of FORWARD.
  if iptables -t filter -C FORWARD -j ND_FWD 2>/dev/null; then
    ok "ND_FWD chain installed (FORWARD → ND_FWD)"
  elif [[ "$(id -u)" != "0" ]]; then
    mb "ND_FWD check needs root (run: sudo nd-net-status)"
  else
    no "ND_FWD chain NOT installed — run: sudo systemctl restart nd-net-manager"
  fi
fi

echo
# --- Hygiene -----------------------------------------------------------------
hdr "Hygiene"
if ! declare -f nd_foreign_dhcp >/dev/null 2>&1; then
  mb "nd-net-lib.sh not loaded — foreign-daemon check unavailable"
else
  ifaces=$(nd_managed_ifaces 2>/dev/null | paste -sd' ' -)
  foreign="$(nd_foreign_dhcp 2>/dev/null)"
  if [[ -z "$foreign" ]]; then
    ok "No foreign DHCP/AP daemons on managed interfaces (${ifaces:-none})"
  else
    while IFS='|' read -r pid iface comm args; do
      [[ -z "$pid" ]] && continue
      no "Foreign $comm (pid $pid) on $iface — will be reaped by nd-net-manager"
    done <<<"$foreign"
  fi
fi
echo
