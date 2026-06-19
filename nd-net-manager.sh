#!/usr/bin/env bash
#
# nd-net-manager — single failover daemon for the Jetson.
# Installed to: /opt/nd-net/nd-net-manager.sh   (run by nd-net-manager.service)
#
# Responsibilities (NetworkManager is the engine; this only drives what NM
# cannot do on its own):
#   1. WiFi: join a known network when in range, otherwise run the onboard
#      hotspot (nd-hotspot). Keep probing so we switch back to a known SSID
#      when it reappears.
#   2. Ethernet: SERVE the LAN by default (nd-eth-dhcp-server, DHCP+NAT). On a
#      link-up edge, probe once for an upstream DHCP server and only then step
#      back to DHCP-client mode (Wired connection 1).
#   3. LTE-only egress: keep the tagged ND_FWD firewall chain in sync so LAN
#      clients reach the internet ONLY via the LTE stick.
#   4. Hygiene: reap foreign dnsmasq/hostapd that land on our interfaces.
#
# Idempotent and safe to restart at any time. Logs via: journalctl -t nd-net
#
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

LOGTAG="nd-net"

# --- tunables (overridable via /opt/nd-net/.env) -----------------------------
HOTSPOT_CON="nd-hotspot"            # NM connection id of the onboard AP
ETH_CLIENT_CON="Wired connection 1" # NM DHCP-client profile (onboard ethernet)
ETH_SERVER_CON="nd-eth-dhcp-server" # NM DHCP-server (shared) — the default
POLL_SECS=15                        # main loop cadence
PROBE_SECS=90                       # min seconds between wifi probes (when enabled)
WIFI_PROBE=0                        # 0=never probe while hotspot is up (clients
                                    #   on the AP stay connected); 1=periodically
                                    #   scan and switch to a known network if seen
CLEANUP_FOREIGN_DHCP=1              # reap foreign dnsmasq/hostapd on our ifaces
LTE_ONLY=1                          # enforce LAN-clients-egress-via-LTE-only
ENV_FILE="${ND_NET_ENV_FILE:-/opt/nd-net/.env}"
# shellcheck disable=SC1090
[[ -r "$ENV_FILE" ]] && . "$ENV_FILE"

# Shared helpers (foreign-daemon reaper). Prefer a sibling copy (running from
# the repo), fall back to the installed location.
ND_LOGTAG="$LOGTAG"
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/nd-net-lib.sh"
[[ -r "$_LIB" ]] || _LIB="/opt/nd-net/nd-net-lib.sh"
# shellcheck source=/dev/null
if [[ -r "$_LIB" ]]; then . "$_LIB"; else
  /usr/bin/logger -t "$LOGTAG" "WARN: nd-net-lib.sh not found ($_LIB) — hygiene cleanup disabled"
  CLEANUP_FOREIGN_DHCP=0
fi

log() { /usr/bin/logger -t "$LOGTAG" -- "$*"; }

# --- one-shot subcommands (no daemon lock) -----------------------------------
# These run a single action and exit; safe to call while the daemon is running
# (no lock contention). Used by the installer and the systemd ExecStop.
case "${1:-}" in
  reap)     [[ "$CLEANUP_FOREIGN_DHCP" == "1" ]] && nd_reap_foreign; exit 0 ;;
  fw-apply) [[ "$LTE_ONLY" == "1" ]] && nd_fw_apply; exit 0 ;;
  fw-clear) nd_fw_clear; exit 0 ;;
esac

# --- single-instance lock ----------------------------------------------------
exec 9>/run/nd-net-manager.lock
if ! flock -n 9; then
  log "another instance is already running — exiting"
  exit 0
fi

# --- helpers -----------------------------------------------------------------

wifi_dev() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null \
    | awk -F: '$2=="wifi"{print $1; exit}'
}

# SSIDs of all saved wifi *client* profiles (mode != ap), excluding the hotspot.
# Printed one per line. Recomputed each cycle so `nmcli` edits are picked up.
known_ssids() {
  local name type mode ssid
  while IFS=: read -r name type; do
    [[ "$type" == "802-11-wireless" ]] || continue
    [[ "$name" == "$HOTSPOT_CON" ]] && continue
    mode=$(nmcli -g 802-11-wireless.mode con show "$name" 2>/dev/null || true)
    [[ "$mode" == "ap" ]] && continue
    ssid=$(nmcli -g 802-11-wireless.ssid con show "$name" 2>/dev/null || true)
    [[ -n "$ssid" ]] && printf '%s\n' "$ssid"
  done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null)
}

# Connection id of the saved client profile for a given SSID (first match).
con_for_ssid() {
  local want="$1" name type ssid
  while IFS=: read -r name type; do
    [[ "$type" == "802-11-wireless" ]] || continue
    [[ "$name" == "$HOTSPOT_CON" ]] && continue
    ssid=$(nmcli -g 802-11-wireless.ssid con show "$name" 2>/dev/null || true)
    if [[ "$ssid" == "$want" ]]; then printf '%s\n' "$name"; return 0; fi
  done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null)
  return 1
}

# Active wifi connection id on a device ("" if none).
active_wifi_con() {
  local dev="$1"
  nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null \
    | awk -F: -v d="$dev" '$3=="802-11-wireless" && $2==d {print $1; exit}'
}

con_is_active() {
  nmcli -t -f NAME con show --active 2>/dev/null | grep -Fxq -- "$1"
}

# SSIDs currently visible to the radio, one per line.
visible_ssids() {
  local dev="$1"
  nmcli -t -f SSID dev wifi list ifname "$dev" 2>/dev/null \
    | sed '/^$/d' | sort -u
}

# Of the known SSIDs, return the first one that is currently visible ("" none).
first_known_visible() {
  local dev="$1" vis k
  vis="$(visible_ssids "$dev")"
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if grep -Fxq -- "$k" <<<"$vis"; then printf '%s\n' "$k"; return 0; fi
  done < <(known_ssids)
  return 1
}

bring_up()   { nmcli con up "$1" >/dev/null 2>&1; }
bring_down() { nmcli con down "$1" >/dev/null 2>&1 || true; }

# --- WiFi state machine ------------------------------------------------------

manage_wifi() {
  local dev now_active
  dev="$(wifi_dev)"
  if [[ -z "$dev" ]]; then
    # Log only on transition into the no-device state, not every poll cycle —
    # on hardware with no wifi radio this would otherwise spam the journal.
    if [[ "$WIFI_DEV_PRESENT" != "0" ]]; then
      log "wifi: no wifi device present — wifi management idle"
      WIFI_DEV_PRESENT=0
    fi
    return
  fi
  WIFI_DEV_PRESENT=1

  # Radio off? nothing to do.
  if [[ "$(nmcli -t -f WIFI radio 2>/dev/null)" != "enabled" ]]; then
    log "wifi: radio disabled — skipping"
    return
  fi

  now_active="$(active_wifi_con "$dev")"

  # Case A: already joined to a known client network -> ensure hotspot is down.
  if [[ -n "$now_active" && "$now_active" != "$HOTSPOT_CON" ]]; then
    if con_is_active "$HOTSPOT_CON"; then
      log "wifi: client '$now_active' active — taking hotspot down"
      bring_down "$HOTSPOT_CON"
    fi
    return
  fi

  # Case B: hotspot is up. Periodically scan for known SSIDs, but DO NOT take the
  # hotspot down to do it — clients (e.g. a chat/SSH session riding the AP) must
  # stay connected. We only tear the hotspot down when a known network is
  # actually in range, i.e. when there is a real reason to switch to it. (On a
  # single-radio adapter the in-AP rescan may return stale/empty results; that
  # is an acceptable trade-off vs. dropping every client every probe cycle.)
  if [[ "$now_active" == "$HOTSPOT_CON" ]]; then
    # Probing disabled: keep the hotspot up unconditionally so AP clients
    # (chat/SSH sessions) are never dropped. We never auto-switch back to a
    # known network while the hotspot is serving.
    if [[ "$WIFI_PROBE" != "1" ]]; then
      return
    fi
    if (( $(date +%s) - LAST_PROBE < PROBE_SECS )); then
      return
    fi
    LAST_PROBE=$(date +%s)
    log "wifi: hotspot up — scanning for known networks (hotspot stays up)"
    nmcli dev wifi rescan ifname "$dev" >/dev/null 2>&1 || true
    sleep 5
    local k con
    if k="$(first_known_visible "$dev")"; then
      con="$(con_for_ssid "$k")" || con=""
      if [[ -n "$con" ]]; then
        log "wifi: known network '$k' in range — taking hotspot down to switch"
        bring_down "$HOTSPOT_CON"
        if bring_up "$con"; then
          log "wifi: switched to known network '$k' ($con)"
          return
        fi
        log "wifi: failed to join '$k' — restoring hotspot"
        bring_up "$HOTSPOT_CON" || log "wifi: ERROR bringing hotspot back up"
      fi
    fi
    return
  fi

  # Case C: not a client, hotspot down. Try known networks, else start hotspot.
  nmcli dev wifi rescan ifname "$dev" >/dev/null 2>&1 || true
  sleep 5
  local k con
  if k="$(first_known_visible "$dev")"; then
    con="$(con_for_ssid "$k")" || con=""
    if [[ -n "$con" ]] && bring_up "$con"; then
      log "wifi: connected to known network '$k' ($con)"
      return
    fi
  fi
  log "wifi: no known network — starting hotspot '$HOTSPOT_CON'"
  bring_up "$HOTSPOT_CON" || log "wifi: ERROR starting hotspot"
}

# --- Ethernet: SERVE by default, detect upstream on link-up ------------------
# The Jetson is the gateway for downstream devices (DHCP server + NAT to LTE).
# We only step back to DHCP-client when another DHCP server is detected on the
# segment. Detection is done by an actual short client probe, triggered on a
# carrier down->up edge (link plugged in) — never on a periodic timer, so a
# stable served LAN is never disrupted.

eth_dev() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null \
    | awk -F: '$2=="ethernet" && $1 ~ /^(en|eth)/ && $1 !~ /^enx/ {print $1; exit}'
}

eth_has_ip() {  # true if the device currently holds any IPv4 address
  local dev="$1"
  [[ -n "$(ip -4 -o addr show dev "$dev" 2>/dev/null)" ]]
}

manage_eth() {
  local dev carrier active
  dev="$(eth_dev)"
  [[ -z "$dev" ]] && return

  carrier=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)

  # Carrier down: nothing to serve; remember state and bail.
  if [[ "$carrier" != "1" ]]; then
    LAST_ETH_CARRIER="$carrier"
    return
  fi

  # Link-up edge (incl. first cycle): probe ONCE for an upstream DHCP server.
  if [[ "$carrier" == "1" && "$LAST_ETH_CARRIER" != "1" ]]; then
    LAST_ETH_CARRIER="$carrier"
    log "eth: link up on $dev — probing for an upstream DHCP server"
    if bring_up "$ETH_CLIENT_CON"; then
      log "eth: upstream DHCP present — running as client on $dev"
    else
      log "eth: no upstream DHCP — serving DHCP + NAT to LTE on $dev"
      bring_up "$ETH_SERVER_CON" || log "eth: ERROR starting DHCP server"
    fi
    return
  fi
  LAST_ETH_CARRIER="$carrier"

  # Steady state. Keep serving unless an upstream client lease is established.
  active="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
            | awk -F: -v d="$dev" '$2==d {print $1; exit}')"
  if [[ "$active" == "$ETH_CLIENT_CON" ]]; then
    # In client mode: if the lease/upstream vanished, revert to serving.
    eth_has_ip "$dev" || { log "eth: client lease lost — reverting to DHCP server"; bring_up "$ETH_SERVER_CON" || true; }
  elif [[ "$active" != "$ETH_SERVER_CON" ]]; then
    # Neither of our profiles is up — assert the server default.
    log "eth: asserting DHCP-server default on $dev"
    bring_up "$ETH_SERVER_CON" || true
  fi
}

# --- LTE-only firewall sync --------------------------------------------------
manage_fw() {
  [[ "$LTE_ONLY" == "1" ]] || return 0
  nd_fw_apply
}

# --- shutdown ----------------------------------------------------------------
on_term() {
  log "nd-net-manager stopping — clearing LTE-only firewall"
  nd_fw_clear 2>/dev/null || true
  exit 0
}
trap on_term TERM INT

# --- main loop ---------------------------------------------------------------

LAST_PROBE=0
LAST_ETH_CARRIER=-1   # force a probe on the first cycle if link is already up
WIFI_DEV_PRESENT=-1   # -1 unknown; log no-wifi-device only on transition

log "nd-net-manager started (poll=${POLL_SECS}s probe=${PROBE_SECS}s cleanup=${CLEANUP_FOREIGN_DHCP} lte_only=${LTE_ONLY})"
while true; do
  [[ "$CLEANUP_FOREIGN_DHCP" == "1" ]] && { nd_reap_foreign || log "cleanup: cycle error (continuing)"; }
  manage_wifi || log "wifi: cycle error (continuing)"
  manage_eth  || log "eth: cycle error (continuing)"
  manage_fw   || log "fw: cycle error (continuing)"
  sleep "$POLL_SECS"
done
