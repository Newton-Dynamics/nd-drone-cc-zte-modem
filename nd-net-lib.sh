#!/usr/bin/env bash
#
# nd-net-lib.sh — shared helpers for nd-net-manager and nd-net-status.
# Installed to: /opt/nd-net/nd-net-lib.sh  (sourced, not executed directly)
#
# Purpose: detect (and optionally kill) DHCP/AP daemons that have landed on the
# interfaces THIS stack manages, while leaving everything else strictly alone —
# NetworkManager's own shared-mode dnsmasq, the BlueOS Cable Guy dnsmasq on
# usb0, Docker's NAT, interface IPs/routes, and NM connection profiles.
#
# Scope is deliberately narrow (user chose "coexist, minimal cleanup"):
# the ONLY thing we ever kill is a foreign dnsmasq/hostapd bound to a managed
# interface. We never flush iptables, never touch addresses/routes, never touch
# a non-managed interface (usb0 can therefore never match).
#
# shellcheck shell=bash

ND_LOGTAG="${ND_LOGTAG:-nd-net}"

nd_log() { /usr/bin/logger -t "$ND_LOGTAG" -- "$*"; }

# Interfaces we manage: the wifi device (hotspot/client) and the onboard
# ethernet (DHCP client/server). The LTE stick is a USB 'enx*' *client* — it
# runs no local DHCP/AP daemon — so it is intentionally NOT a managed iface.
nd_managed_ifaces() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '
    $2=="wifi" { print $1 }
    $2=="ethernet" && $1 ~ /^(en|eth)/ && $1 !~ /^enx/ { print $1 }'
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

# Kill whatever nd_foreign_dhcp reports. Returns the number of processes killed.
nd_reap_foreign() {
  local pid iface comm args n=0
  while IFS='|' read -r pid iface comm args; do
    [[ -z "$pid" ]] && continue
    nd_log "cleanup: killing foreign $comm pid=$pid on $iface: $args"
    kill "$pid" 2>/dev/null || true
    n=$((n + 1))
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

# The LTE network interface: a USB 'enx*' (or eth1/wwan0) whose USB vendor is
# ZTE (19d2). Empty when the stick is not present.
nd_lte_iface() {
  local iface vf
  for iface in eth1 wwan0 $(ls /sys/class/net 2>/dev/null | grep -E '^enx'); do
    vf="/sys/class/net/$iface/device/idVendor"
    if [[ -f "$vf" && "$(cat "$vf" 2>/dev/null)" == "19d2" ]]; then
      printf '%s\n' "$iface"; return 0
    fi
  done
  return 0
}

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
