#!/bin/bash
# triggered from /etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh
# for environment variables .. invoked via zte_http.sh
# this file goes to /opt/zte/zte_login.sh
#
# Multi-device unlock:
#   The modem login PASSWORD is a property of the STICK (keyed by IMEI); the SIM
#   PIN is a property of the CARD (keyed by IMSI). Both are looked up from the
#   device registry (nd-modem-registry, /opt/nd-net/devices.json) rather than
#   hard-coded in .env, so one Jetson can serve many sticks and SIM cards.
#
# Login bootstrap (we need the password to log in, but want the IMEI to choose
# the password):
#   1. Try to read the IMEI from the modem WITHOUT authenticating. If the modem
#      exposes it pre-auth, look the stick password up directly.
#   2. Otherwise fall back to the password of the stick that last logged in on
#      this host (cached by the registry). Try it once.
#   3. .env may still provide ZTE_PASSWORD / ZTE_PIN as a last-resort override
#      (back-compat / single-device bring-up); registry matches take priority.
#
# Env (from /opt/zte/.env via zte_http.sh):
#   ZTE_HOST              modem IP/host (required)
#   ZTE_PASSWORD          optional fallback login password (back-compat)
#   ZTE_PIN               optional fallback SIM PIN (back-compat)
#   ND_MODEM_REGISTRY     registry path (default /opt/nd-net/devices.json)
#   ZTE_REGISTRY_CMD      registry CLI (default: nd-modem-registry)

COOKIE_PATH=/tmp/zte_cookies.txt

# Tag for systemd logger
LOG_TAG="nd-nm-zte-modem"
logger -t "$LOG_TAG" "Newton ZTE MODEM Unlocker (multi-device)"

# Modem IP or hostname
ZTE_HOST="${ZTE_HOST:-localhost}"
MODEM_URL="http://$ZTE_HOST:8080"
logger -t "$LOG_TAG" "ZTE_HOST=$ZTE_HOST"

# Registry CLI (resolve a sibling/installed copy if not on PATH).
REGISTRY_CMD="${ZTE_REGISTRY_CMD:-nd-modem-registry}"
if ! command -v "$REGISTRY_CMD" >/dev/null 2>&1; then
  for cand in /opt/nd-net/nd-modem-registry.py \
              "$(dirname "${BASH_SOURCE[0]}")/nd-modem-registry.py"; do
    [[ -x "$cand" || -r "$cand" ]] && { REGISTRY_CMD="python3 $cand"; break; }
  done
fi
reg() { $REGISTRY_CMD "$@"; }

UAHDRS=(
  -H "Origin: $HOST"
  -H "Referer: http://$ZTE_HOST/index.html"
  -H "X-Requested-With: XMLHttpRequest"
  -H "Accept: application/json, text/javascript, */*; q=0.01"
  -H "Accept-Language: de-DE,de;q=0.9,en;q=0.8"
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8"
  -H "Connection: keep-alive"
)

epoch_ms=$(date +%s%3N)

collect_modem_data() {
    local responses=()
    responses=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=privacy_read_flag&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status,signalbar,network_type,network_provider,battery_charg_type,external_charging_flag,mode_main_state,battery_temp,SSID1,ppp_status,EX_SSID1,sta_ip_status,EX_wifi_profile,m_ssid_enable,RadioOff,wifi_onoff_state,wifi_chip1_ssid1_ssid,wifi_chip2_ssid1_ssid,wifi_chip1_ssid1_access_sta_num,wifi_chip2_ssid1_access_sta_num,simcard_roam,lan_ipaddr,station_mac,wifi_access_sta_num,battery_charging,battery_vol_percent,battery_pers,spn_name_data,spn_b1_flag,spn_b2_flag,realtime_tx_bytes,realtime_rx_bytes,realtime_time,realtime_tx_thrpt,realtime_rx_thrpt,monthly_rx_bytes,monthly_tx_bytes,monthly_time,date_month,data_volume_limit_switch,data_volume_limit_size,data_volume_alert_percent,data_volume_limit_unit,roam_setting_option,upg_roam_switch,ssid,wifi_enable,wifi_5g_enable,check_web_conflict,dial_mode,ppp_dial_conn_fail_counter,wan_lte_ca,privacy_read_flag,is_night_mode,pppoe_status,dhcp_wan_status,static_wan_status,vpn_conn_status,wan_connect_status,wifi_chip1_ssid2_access_sta_num,wifi_chip2_ssid2_access_sta_num&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryWiFiModuleSwitch&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryAccessPointInfo&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=OOM_TEMP_PRO&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,puknumber,pinnumber,opms_wan_mode,psw_fail_num_str,login_lock_time,SleepStatusForSingleChipCpe&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=Language,cr_version,wa_inner_version&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=imei,imsi,sim_imsi,msisdn,network_type,network_provider,cr_version,wa_inner_version,wa_version,hardware_version,sim_status,pin_status&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=imei&_=$epoch_ms" "${UAHDRS[@]}")")

    local merged
    merged=$(printf '%s\n' "${responses[@]}" | jq -s 'reduce .[] as $item ({}; . * $item)' 2>/dev/null)
    echo "$merged"
}

# Read a single cmd value without authenticating (best-effort; may be blank).
read_cmd_unauth() {
    local cmd="$1"
    curl -s --header "Referer: http://$ZTE_HOST/index.html" \
        "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=$cmd&_=$epoch_ms" \
        | grep -oP "(?<=\"$cmd\":\")[^\"]+"
}

# Attempt a login with a given plaintext password. Echoes the modem "result"
# code (0 ok, 3 bad pw, 1 locked, "" unknown) and returns 0 only on result==0.
do_login() {
    local password="$1"
    local ld_response ld prefix_hash login_hash login_response result

    ld_response=$(curl -s --header "Referer: http://$ZTE_HOST/index.html" \
        "$ZTE_HOST/goform/goform_get_cmd_process?cmd=LD")
    ld=$(echo "$ld_response" | grep -oP '(?<="LD":")[^"]+')
    if [ -z "$ld" ]; then
        logger -t "$LOG_TAG" "Failed to extract LD value."
        echo ""
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
    echo "$result"
    [ "$result" = "0" ]
}

# --- choose the login password ------------------------------------------------
# Build an ordered, de-duplicated list of candidate passwords to try. We cap the
# number of attempts to avoid tripping the modem's bad-password lockout.
declare -a CAND_PWS=()
add_cand() { local p="$1"; [ -n "$p" ] || return 0; for x in "${CAND_PWS[@]}"; do [ "$x" = "$p" ] && return 0; done; CAND_PWS+=("$p"); }

# (1) Pre-auth IMEI read → exact stick password.
PREAUTH_IMEI="$(read_cmd_unauth imei)"
if [ -n "$PREAUTH_IMEI" ]; then
    logger -t "$LOG_TAG" "Pre-auth IMEI=$PREAUTH_IMEI"
    if PW="$(reg lookup-stick --imei "$PREAUTH_IMEI")"; then
        logger -t "$LOG_TAG" "Found registry password for IMEI $PREAUTH_IMEI"
        add_cand "$PW"
    else
        logger -t "$LOG_TAG" "No registry stick entry for pre-auth IMEI $PREAUTH_IMEI"
    fi
else
    logger -t "$LOG_TAG" "IMEI not readable pre-auth — will use last-good / fallback password"
fi

# (2) Last stick that logged in on this host.
if LAST_IMEI="$(reg last-imei --host "$ZTE_HOST")"; then
    if [ -n "$LAST_IMEI" ]; then
        logger -t "$LOG_TAG" "Last-good stick for $ZTE_HOST: IMEI $LAST_IMEI"
        if PW="$(reg lookup-stick --imei "$LAST_IMEI")"; then add_cand "$PW"; fi
    fi
fi

# (3) .env fallback (back-compat / single-device bring-up).
add_cand "$ZTE_PASSWORD"

if [ "${#CAND_PWS[@]}" -eq 0 ]; then
    logger -t "$LOG_TAG" "No candidate login passwords (empty registry and no ZTE_PASSWORD). Aborting."
    exit 1
fi

# --- attempt login ------------------------------------------------------------
LOGIN_OK=0
USED_PW=""
for pw in "${CAND_PWS[@]}"; do
    logger -t "$LOG_TAG" "Attempting login…"
    RESULT="$(do_login "$pw")"
    case "$RESULT" in
        0) logger -t "$LOG_TAG" "Login successful."; LOGIN_OK=1; USED_PW="$pw"; break ;;
        3) logger -t "$LOG_TAG" "Login failed: bad password — trying next candidate if any." ;;
        1) logger -t "$LOG_TAG" "Login failed: account LOCKED (wait ~5 min). Aborting."; exit 1 ;;
        *) logger -t "$LOG_TAG" "Unexpected login result: '${RESULT:-<none>}'." ;;
    esac
done

if [ "$LOGIN_OK" != "1" ]; then
    logger -t "$LOG_TAG" "All candidate passwords exhausted — login failed."
    exit 1
fi

echo "### Login successful"
STOK=$(awk '/stok/ {print $NF}' "$COOKIE_PATH" 2>/dev/null)
logger -t "$LOG_TAG" "STOK=$STOK"

# --- gather post-login modem data --------------------------------------------
modem_data=$(collect_modem_data)
echo "$modem_data" | jq . 2>/dev/null || true

IMEI=$(jq -r '.imei // empty' <<< "$modem_data")
IMSI=$(jq -r '(.imsi // .sim_imsi) // empty' <<< "$modem_data")
MODEM_MAIN_STATE=$(jq -r '.modem_main_state // empty' <<< "$modem_data")
logger -t "$LOG_TAG" "IMEI=$IMEI IMSI=$IMSI MODEM_MAIN_STATE=$MODEM_MAIN_STATE"

# Record which stick logged in so the next bootstrap can fall back to it.
NOW_ISO=$(date -Is)
if [ -n "$IMEI" ]; then
    reg record-login --host "$ZTE_HOST" --imei "$IMEI" --ts "$NOW_ISO" || true
fi

# --- resolve the SIM PIN ------------------------------------------------------
# Prefer the registry (keyed by the inserted SIM's IMSI); fall back to .env.
ZTE_PIN_RESOLVED=""
if [ -n "$IMSI" ]; then
    if PIN="$(reg lookup-sim --imsi "$IMSI")"; then
        ZTE_PIN_RESOLVED="$PIN"
        logger -t "$LOG_TAG" "Found registry PIN for IMSI $IMSI"
        reg seen-sim --imsi "$IMSI" --ts "$NOW_ISO" || true
    else
        logger -t "$LOG_TAG" "No registry SIM entry for IMSI $IMSI"
    fi
fi
if [ -z "$ZTE_PIN_RESOLVED" ] && [ -n "$ZTE_PIN" ]; then
    logger -t "$LOG_TAG" "Using .env fallback PIN"
    ZTE_PIN_RESOLVED="$ZTE_PIN"
fi
if [ -z "$ZTE_PIN_RESOLVED" ]; then
    logger -t "$LOG_TAG" "No PIN available for IMSI '${IMSI:-?}' (registry miss, no .env fallback). Aborting before ENTER_PIN."
    exit 1
fi

# --- compute AD for ENTER_PIN -------------------------------------------------
logger -t "$LOG_TAG" "Fetching RD value from <$ZTE_HOST>"
RD_RESPONSE=$(curl -s --header "Referer: http://$ZTE_HOST/index.html" "$ZTE_HOST/goform/goform_get_cmd_process?cmd=RD")
RD=$(echo "$RD_RESPONSE" | grep -oP '(?<="RD":")[^"]+')
if [ -z "$RD" ]; then
    logger -t "$LOG_TAG" "Failed to extract RD value."
    exit 1
fi
RD0=$(jq -r '.wa_inner_version // empty' <<< "$modem_data")
RD1=$(jq -r '.cr_version // empty' <<< "$modem_data")
PREFIX_HASH=$(echo -n "${RD0}${RD1}" | md5sum | awk '{print $1}')
AD=$(echo -n "${PREFIX_HASH}${RD}" | md5sum | awk '{print $1}')
logger -t "$LOG_TAG" "RD:$RD, RD0:$RD0, RD1:$RD1, AD:$AD"

# --- ENTER_PIN ----------------------------------------------------------------
logger -t "$LOG_TAG" "curl -s -X POST ENTER_PIN"
ENTER_PIN=$(curl -s -X POST "http://$ZTE_HOST/goform/goform_set_cmd_process" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Referer: http://$ZTE_HOST/index.html" \
    --header "Accept-Language: de-DE,de;q=0.9,en;q=0.8" \
    --header "Connection: keep-alive" \
    -c "$COOKIE_PATH" -b "$COOKIE_PATH" \
    -d "isTest=false&goformId=ENTER_PIN&PinNumber=$ZTE_PIN_RESOLVED&AD=$AD")

ENTER_PIN_RESULT=$(echo "$ENTER_PIN" | grep -oP '(?<="result":")[^"]+')
case "$ENTER_PIN_RESULT" in
    "success")
        logger -t "$LOG_TAG" "SIM unlocked."
        ;;
    "failure")
        logger -t "$LOG_TAG" "SIM unlocking failed."
        exit 1
        ;;
    *)
        logger -t "$LOG_TAG" "Unexpected result: $ENTER_PIN_RESULT"
        exit 1
        ;;
esac

# Refresh state after unlock.
modem_data=$(collect_modem_data)
MODEM_MAIN_STATE=$(jq -r '.modem_main_state // empty' <<< "$modem_data")
logger -t "$LOG_TAG" "MODEM_MAIN_STATE:$MODEM_MAIN_STATE"

if command -v netbird >/dev/null 2>&1; then
    netbird up
else
    logger -t "$LOG_TAG" "netbird not found — skipping netbird up"
fi
