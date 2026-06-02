#!/bin/bash
# triggered from /etc/NetworkManager/dispatcher.d/99-eth1-up.sh 
# for environment variables .. uses zte_http.sh
# this file goes to /opt/zte/zte_http.sh

COOKIE_PATH=/tmp/zte_cookies.txt

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
    #$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=upgrade_result&_=$epoch_ms" "${UAHDRS[@]}")

    responses=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=privacy_read_flag&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status,signalbar,network_type,network_provider,battery_charg_type,external_charging_flag,mode_main_state,battery_temp,SSID1,ppp_status,EX_SSID1,sta_ip_status,EX_wifi_profile,m_ssid_enable,RadioOff,wifi_onoff_state,wifi_chip1_ssid1_ssid,wifi_chip2_ssid1_ssid,wifi_chip1_ssid1_access_sta_num,wifi_chip2_ssid1_access_sta_num,simcard_roam,lan_ipaddr,station_mac,wifi_access_sta_num,battery_charging,battery_vol_percent,battery_pers,spn_name_data,spn_b1_flag,spn_b2_flag,realtime_tx_bytes,realtime_rx_bytes,realtime_time,realtime_tx_thrpt,realtime_rx_thrpt,monthly_rx_bytes,monthly_tx_bytes,monthly_time,date_month,data_volume_limit_switch,data_volume_limit_size,data_volume_alert_percent,data_volume_limit_unit,roam_setting_option,upg_roam_switch,ssid,wifi_enable,wifi_5g_enable,check_web_conflict,dial_mode,ppp_dial_conn_fail_counter,wan_lte_ca,privacy_read_flag,is_night_mode,pppoe_status,dhcp_wan_status,static_wan_status,vpn_conn_status,wan_connect_status,wifi_chip1_ssid2_access_sta_num,wifi_chip2_ssid2_access_sta_num&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,pin_status,opms_wan_mode,opms_wan_auto_mode,loginfo,new_version_state,current_upgrade_state,is_mandatory,wifi_dfs_status,battery_value,ppp_dial_conn_fail_counter,dhcp_wan_status&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryWiFiModuleSwitch&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryAccessPointInfo&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryWiFiModuleSwitch&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=queryAccessPointInfo&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=OOM_TEMP_PRO&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=modem_main_state,puknumber,pinnumber,opms_wan_mode,psw_fail_num_str,login_lock_time,SleepStatusForSingleChipCpe&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=Language,cr_version,wa_inner_version&multi_data=1&_=$epoch_ms" "${UAHDRS[@]}")")
    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=wifi_onoff_state,guest_switch,wifi_chip1_ssid2_max_access_num,RadioOff,SSID1,MAX_Access_num,m_SSID,m_MAX_Access_num,m_SSID2,wifi_coverage,wifi_chip2_ssid2_max_access_num,wifi_chip1_ssid1_wifi_coverage,apn_interface_version,m_ssid_enable,imei,network_type,rssi,rscp,lte_rsrp,imsi,sim_imsi,cr_version,wa_version,hardware_version,web_version,wa_inner_version,wifi_chip1_ssid1_max_access_num,wifi_chip1_ssid1_ssid,wifi_chip1_ssid1_auth_mode,wifi_chip1_ssid1_password_encode,wifi_chip2_ssid1_ssid,wifi_chip2_ssid1_auth_mode,m_HideSSID,wifi_chip2_ssid1_password_encode,wifi_chip2_ssid1_max_access_num,lan_ipaddr,mac_address,msisdn,LocalDomain,wan_ipaddr,static_wan_ipaddr,ipv6_wan_ipaddr,ipv6_pdp_type,ipv6_pdp_type_ui,pdp_type,pdp_type_ui,opms_wan_mode,opms_wan_auto_mode,ppp_status,Z5g_snr,Z5g_rsrp,wan_lte_ca,lte_ca_pcell_band,lte_ca_pcell_bandwidth,lte_ca_scell_band,lte_ca_scell_bandwidth,lte_ca_pcell_arfcn,lte_ca_scell_arfcn,lte_multi_ca_scell_info,wan_active_band,wifi_chip1_ssid2_ssid,wifi_chip2_ssid2_ssid,wifi_chip1_ssid1_switch_onoff,wifi_chip2_ssid1_switch_onoff,wifi_chip1_ssid2_switch_onoff,wifi_chip2_ssid2_switch_onoff,Z5g_SINR,station_ip_addr&_=$epoch_ms" "${UAHDRS[@]}")")


    responses+=("$(curl -s "$ZTE_HOST/goform/goform_get_cmd_process?isTest=false&cmd=imei&_=$epoch_ms" "${UAHDRS[@]}")")

    local merged
    merged=$(printf '%s\n' "${responses[@]}" | jq -s 'reduce .[] as $item ({}; . * $item)')

    echo "$merged"
}






# Tag for systemd logger
LOG_TAG="nd-nm-zte-modem"
logger -t "$LOG_TAG" "Newton ZTE MODEM Unlocker"

# Modem IP or hostname
ZTE_HOST="${ZTE_HOST:-localhost}"
MODEM_URL="http://$ZTE_HOST:8080"

logger -t "$LOG_TAG" "ZTE_HOST=$ZTE_HOST"

# Password (can be exported or set in .env)
ZTE_PASSWORD="${ZTE_PASSWORD:-SB8AW6V7}"

# Step 1: Get LD
logger -t "$LOG_TAG" "Fetching LD value from <$ZTE_HOST>"
LD_RESPONSE=$(curl -s --header "Referer: http://$ZTE_HOST/index.html" "$ZTE_HOST/goform/goform_get_cmd_process?cmd=LD")

echo "ZTE: $LD_RESPONSE"

LD=$(echo "$LD_RESPONSE" | grep -oP '(?<="LD":")[^"]+')
if [ -z "$LD" ]; then
    logger -t "$LOG_TAG" "Failed to extract LD value."
    exit 1
fi
logger -t "$LOG_TAG" "<$ZTE_HOST> $LD_RESPONSE"

# Step 2: Encrypt password
PREFIX_HASH=$(echo -n "$ZTE_PASSWORD" | sha256sum | awk '{print toupper($1)}')
LOGIN_HASH=$(echo -n "${PREFIX_HASH}${LD^^}" | sha256sum | awk '{print toupper($1)}')

logger -t "$LOG_TAG" "PREFIX_HASH: <$PREFIX_HASH>"
logger -t "$LOG_TAG" "LOGIN_HASH: <$LOGIN_HASH>"

# Step 3: Login
logger -t "$LOG_TAG" "Sending login request..."
LOGIN_RESPONSE=$(curl -s -c $COOKIE_PATH -b $COOKIE_PATH \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Referer: http://$ZTE_HOST/index.html" \
    --header "Accept-Language: de-DE,de;q=0.9,en;q=0.8" \
    --header "Connection: keep-alive" \
    -d "isTest=false&goformId=LOGIN&password=$LOGIN_HASH" \
    "$ZTE_HOST/goform/goform_set_cmd_process")

echo "Login response: $LOGIN_RESPONSE"
logger -t "$LOG_TAG" "Login response: $LOGIN_RESPONSE"

# Step 4: Interpret result
RESULT=$(echo "$LOGIN_RESPONSE" | grep -oP '(?<="result":")[^"]+')
case "$RESULT" in
    "0")
        logger -t "$LOG_TAG" "Login successful."
	    STOK=$(awk '/stok/ {print $NF}' $COOKIE_PATH)
	    logger -t "$LOG_TAG" "STOK=$STOK"
        ;;
    "3")
        logger -t "$LOG_TAG" "Login failed: bad password."
        exit 1
        ;;
    "1")
        logger -t "$LOG_TAG" "Login failed: Your account is locked - wait 5 minutes"
        exit 1
	    ;;
    *)
        logger -t "$LOG_TAG" "Unexpected login result: $RESULT"
        exit 1
        ;;
esac

# After login is successful and session is established
echo "### Login successful"
# Send the GET request

modem_data=$(collect_modem_data)


echo "$modem_data" | jq

# Fetch RD, rd0, rd1 for AD computation
logger -t "$LOG_TAG" "Fetching RD value from <$ZTE_HOST>"
RD_RESPONSE=$(curl -s --header "Referer: http://$ZTE_HOST/index.html" "$ZTE_HOST/goform/goform_get_cmd_process?cmd=RD")
logger -t "$LOG_TAG" "<$ZTE_HOST> $RD_RESPONSE"

RD=$(echo "$RD_RESPONSE" | grep -oP '(?<="RD":")[^"]+')
#RD=98f13708210194c475687be6106a3b84
if [ -z "$RD" ]; then
    logger -t "$LOG_TAG" "Failed to extract RD value."
    exit 1
fi
RD0=$(jq -r '.wa_inner_version // empty' <<< "$modem_data")
RD1=$(jq -r '.cr_version // empty' <<< "$modem_data")
#RD0="BD_XCBZHKMF79UV1.0.0B03"
#RD1=""

PREFIX_HASH=$(echo -n "${RD0}${RD1}" | md5sum | awk '{print $1}')
AD=$(echo -n "${PREFIX_HASH}${RD}" | md5sum | awk '{print $1}')
logger -t "$LOG_TAG" "RD:$RD, RD0:$RD0, RD1:$RD1, AD:$AD"

IMEI=$(jq -r '.imei' <<< "$modem_data")
MODEM_MAIN_STATE=$(jq -r '.modem_main_state' <<< "$modem_data")
logger -t "$LOG_TAG" "MODEM_MAIN_STATE:$MODEM_MAIN_STATE"

# Check conditions
if [[ "$IMEI" == $ZTE_IMEI ]]; then
    logger -t "$LOG_TAG" "curl -s -X POST ENTER_PIN"
    ENTER_PIN=$(curl -s -X POST http://$ZTE_HOST/goform/goform_set_cmd_process \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --header "Referer: http://$ZTE_HOST/index.html" \
    --header "Accept-Language: de-DE,de;q=0.9,en;q=0.8" \
    --header "Connection: keep-alive" \
    -c $COOKIE_PATH -b $COOKIE_PATH \
    -d "isTest=false&goformId=ENTER_PIN&PinNumber=$ZTE_PIN&AD=$AD" \
    )
else
    logger -t "$LOG_TAG" "IMEI in .env does not match IMEI returned by modem, skipping ENTER_PIN"
    exit 1
fi

# Step 4: Interpret result
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

modem_data=$(collect_modem_data)
network_type=$(jq -r '.network_type' <<< "$modem_data")
# echo "$network_type" 
MODEM_MAIN_STATE=$(jq -r '.modem_main_state' <<< "$modem_data")
logger -t "$LOG_TAG" "MODEM_MAIN_STATE:$MODEM_MAIN_STATE"

if command -v netbird >/dev/null 2>&1; then
    netbird up
else
    logger -t "$LOG_TAG" "netbird not found — skipping netbird up"
fi
