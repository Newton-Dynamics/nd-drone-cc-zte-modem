#!/usr/bin/env bash
#
# nd-zte-modem.sh — identify the connected ZTE MF79U + inserted SIM by reading
# their IMEI/IMSI, look up credentials in the modem/SIM tables, log in, and
# unlock the SIM PIN.
# Installed to: /opt/nd-uplink/modem/nd-zte-modem.sh
#
# Modes:
#   (no args)            full identify-then-unlock flow. Triggered by
#                         dispatcher/00-nd-nm-dispatcher-zte-modem.sh on
#                         interface up, or manually via `nd-zte-activate` /
#                         the config web UI's "run unlock now" button.
#   --test-login <pass> [host]
#                         one login attempt against the given host (or the
#                         global default if omitted), no SIM/PIN touched.
#                         Used by nd-modem-webui right when a modem is added
#                         (before it has a modems.json entry of its own to
#                         look a per-modem host up from), so a typo is caught
#                         immediately instead of at the next real unlock.
#                         Prints one JSON line: {"ok":true,"imei":"..."} or
#                         {"ok":false,"error":"..."}.
#   --test-pin <pin>     resolves the modem the same way the real flow does
#                         (pre-auth IMEI probe -> modems.json, else the
#                         config UI's active modem), logs in, and attempts
#                         ENTER_PIN with the given PIN exactly once. Used by
#                         nd-modem-webui right when a SIM is added. Prints
#                         {"ok":true,"imsi":"...","modem_imei":"..."} or
#                         {"ok":false,"error":"..."}.
#
# Credentials come from two lookup tables managed by nd-modem-webui (never
# from a single fixed .env anymore — a drone may see several modems/SIMs
# over its life):
#   modems.json = [{"imei","password","label","zte_host"(optional)}, ...]
#   sims.json   = [{"imsi": "...", "pin": "...", "label": "..."}, ...]
#   active.json = {"modem_imei": "...", "sim_imsi": "..."}  (fallback/last-known)
#   config.json = {"zte_host": "..."}  (default modem WebUI IP; absent/null -> 192.168.0.1)
#
# A modem's own "zte_host" (set per-entry via the config UI) overrides the
# global default for that specific unit — most MF79U units answer on
# 192.168.0.1, but some units/firmware variants use a different subnet.
# Since identification has to happen before we know WHICH registered modem is
# plugged in, the live-IMEI probe tries every distinct host in play (the
# global default, then each registered modem's override) until one answers —
# see candidate_hosts()/probe_live_imei().
#
# Identification always happens BEFORE any login/PIN attempt — never guess
# across stored credentials against the live device: a wrong WebUI password
# can lock the admin account for 5 minutes, and a wrong SIM PIN 3x forces a
# PUK reset. An unknown modem or SIM is a hard stop, not a brute-force loop.
# --test-login/--test-pin make exactly ONE attempt each, same as the real
# flow — never a retry loop.
#
set -Eeuo pipefail

LOGTAG="nd-zte"
COOKIE_PATH=/tmp/zte_cookies.txt

# Resolve the directory of this script (handles symlinks, e.g. nd-zte-activate)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

MODEMS_DB="${ND_MODEMS_DB:-$SCRIPT_DIR/modems.json}"
SIMS_DB="${ND_SIMS_DB:-$SCRIPT_DIR/sims.json}"
ACTIVE_DB="${ND_ACTIVE_DB:-$SCRIPT_DIR/active.json}"
CONFIG_DB="${ND_CONFIG_DB:-$SCRIPT_DIR/config.json}"
DB_LOCK="${ND_DB_LOCK:-$SCRIPT_DIR/db.lock}"
MODEM_LOCK="${ND_MODEM_LOCK:-$SCRIPT_DIR/modem.lock}"

# Modem WebUI host — the DEFAULT/first candidate only. Most MF79U units
# answer on 192.168.0.1 when USB-tethered, but some units/firmware variants
# use a different subnet (e.g. 192.168.144.10), set per-modem in modems.json
# (see candidate_hosts()) or globally in config.json's "zte_host" field (same
# file/lock discipline as modems.json), managed through the config UI.
# ND_ZTE_HOST env var is a lower-priority override for the global default
# (e.g. one-off manual testing); config.json wins when both are set. probe_
# live_imei() mutates $ZTE_HOST once it finds which host actually answers —
# every function below always uses "whichever host we're currently talking
# to", not this initial value. The login endpoint never took a username.
ZTE_HOST="192.168.0.1"
[[ -n "${ND_ZTE_HOST:-}" ]] && ZTE_HOST="$ND_ZTE_HOST"
_cfg_zte_host="$([[ -r "$CONFIG_DB" ]] && jq -r '.zte_host // empty' "$CONFIG_DB" 2>/dev/null || true)"
[[ -n "$_cfg_zte_host" ]] && ZTE_HOST="$_cfg_zte_host"
unset _cfg_zte_host

# Best-effort shared helpers — used only for the multi-modem advisory below.
# Sourcing must never be fatal: this script has to keep working (unlock the one
# modem that IS plugged in) even if the lib is missing/unreadable.
_ND_LIB="${ND_COMMON_LIB:-$SCRIPT_DIR/../lib/nd-common.sh}"
# shellcheck source=/dev/null
[[ -r "$_ND_LIB" ]] && . "$_ND_LIB" 2>/dev/null || true

log() { logger -t "$LOGTAG" -- "$*"; }

# Serialize ALL talk to the modem (default flow, --test-login, --test-pin)
# across concurrent invocations — e.g. the dispatcher firing on interface-up
# at the same moment someone clicks "test login" in the web UI. Held for the
# whole process lifetime; blocking (not -n) since these should queue, not
# skip, unlike the dispatcher's own single-instance guard.
exec 7>"$MODEM_LOCK"
flock 7

# Bare unauthenticated single-field read against a given host (default:
# whichever host we're currently resolved to). Bounded so an unreachable
# modem fails fast instead of hanging on curl's default TCP connect timeout
# (~2 minutes).
fetch_unauth() {
  local host="${2:-$ZTE_HOST}"
  curl -s --connect-timeout 2 --max-time 3 \
    --header "Referer: http://$host/index.html" \
    "$host/goform/goform_get_cmd_process?cmd=$1"
}

# Every distinct WebUI host currently in play: the resolved default first
# (fast path — matches the common case), then each registered modem's own
# "zte_host" override, deduped. We can't know in advance which registered
# modem (if any) is physically plugged in, so identification has to be
# willing to check every host any of them might be answering on.
candidate_hosts() {
  printf '%s\n' "$ZTE_HOST"
  [[ -r "$MODEMS_DB" ]] && jq -r '.[].zte_host // empty' "$MODEMS_DB" 2>/dev/null
}

# Read the live IMEI, trying every candidate host in turn (2 attempts each,
# 1s apart) — right after the interface comes up (or the modem is freshly
# plugged in) its web server can take a few seconds to start answering, so a
# single attempt would often report "unreadable" moments before the modem
# was ready to respond. On success, sets $ZTE_HOST to the host that actually
# answered plus $PROBED_IMEI (never echoed — must be CALLED DIRECTLY, never
# via $(...): a command substitution forks a subshell, and the $ZTE_HOST
# mutation would be silently lost the moment it returned, leaving every
# later call talking to the wrong host). Callers wrapping this in an
# external timeout (webui's --test-pin) must leave enough headroom above
# (attempts x hosts) for login + telemetry + ENTER_PIN afterward.
probe_live_imei() {
  local host imei attempt seen=" "
  PROBED_IMEI=""
  while IFS= read -r host; do
    [[ -z "$host" || "$seen" == *" $host "* ]] && continue
    seen="$seen$host "
    for attempt in 1 2; do
      imei=$(fetch_unauth imei "$host" | grep -oP '(?<="imei":")[^"]+' || true)
      if [[ -n "$imei" ]]; then
        ZTE_HOST="$host"
        PROBED_IMEI="$imei"
        return 0
      fi
      (( attempt < 2 )) && sleep 1
    done
  done < <(candidate_hosts)
  return 0
}

# Query the modem's goform API for full status/telemetry, merging every
# response into one JSON object. Each distinct field set is fetched once.
# Headers are (re)built fresh from $ZTE_HOST on every call, never cached at
# script start — probe_live_imei() may have since switched hosts.
collect_modem_data() {
  local epoch_ms
  epoch_ms=$(date +%s%3N)
  local -a responses=()
  local -a UAHDRS=(
    -H "Origin: http://$ZTE_HOST"
    -H "Referer: http://$ZTE_HOST/index.html"
    -H "X-Requested-With: XMLHttpRequest"
    -H "Accept: application/json, text/javascript, */*; q=0.01"
    -H "Accept-Language: de-DE,de;q=0.9,en;q=0.8"
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
    -H "Connection: keep-alive"
  )

  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=privacy_read_flag&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status,signalbar,network_type,network_provider,battery_charg_type,external_charging_flag,mode_main_state,battery_temp,SSID1,ppp_status,EX_SSID1,sta_ip_status,EX_wifi_profile,m_ssid_enable,RadioOff,wifi_onoff_state,wifi_chip1_ssid1_ssid,wifi_chip2_ssid1_ssid,wifi_chip1_ssid1_access_sta_num,wifi_chip2_ssid1_access_sta_num,simcard_roam,lan_ipaddr,station_mac,wifi_access_sta_num,battery_charging,battery_vol_percent,battery_pers,spn_name_data,spn_b1_flag,spn_b2_flag,realtime_tx_bytes,realtime_rx_bytes,realtime_time,realtime_tx_thrpt,realtime_rx_thrpt,monthly_rx_bytes,monthly_tx_bytes,monthly_time,date_month,data_volume_limit_switch,data_volume_limit_size,data_volume_alert_percent,data_volume_limit_unit,roam_setting_option,upg_roam_switch,ssid,wifi_enable,wifi_5g_enable,check_web_conflict,dial_mode,ppp_dial_conn_fail_counter,wan_lte_ca,privacy_read_flag,is_night_mode,pppoe_status,dhcp_wan_status,static_wan_status,vpn_conn_status,wan_connect_status,wifi_chip1_ssid2_access_sta_num,wifi_chip2_ssid2_access_sta_num&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryWiFiModuleSwitch&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryAccessPointInfo&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=OOM_TEMP_PRO&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,puknumber,pinnumber,opms_wan_mode,psw_fail_num_str,login_lock_time,SleepStatusForSingleChipCpe&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=Language,cr_version,wa_inner_version&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=wifi_onoff_state,guest_switch,wifi_chip1_ssid2_max_access_num,RadioOff,SSID1,MAX_Access_num,m_SSID,m_MAX_Access_num,m_SSID2,wifi_coverage,wifi_chip2_ssid2_max_access_num,wifi_chip1_ssid1_wifi_coverage,apn_interface_version,m_ssid_enable,imei,network_type,rssi,rscp,lte_rsrp,imsi,sim_imsi,cr_version,wa_version,hardware_version,web_version,wa_inner_version,wifi_chip1_ssid1_max_access_num,wifi_chip1_ssid1_ssid,wifi_chip1_ssid1_auth_mode,wifi_chip1_ssid1_password_encode,wifi_chip2_ssid1_ssid,wifi_chip2_ssid1_auth_mode,m_HideSSID,wifi_chip2_ssid1_password_encode,wifi_chip2_ssid1_max_access_num,lan_ipaddr,mac_address,msisdn,LocalDomain,wan_ipaddr,static_wan_ipaddr,ipv6_wan_ipaddr,ipv6_pdp_type,ipv6_pdp_type_ui,pdp_type,pdp_type_ui,opms_wan_mode,opms_wan_auto_mode,ppp_status,Z5g_snr,Z5g_rsrp,wan_lte_ca,lte_ca_pcell_band,lte_ca_pcell_bandwidth,lte_ca_scell_band,lte_ca_scell_bandwidth,lte_ca_pcell_arfcn,lte_ca_scell_arfcn,lte_multi_ca_scell_info,wan_active_band,wifi_chip1_ssid2_ssid,wifi_chip2_ssid2_ssid,wifi_chip1_ssid1_switch_onoff,wifi_chip2_ssid1_switch_onoff,wifi_chip1_ssid2_switch_onoff,wifi_chip2_ssid2_switch_onoff,Z5g_SINR,station_ip_addr&_=$epoch_ms" "${UAHDRS[@]}")")
  responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=imei&_=$epoch_ms" "${UAHDRS[@]}")")

  printf '%s\n' "${responses[@]}" | jq -s 'reduce .[] as $item ({}; . * $item)'
}

# --- lookup-table helpers -----------------------------------------------------

modem_password_for_imei() {
  jq -r --arg imei "$1" '[.[] | select(.imei == $imei)][0].password // empty' "$MODEMS_DB"
}
modem_host_for_imei() {
  jq -r --arg imei "$1" '[.[] | select(.imei == $imei)][0].zte_host // empty' "$MODEMS_DB"
}
sim_pin_for_imsi() {
  jq -r --arg imsi "$1" '[.[] | select(.imsi == $imsi)][0].pin // empty' "$SIMS_DB"
}
active_modem_imei() {
  [[ -r "$ACTIVE_DB" ]] && jq -r '.modem_imei // empty' "$ACTIVE_DB" 2>/dev/null || true
}
active_sim_imsi() {
  [[ -r "$ACTIVE_DB" ]] && jq -r '.sim_imsi // empty' "$ACTIVE_DB" 2>/dev/null || true
}
write_active() {
  local modem_imei="$1" sim_imsi="$2"
  exec 8>"$DB_LOCK"
  flock 8
  jq -n --arg m "$modem_imei" --arg s "$sim_imsi" '{modem_imei: $m, sim_imsi: $s}' > "${ACTIVE_DB}.tmp"
  mv -f "${ACTIVE_DB}.tmp" "$ACTIVE_DB"
  flock -u 8
}

# --- resolve the connected modem, without ever guessing ----------------------
# Sets RESOLVED_IMEI / RESOLVED_PASSWORD on success; returns 1 on failure.
resolve_modem() {
  local live_imei="$1" password
  if [[ -n "$live_imei" ]]; then
    password=$(modem_password_for_imei "$live_imei")
    if [[ -n "$password" ]]; then
      RESOLVED_IMEI="$live_imei"; RESOLVED_PASSWORD="$password"
      log "Identified modem by IMEI $live_imei (pre-auth probe)."
      return 0
    fi
    log "Unknown modem (IMEI $live_imei) — not registered. Add it via the nd-uplink config UI (port 7077)."
    return 1
  fi

  local fallback_imei fallback_host
  fallback_imei="$(active_modem_imei)"
  if [[ -n "$fallback_imei" ]]; then
    password=$(modem_password_for_imei "$fallback_imei")
    if [[ -n "$password" ]]; then
      RESOLVED_IMEI="$fallback_imei"; RESOLVED_PASSWORD="$password"
      # No live probe means candidate_hosts() never ran, so $ZTE_HOST is
      # still just the global default — apply this modem's own override, if
      # it has one, since that's the host we're about to log into blind.
      fallback_host="$(modem_host_for_imei "$fallback_imei")"
      [[ -n "$fallback_host" ]] && ZTE_HOST="$fallback_host"
      log "Pre-auth IMEI probe unavailable — using config-UI active modem (IMEI $fallback_imei) without pre-verification."
      return 0
    fi
  fi
  log "Cannot identify the connected modem (pre-auth probe unavailable) and no active modem is selected in the config UI — aborting."
  return 1
}

# Sets RESOLVED_IMSI / RESOLVED_PIN on success; returns 1 on failure.
resolve_sim() {
  local live_imsi="$1" pin
  if [[ -n "$live_imsi" ]]; then
    pin=$(sim_pin_for_imsi "$live_imsi")
    if [[ -n "$pin" ]]; then
      RESOLVED_IMSI="$live_imsi"; RESOLVED_PIN="$pin"
      log "Identified SIM by IMSI $live_imsi."
      return 0
    fi
    log "Unknown SIM (IMSI $live_imsi) — not registered. Add it via the nd-uplink config UI (port 7077). Skipping ENTER_PIN."
    return 1
  fi

  local fallback_imsi
  fallback_imsi="$(active_sim_imsi)"
  if [[ -n "$fallback_imsi" ]]; then
    pin=$(sim_pin_for_imsi "$fallback_imsi")
    if [[ -n "$pin" ]]; then
      RESOLVED_IMSI="$fallback_imsi"; RESOLVED_PIN="$pin"
      log "IMSI unavailable from telemetry — using config-UI active SIM (IMSI $fallback_imsi) without pre-verification."
      return 0
    fi
  fi
  log "Cannot identify the inserted SIM and no active SIM is selected in the config UI — aborting. Skipping ENTER_PIN."
  return 1
}

# --- reusable login (steps: LD -> hash -> POST LOGIN) ------------------------
# On failure sets LOGIN_ERROR and returns 1. Never retries — call once.
do_login() {
  local password="$1" ld_response ld prefix_hash login_hash login_response result
  LOGIN_ERROR=""
  ld_response=$(fetch_unauth LD)
  ld=$(echo "$ld_response" | grep -oP '(?<="LD":")[^"]+')
  if [[ -z "$ld" ]]; then
    LOGIN_ERROR="could not reach modem at $ZTE_HOST (no LD response)"
    return 1
  fi
  prefix_hash=$(echo -n "$password" | sha256sum | awk '{print toupper($1)}')
  login_hash=$(echo -n "${prefix_hash}${ld^^}" | sha256sum | awk '{print toupper($1)}')
  login_response=$(curl -s -c "$COOKIE_PATH" -b "$COOKIE_PATH" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Referer: http://$ZTE_HOST/index.html" \
    --header "Accept-Language: de-DE,de;q=0.9,en;q=0.8" \
    --header "Connection: keep-alive" \
    -d "isTest=false&goformId=LOGIN&password=$login_hash" \
    "$ZTE_HOST/goform/goform_set_cmd_process")
  result=$(echo "$login_response" | grep -oP '(?<="result":")[^"]+')
  case "$result" in
    "0") return 0 ;;
    "3") LOGIN_ERROR="bad password"; return 1 ;;
    "1") LOGIN_ERROR="account locked - wait 5 minutes"; return 1 ;;
    *)   LOGIN_ERROR="unexpected login result: $result"; return 1 ;;
  esac
}

# --- reusable AD computation (needs $modem_data from a post-login collect) --
# On failure sets AD_ERROR and returns 1. Sets $AD on success.
compute_ad() {
  local rd_response rd rd0 rd1 prefix_hash
  AD_ERROR=""
  rd_response=$(fetch_unauth RD)
  rd=$(echo "$rd_response" | grep -oP '(?<="RD":")[^"]+')
  if [[ -z "$rd" ]]; then
    AD_ERROR="could not fetch RD value"
    return 1
  fi
  rd0=$(jq -r '.wa_inner_version // empty' <<< "$modem_data")
  rd1=$(jq -r '.cr_version // empty' <<< "$modem_data")
  prefix_hash=$(echo -n "${rd0}${rd1}" | md5sum | awk '{print $1}')
  AD=$(echo -n "${prefix_hash}${rd}" | md5sum | awk '{print $1}')
  return 0
}

enter_pin() {
  curl -s -X POST "http://$ZTE_HOST/goform/goform_set_cmd_process" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Referer: http://$ZTE_HOST/index.html" \
    --header "Accept-Language: de-DE,de;q=0.9,en;q=0.8" \
    --header "Connection: keep-alive" \
    -c "$COOKIE_PATH" -b "$COOKIE_PATH" \
    -d "isTest=false&goformId=ENTER_PIN&PinNumber=$1&AD=$2"
}

# ==============================================================================
# --test-login <password> [host] — one login attempt, no SIM/PIN touched.
# [host]: used when adding a modem that isn't registered yet (so it has no
# modems.json entry to look a zte_host override up from) — the config UI
# passes whatever the operator entered/detected. Falls back to the global
# default if omitted, same as before this existed.
# ==============================================================================
if [[ "${1:-}" == "--test-login" ]]; then
  test_password="${2:?--test-login requires a password argument}"
  [[ -n "${3:-}" ]] && ZTE_HOST="$3"
  if do_login "$test_password"; then
    live_imei=$(fetch_unauth imei | grep -oP '(?<="imei":")[^"]+' || true)
    printf '{"ok":true,"imei":"%s"}\n' "$live_imei"
    exit 0
  fi
  printf '{"ok":false,"error":"%s"}\n' "$LOGIN_ERROR"
  exit 1
fi

# ==============================================================================
# --test-pin <pin> — resolve the modem the normal way, log in, ENTER_PIN once.
# ==============================================================================
if [[ "${1:-}" == "--test-pin" ]]; then
  test_pin="${2:?--test-pin requires a pin argument}"
  for f in "$MODEMS_DB" "$SIMS_DB"; do
    [[ -r "$f" ]] || { printf '{"ok":false,"error":"%s not found"}\n' "$f"; exit 1; }
  done
  probe_live_imei
  if ! resolve_modem "$PROBED_IMEI"; then
    printf '{"ok":false,"error":"no identifiable/active modem to test against"}\n'
    exit 1
  fi
  if ! do_login "$RESOLVED_PASSWORD"; then
    printf '{"ok":false,"error":"login failed: %s"}\n' "$LOGIN_ERROR"
    exit 1
  fi
  modem_data=$(collect_modem_data)
  if ! compute_ad; then
    printf '{"ok":false,"error":"%s"}\n' "$AD_ERROR"
    exit 1
  fi
  live_imsi=$(jq -r '.imsi // .sim_imsi // empty' <<< "$modem_data")
  enter_pin_response=$(enter_pin "$test_pin" "$AD")
  enter_pin_result=$(echo "$enter_pin_response" | grep -oP '(?<="result":")[^"]+')
  case "$enter_pin_result" in
    success)
      write_active "$RESOLVED_IMEI" "$live_imsi"
      printf '{"ok":true,"imsi":"%s","modem_imei":"%s"}\n' "$live_imsi" "$RESOLVED_IMEI"
      exit 0 ;;
    failure)
      printf '{"ok":false,"error":"SIM PIN rejected","imsi":"%s"}\n' "$live_imsi"
      exit 1 ;;
    *)
      printf '{"ok":false,"error":"unexpected ENTER_PIN result: %s","imsi":"%s"}\n' "$enter_pin_result" "$live_imsi"
      exit 1 ;;
  esac
fi

# ==============================================================================
# Default: full identify-then-unlock flow.
# ==============================================================================

log "Newton ZTE MODEM Unlocker — identify-then-unlock (host=$ZTE_HOST)"

for f in "$MODEMS_DB" "$SIMS_DB"; do
  if [[ ! -r "$f" ]]; then
    log "ERROR: $f not found — add modems/SIMs via the nd-uplink config UI first."
    exit 1
  fi
done

# Multi-modem advisory (non-fatal). Every call below targets a single fixed
# address (ZTE_HOST): all MF79U units default to that same 192.168.0.1, so two
# attached at once collide on 192.168.0.0/24 and which one answers is not
# deterministic. The flow still self-identifies by the live IMEI and re-checks
# it post-login before touching the SIM (so a wrong-PIN-to-wrong-SIM stays
# guarded), but routing/firewall/telemetry are unreliable in this state — make
# it loud in the log so the ambiguity is visible.
if declare -f nd_lte_modem_count >/dev/null 2>&1; then
  _nmodems="$(nd_lte_modem_count 2>/dev/null || echo 0)"
  if [[ "$_nmodems" =~ ^[0-9]+$ ]] && (( _nmodems > 1 )); then
    log "WARNING: $_nmodems ZTE modems attached — they share $ZTE_HOST and cannot be told apart. Proceeding by live-IMEI identification only; keep only one plugged in for reliable operation."
  fi
fi

# Step 1+2: identify the connected modem BEFORE attempting any login
probe_live_imei
if ! resolve_modem "$PROBED_IMEI"; then
  exit 1
fi

# Step 3: log in
if ! do_login "$RESOLVED_PASSWORD"; then
  log "Login failed for modem IMEI $RESOLVED_IMEI: $LOGIN_ERROR"
  exit 1
fi
log "Login successful (modem IMEI $RESOLVED_IMEI)."

modem_data=$(collect_modem_data)

# Defense in depth: confirm the modem we're now talking to is still the one
# we resolved (matters mainly on the active.json fallback path, where we
# didn't pre-verify the IMEI).
POST_LOGIN_IMEI=$(jq -r '.imei // empty' <<< "$modem_data")
if [[ -n "$POST_LOGIN_IMEI" && "$POST_LOGIN_IMEI" != "$RESOLVED_IMEI" ]]; then
  log "Post-login IMEI ($POST_LOGIN_IMEI) does not match the resolved modem ($RESOLVED_IMEI) — aborting before touching the SIM."
  exit 1
fi

# Step 4: RD/AD
if ! compute_ad; then
  log "$AD_ERROR"
  exit 1
fi

# Step 5: identify the inserted SIM BEFORE attempting ENTER_PIN
LIVE_IMSI=$(jq -r '.imsi // .sim_imsi // empty' <<< "$modem_data")
if ! resolve_sim "$LIVE_IMSI"; then
  exit 1
fi

ENTER_PIN_RESPONSE=$(enter_pin "$RESOLVED_PIN" "$AD")
ENTER_PIN_RESULT=$(echo "$ENTER_PIN_RESPONSE" | grep -oP '(?<="result":")[^"]+')
case "$ENTER_PIN_RESULT" in
  "success") log "SIM unlocked (IMSI $RESOLVED_IMSI)." ;;
  "failure") log "SIM unlocking failed — check the stored PIN in the config UI."; exit 1 ;;
  *)         log "Unexpected ENTER_PIN result: $ENTER_PIN_RESULT"; exit 1 ;;
esac

write_active "$RESOLVED_IMEI" "$RESOLVED_IMSI"

modem_data=$(collect_modem_data)
network_type=$(jq -r '.network_type // empty' <<< "$modem_data")
modem_main_state=$(jq -r '.modem_main_state // empty' <<< "$modem_data")
log "network_type:$network_type modem_main_state:$modem_main_state"

if command -v netbird >/dev/null 2>&1; then
  netbird up
else
  log "netbird not found — skipping netbird up"
fi
