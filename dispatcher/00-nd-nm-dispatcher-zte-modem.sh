#!/bin/bash
# This file goes to /etc/NetworkManager/dispatcher.d/
# Purpose: Handle ZTE modem interface events, prefer LTE routes, and run modem workflow.
#
# Deliberately self-contained (does not source lib/nd-common.sh): this runs
# synchronously inside NetworkManager's dispatcher event path, so a
# missing/broken shared-lib file must never be able to break interface-up
# handling.

set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

iface="${1:-}"
state="${2:-}"

LOGTAG="nd-nm-dispatcher"
SCRIPT_NAME="$(basename "$0")"

# --- helpers -----------------------------------------------------------------

log() {
  # Uniform, greppable log format
  # Usage: log "message"
  /usr/bin/logger -t "$LOGTAG" "$SCRIPT_NAME: $*"
}

die() {
  # Log an error and exit non-zero (keeps behavior obvious)
  log "ERROR: $*"
  exit 1
}

cleanup() {
  # Hook for future use; currently just records abnormal exits.
  # shellcheck disable=SC2181
  if [[ $? -ne 0 ]]; then
    log "ABORTED: an error occurred (trap caught)."
  fi
}
trap cleanup EXIT

# --- start -------------------------------------------------------------------

log "Dispatcher triggered: interface=${iface:-<empty>}, status=${state:-<empty>}"

# Only act on ZTE interface when it goes up
# NOTE: Do not alter overall logic — keep exact condition semantics.
if [[ "$iface" =~ ^(enx|eth1|usb0) ]] && [[ "$state" =~ ^(pre-up|up)$ ]]; then
  log "[$iface] state: $state - entering handler"

  # Lock to avoid concurrent runs
  if ! command -v flock >/dev/null 2>&1; then
    die "flock not found in PATH"
  fi
  exec 9>/run/zte_dispatcher.lock
  if ! flock -n 9; then
    log "[$iface] state: $state - another instance holding lock, exiting"
    exit 0
  fi

  log "[$iface] state: $state - lock acquired"

  script="/opt/nd-uplink/modem/nd-zte-modem.sh"
  if [[ ! -r "$script" ]]; then
    die "Script not readable: $script"
  fi

  # Give NM a moment to settle interfaces/routes
  sleep 2

  ###
  ### Routing policy: LTE (ZTE) is the PREFERRED uplink.
  ### LTE gets the lowest metric; Wi‑Fi is the fallback (higher metric).
  ###
  ZTE_IF="$iface"
  # Connection bound to the active ZTE interface
  ZTE_CON=$(nmcli -t -f NAME,DEVICE con show | grep ":$ZTE_IF" | cut -d: -f1 || true)

  # Detect active Wi‑Fi interface and connection
  WIFI_IF=$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1; exit}' || true)
  WIFI_CON=""
  if [[ -n "$WIFI_IF" ]]; then
    WIFI_CON=$(nmcli -t -f NAME,DEVICE con show | grep ":$WIFI_IF" | cut -d: -f1 || true)
  fi

  if [[ -n "$WIFI_CON" ]]; then
    # dns-priority: deprioritized (higher number = tried later) — WiFi is a
    # fallback uplink, so its DNS server should never be preferred over a
    # better connection's, even though it's still available if WiFi is the
    # only interface up.
    nmcli con modify "$WIFI_CON" ipv4.route-metric 600 ipv4.dns-priority 600 >/dev/null 2>&1 \
      || log "WARN: failed to set metric/dns-priority on Wi‑Fi connection: $WIFI_CON"
    # con modify only updates the saved profile; reapply pushes it onto the
    # already-active device so an existing route/DNS registration doesn't
    # keep using the old values until the next full reconnect.
    nmcli device reapply "$WIFI_IF" >/dev/null 2>&1 || log "WARN: failed to reapply Wi‑Fi device: $WIFI_IF"
  else
    log "INFO: No Wi‑Fi connection found to prioritize"
  fi

  if [[ -n "$ZTE_CON" ]]; then
    nmcli con modify "$ZTE_CON" ipv4.route-metric 50 >/dev/null 2>&1 || log "WARN: failed to set IPv4 metric on ZTE connection: $ZTE_CON"
    nmcli con modify "$ZTE_CON" ipv6.route-metric 50 >/dev/null 2>&1 || log "WARN: failed to set IPv6 metric on ZTE connection: $ZTE_CON"
    # Deprioritize this connection's DNS too (same reasoning as WiFi above):
    # while the SIM is locked, this interface only reaches the modem's own
    # local/fake resolver, which must never win over a real connection's DNS
    # just because it's registered as a default-route scope. Once the modem
    # is genuinely providing data, its route-metric (50) still wins for the
    # actual data path regardless of DNS priority — DNS queries go to
    # whichever resolver is reachable, independent of which interface
    # carries the return internet traffic.
    nmcli con modify "$ZTE_CON" ipv4.dns-priority 600 >/dev/null 2>&1 \
      || log "WARN: failed to set dns-priority on ZTE connection: $ZTE_CON"
    nmcli device reapply "$ZTE_IF" >/dev/null 2>&1 || log "WARN: failed to reapply ZTE device: $ZTE_IF"
  else
    log "INFO: No ZTE connection found for interface: $ZTE_IF"
  fi

  log "Routing metrics applied (LTE preferred over Wi‑Fi). Starting modem handler…"

  # Only run the modem workflow when it's meaningful
  if [[ "$state" != "dhcp4-change" ]]; then
    # Intentionally keep sudo + invocation style to avoid behavior change.
    /usr/bin/sudo -u root -H /bin/bash -lc "/bin/bash '$script' 2>&1" | /usr/bin/logger -t nd-zte &
    log "Modem handler started in background (PID $!)"
  else
    log "Skipping modem workflow on state=$state"
  fi

  log "[$iface] state: $state - handler done"
else
  # Improve observability for ignored events without being noisy
  # Only log if the dispatcher is noisy (optional level)
  # Examples seen: interface=none/empty with hostname/connectivity-change
  log "Ignoring event: interface=${iface:-<empty>} state=${state:-<empty>}"
fi
