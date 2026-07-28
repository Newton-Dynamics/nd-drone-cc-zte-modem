#!/usr/bin/env bash
#
# nd-common.sh — shared helpers for the nd-uplink / nd-zte-modem stack.
# Installed to: /opt/nd-uplink/lib/nd-common.sh  (sourced, not executed directly)
#
# Covers: console output, root/dependency checks, device detection
# (wifi / onboard-ethernet / LTE), foreign DHCP/AP daemon detection+reap,
# and the LTE-only egress firewall (tagged chain ND_FWD).
#
# Scope is deliberately narrow (user chose "coexist, minimal cleanup"): the
# ONLY processes ever killed are a foreign dnsmasq/hostapd bound to an
# interface THIS stack manages (wifi + onboard ethernet). The LTE stick is a
# USB client interface that runs no local DHCP/AP daemon, so it is never a
# managed iface. We never flush iptables, never touch addresses/routes, and
# never touch a non-managed interface (so BlueOS's usb0 can never match).
#
# shellcheck shell=bash

ND_LOGTAG="${ND_LOGTAG:-nd-uplink}"

# --- console output (installer / interactive use) ----------------------------
if [[ -t 1 ]]; then
  nd_cG="\033[1;32m"; nd_cR="\033[1;31m"; nd_cY="\033[1;33m"; nd_cB="\033[1;34m"; nd_c0="\033[0m"
else
  nd_cG=""; nd_cR=""; nd_cY=""; nd_cB=""; nd_c0=""
fi
msg()  { echo -e "${nd_cB}[*]${nd_c0} $*"; }
ok()   { echo -e "${nd_cG}[OK]${nd_c0} $*"; }
warn() { echo -e "${nd_cY}[WARN]${nd_c0} $*"; }
err()  { echo -e "${nd_cR}[ERR]${nd_c0} $*" >&2; }

# --- syslog (daemon / dispatcher use) ----------------------------------------
nd_log() { /usr/bin/logger -t "$ND_LOGTAG" -- "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This action needs root. Re-run with sudo."
    exit 1
  fi
}

# --- dependency check ---------------------------------------------------------
# nd_check_deps <dry-run|install> <tool> [tool...]
# Reports missing tools; in "install" mode, attempts apt-get install.
nd_check_deps() {
  local mode="$1"; shift
  local deps=("$@")
  local missing=()
  local d
  msg "Checking required tools…"
  for d in "${deps[@]}"; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
  if (( ${#missing[@]} == 0 )); then
    ok "All required tools present."
    return 0
  fi
  warn "Missing: ${missing[*]}"
  if [[ "$mode" == "install" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      msg "Attempting apt-get install…"
      apt-get update -qq && apt-get install -y "${missing[@]}" || true
    fi
    local still_missing=()
    for d in "${missing[@]}"; do command -v "$d" >/dev/null 2>&1 || still_missing+=("$d"); done
    if (( ${#still_missing[@]} > 0 )); then
      err "Still missing after automatic install attempt: ${still_missing[*]} — install manually (e.g. 'sudo apt update && sudo apt install ${still_missing[*]}') and re-run."
      return 1
    fi
    ok "All required tools present."
  fi
}

# --- device detection ---------------------------------------------------------
nd_wifi_dev() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
}

# Onboard ethernet = an ethernet NIC named en*/eth* that is NOT a ZTE modem.
# The enx* name exclusion isn't sufficient on its own: these modems share a
# hard-coded default MAC, so a second one enumerates as eth0 — which would
# otherwise look exactly like an onboard NIC. Also drop anything nd_lte_ifaces
# flags as a 19d2 modem, whatever name it took.
nd_eth_dev() {
  local lte_set dev typ
  lte_set=" $(nd_lte_ifaces 2>/dev/null | paste -sd' ' -) "
  while IFS=: read -r dev typ; do
    [[ "$typ" == ethernet ]] || continue
    [[ "$dev" =~ ^(en|eth) && "$dev" != enx* ]] || continue
    [[ "$lte_set" == *" $dev "* ]] && continue
    printf '%s\n' "$dev"; return 0
  done < <(nmcli -t -f DEVICE,TYPE device 2>/dev/null)
}

# The LTE network interface: a USB 'enx*' (or eth1/wwan0) whose USB vendor is
# ZTE (19d2). Empty when the stick is not present.
# USB vendor ID for a network interface's underlying device. Plain
# USB-ethernet adapters expose idVendor directly under .../device/; composite
# (RNDIS-style) devices — like the ZTE MF79U — expose it one level up, on the
# parent USB device node, since .../device/ points at the USB *interface*
# (e.g. 1-2.2:1.0), not the USB *device* (1-2.2) that idVendor lives on.
# Walk up a few levels to find it either way.
# Resolve the sysfs directory that carries idVendor for a net iface's USB
# device — i.e. the USB *device* node (e.g. .../1-2.2), not the USB *interface*
# node (.../1-2.2:1.0). Walk up a few levels and print the canonical path.
# Empty + non-zero return when the iface isn't USB-backed.
nd_usb_device_path() {
  local dev_path="/sys/class/net/$1/device" up="" i
  for i in 0 1 2 3; do
    if [[ -f "$dev_path$up/idVendor" ]]; then
      # readlink -f (not cd/pwd): the '..' has to be resolved PHYSICALLY, past
      # the 'device' symlink, to reach the USB device node. A logical cd would
      # lexically cancel 'device/..' and land back on the net iface dir.
      readlink -f "$dev_path$up" 2>/dev/null && return 0
      return 1
    fi
    up="$up/.."
  done
  return 1
}

nd_usb_vendor_id() {
  local p
  p="$(nd_usb_device_path "$1")" || return 1
  cat "$p/idVendor" 2>/dev/null
}

# Every ZTE (vendor 19d2) network interface currently present, one per line.
# Detection is by USB vendor id, NOT by interface name: these modems ship with
# an identical hard-coded MAC (34:4b:50:00:00:00), so when two are attached the
# second cannot take an enx<MAC> name and the kernel falls back to eth0 (or
# similar). A name-based scan would miss it — and worse, that eth0 would then
# masquerade as an onboard NIC. So walk every interface and match on vendor.
nd_lte_ifaces() {
  local iface
  for iface in $(ls /sys/class/net 2>/dev/null); do
    [[ "$iface" == lo ]] && continue
    [[ "$(nd_usb_vendor_id "$iface" 2>/dev/null)" == "19d2" ]] && printf '%s\n' "$iface"
  done
}

# The (single) LTE network interface — first ZTE iface by name. Empty when the
# stick is not present. Unchanged behaviour; now expressed via nd_lte_ifaces.
nd_lte_iface() {
  nd_lte_ifaces | head -n1
  return 0
}

# Count of DISTINCT physical ZTE modems attached. A composite (RNDIS) modem can
# expose more than one net interface but is still ONE modem behind ONE
# 192.168.0.1, so we de-duplicate the interfaces on their parent USB device
# node rather than just counting interfaces. Prints an integer (0 if none).
# This is the signal the multi-modem safety guard keys off: all MF79U units
# default to the same 192.168.0.1 gateway, so two attached at once collide and
# cannot be told apart.
nd_lte_modem_count() {
  local iface p
  declare -A _nd_seen=()
  while read -r iface; do
    [[ -z "$iface" ]] && continue
    p="$(nd_usb_device_path "$iface" 2>/dev/null)"; [[ -z "$p" ]] && p="$iface"
    _nd_seen["$p"]=1
  done < <(nd_lte_ifaces)
  printf '%s\n' "${#_nd_seen[@]}"
}

# Interfaces we manage: the wifi device (hotspot/client) and the onboard
# ethernet (DHCP client/server). The LTE stick is intentionally excluded (see
# header note).
nd_managed_ifaces() {
  local lte_set dev typ
  lte_set=" $(nd_lte_ifaces 2>/dev/null | paste -sd' ' -) "
  while IFS=: read -r dev typ; do
    [[ -z "$dev" ]] && continue
    # never manage a ZTE modem, whatever iface name it took (enx*, eth0, …)
    [[ "$lte_set" == *" $dev "* ]] && continue
    case "$typ" in
      wifi)     printf '%s\n' "$dev" ;;
      ethernet) [[ "$dev" =~ ^(en|eth) && "$dev" != enx* ]] && printf '%s\n' "$dev" ;;
    esac
  done < <(nmcli -t -f DEVICE,TYPE device 2>/dev/null)
}

nd_nm_pid() { pgrep -x NetworkManager 2>/dev/null | head -1; }

# Is this process one of NetworkManager's own daemons? (must be spared)
#   args: <ppid> <args>
nd_is_nm_owned() {
  local ppid="$1" args="$2" nmpid
  nmpid="$(nd_nm_pid)"
  [[ -n "$nmpid" && "$ppid" == "$nmpid" ]] && return 0
  [[ "$args" == *"/var/lib/NetworkManager/"* ]] && return 0
  [[ "$args" == *"/run/NetworkManager/"* ]]     && return 0
  return 1
}

# Print foreign dnsmasq/hostapd bound to a managed iface, one per line:
#   pid|iface|comm|args
# Read-only — safe to call from the status command.
nd_foreign_dhcp() {
  local -a ifaces=()
  mapfile -t ifaces < <(nd_managed_ifaces)
  (( ${#ifaces[@]} )) || return 0

  local pid ppid comm args iface
  while read -r pid ppid comm args; do
    [[ -z "$pid" ]] && continue
    [[ "$comm" == "dnsmasq" || "$comm" == "hostapd" ]] || continue
    nd_is_nm_owned "$ppid" "$args" && continue
    for iface in "${ifaces[@]}"; do
      [[ -z "$iface" ]] && continue
      # Match the managed iface name as it appears in the daemon's args
      # (e.g. --interface=enP8p1s0). Managed names are distinctive, and the
      # managed-iface whitelist means usb0/other ifaces can never match.
      if [[ "$args" == *"$iface"* ]]; then
        printf '%s|%s|%s|%s\n' "$pid" "$iface" "$comm" "$args"
        break
      fi
    done
  done < <(ps -eo pid=,ppid=,comm=,args= 2>/dev/null)
}

# Kill whatever nd_foreign_dhcp reports.
nd_reap_foreign() {
  local pid iface comm args
  while IFS='|' read -r pid iface comm args; do
    [[ -z "$pid" ]] && continue
    nd_log "cleanup: killing foreign $comm pid=$pid on $iface: $args"
    kill "$pid" 2>/dev/null || true
  done < <(nd_foreign_dhcp)
  return 0
}

# ---------------------------------------------------------------------------
# LTE-only egress firewall (tagged chain ND_FWD)
# ---------------------------------------------------------------------------
# LAN clients (our NM 'shared' subnets on wifi/eth) may reach the internet ONLY
# via the LTE stick. Enforced with one tagged chain so Docker/BlueOS rules are
# never touched: ND_FWD only ever matches our own 10.42.x.0/24 sources; all
# other traffic falls through (implicit RETURN).

ND_CHAIN="ND_FWD"
ND_IPT="${ND_IPT:-iptables}"   # overridable for testing

# /24 subnets we are currently SERVING (NM 'shared' assigns 10.42.x.1/24).
# Only our managed ifaces are considered, and only when they hold a 10.42.x addr.
nd_shared_subnets() {
  local dev addr net
  while read -r dev; do
    [[ -z "$dev" ]] && continue
    while read -r addr; do
      # addr like 10.42.0.1/24  -> network 10.42.0.0/24
      [[ "$addr" == 10.42.*/24 ]] || continue
      net="${addr%/*}"; net="${net%.*}.0/24"
      printf '%s\n' "$net"
    done < <(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}')
  done < <(nd_managed_ifaces)
}

# (Re)build the ND_FWD chain for the current LTE iface + served subnets.
# Idempotent: safe to call every reconcile cycle.
nd_fw_apply() {
  command -v "$ND_IPT" >/dev/null 2>&1 || { nd_log "fw: $ND_IPT not found — skipping"; return 0; }
  local lte subnets s d
  lte="$(nd_lte_iface)"
  mapfile -t subnets < <(nd_shared_subnets)

  # Ensure the chain exists and is empty, then (re)assert the jump at FORWARD #1.
  if ! "$ND_IPT" -t filter -nL "$ND_CHAIN" >/dev/null 2>&1; then
    "$ND_IPT" -t filter -N "$ND_CHAIN" 2>/dev/null || { nd_log "fw: cannot create $ND_CHAIN (need root?)"; return 0; }
  fi
  "$ND_IPT" -t filter -F "$ND_CHAIN" 2>/dev/null || true
  # Remove any existing jumps to us, then put exactly one at the very top so we
  # are evaluated before NM's per-interface ACCEPTs and Docker's rules.
  while "$ND_IPT" -t filter -C FORWARD -j "$ND_CHAIN" 2>/dev/null; do
    "$ND_IPT" -t filter -D FORWARD -j "$ND_CHAIN" 2>/dev/null || break
  done
  "$ND_IPT" -t filter -I FORWARD 1 -j "$ND_CHAIN" 2>/dev/null

  # No served LAN subnets -> nothing to police; empty chain just RETURNs.
  (( ${#subnets[@]} )) || { nd_log "fw: no served subnets; ND_FWD empty (lte='${lte:-none}')"; return 0; }

  for s in "${subnets[@]}"; do
    # Allow egress to the internet ONLY via the LTE iface (when present).
    [[ -n "$lte" ]] && "$ND_IPT" -t filter -A "$ND_CHAIN" -s "$s" -o "$lte" -j ACCEPT 2>/dev/null
    # Allow inter-LAN traffic between our own served subnets.
    for d in "${subnets[@]}"; do
      "$ND_IPT" -t filter -A "$ND_CHAIN" -s "$s" -d "$d" -j ACCEPT 2>/dev/null
    done
    # Everything else from this LAN is dropped: no leak via WiFi-client /
    # Ethernet-upstream, and (no LTE iface) => all LAN internet is cut. Strict.
    "$ND_IPT" -t filter -A "$ND_CHAIN" -s "$s" -j DROP 2>/dev/null
  done
  nd_log "fw: LTE-only applied (lte='${lte:-none}', subnets='${subnets[*]}')"
  return 0
}

# Remove our chain + jump entirely (service stop / uninstall). Never touches
# any other chain.
nd_fw_clear() {
  command -v "$ND_IPT" >/dev/null 2>&1 || return 0
  while "$ND_IPT" -t filter -C FORWARD -j "$ND_CHAIN" 2>/dev/null; do
    "$ND_IPT" -t filter -D FORWARD -j "$ND_CHAIN" 2>/dev/null || break
  done
  "$ND_IPT" -t filter -F "$ND_CHAIN" 2>/dev/null || true
  "$ND_IPT" -t filter -X "$ND_CHAIN" 2>/dev/null || true
  nd_log "fw: LTE-only chain cleared"
  return 0
}
