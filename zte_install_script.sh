#!/usr/bin/env bash
#
# ZTE MF79U Installer for Raspberry Pi / Jetson / Ubuntu
# Installs dispatcher and modem control scripts
#
# Usage:
#   ./install_zte_modem.sh --dry-run
#   ./install_zte_modem.sh --install
#

set -Eeuo pipefail

### ---------------------------------------------------------------------------
### CONFIGURATION
### ---------------------------------------------------------------------------

DISPATCHER_SRC="./00-nd-nm-dispatcher-zte-modem.sh"
HTTP_SRC="./zte_http.sh"
LOGIN_SRC="./zte_login.sh"

DISPATCHER_DST="/etc/NetworkManager/dispatcher.d/00-nd-nm-dispatcher-zte-modem.sh"
ZTE_DIR="/opt/zte"
HTTP_DST="$ZTE_DIR/zte_http.sh"
LOGIN_DST="$ZTE_DIR/zte_login.sh"
ENV_FILE="$ZTE_DIR/.env"

### ---------------------------------------------------------------------------
### COLORS
### ---------------------------------------------------------------------------
c_green="\033[1;32m"
c_red="\033[1;31m"
c_yellow="\033[1;33m"
c_blue="\033[1;34m"
c_reset="\033[0m"

### ---------------------------------------------------------------------------
### HELPER
### ---------------------------------------------------------------------------

msg() { echo -e "${c_blue}[*]${c_reset} $*"; }
ok()  { echo -e "${c_green}[OK]${c_reset} $*"; }
warn(){ echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err() { echo -e "${c_red}[ERR]${c_reset} $*" >&2; }

# Find the ZTE LTE network interface (vendor 19d2). A USB net iface's
# /sys/.../device symlink points at the USB *interface* node, which has no
# idVendor — that lives on a parent USB *device* node — so walk parents up.
# Echoes the iface name (empty if not present).
zte_find_iface() {
    local iface dev p
    for iface in eth1 usb0 wwan0 $(ls /sys/class/net 2>/dev/null | grep -E '^enx'); do
        dev="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null)" || continue
        [[ -n "$dev" ]] || continue
        p="$dev"
        while [[ -n "$p" && "$p" != "/" && "$p" != "/sys" ]]; do
            if [[ -f "$p/idVendor" && "$(cat "$p/idVendor" 2>/dev/null)" == "19d2" ]]; then
                printf '%s\n' "$iface"; return 0
            fi
            p="$(dirname "$p")"
        done
    done
    return 0
}

### ---------------------------------------------------------------------------
### PREFLIGHT CHECK
### ---------------------------------------------------------------------------

preflight_check() {
    msg "Running dry-run checks…"

    check_dependencies dry-run

    # check for files
    [[ -f "$DISPATCHER_SRC" ]] && ok "Found dispatcher script" || err "Missing $DISPATCHER_SRC"
    [[ -f "$HTTP_SRC" ]]        && ok "Found zte_http.sh"       || err "Missing $HTTP_SRC"
    [[ -f "$LOGIN_SRC" ]]       && ok "Found zte_login.sh"      || err "Missing $LOGIN_SRC"

    # check for root
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root – install will require sudo"
    else
        ok "Running as root"
    fi

    # check NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        ok "NetworkManager is running"
    else
        warn "NetworkManager not active – dispatcher will not trigger!"
    fi

    # check dispatcher directory
    if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
        ok "Dispatcher directory exists"
    else
        err "Missing /etc/NetworkManager/dispatcher.d"
    fi

    # target directory check
    if [[ -d "$ZTE_DIR" ]]; then
        ok "$ZTE_DIR already exists"
    else
        warn "$ZTE_DIR will be created"
    fi

    # USB device presence check (raw USB, works even before a net interface appears)
    msg "Checking for ZTE USB device…"
    if command -v lsusb >/dev/null 2>&1; then
        if lsusb | grep -qi "19d2"; then
            ok "ZTE USB device detected via lsusb (vendor 19d2)"
        else
            warn "No ZTE USB device found via lsusb — modem may not be connected or is in storage mode"
        fi
    else
        warn "lsusb not available — install usbutils for USB-level detection"
    fi

    # interface detection
    msg "Detecting potential modem interfaces…"
    local zte_iface
    zte_iface="$(zte_find_iface)"
    if [[ -n "$zte_iface" ]]; then
        ok "Detected ZTE modem interface: $zte_iface"
    else
        warn "No ZTE modem interface detected — connect the modem and re-run --dry-run to verify"
    fi

    # check netbird (optional)
    if command -v netbird >/dev/null 2>&1; then
        ok "netbird is installed"
    else
        warn "netbird not found — 'netbird up' will be skipped at runtime"
    fi

    # check .env
    if [[ -f "$ENV_FILE" ]]; then
        ok ".env file exists"
    else
        warn "No .env file found at $ENV_FILE – script will NOT work until created"
    fi

    msg "Dry-run completed."
}

### ---------------------------------------------------------------------------
### CREATE ENV ROUTINE
### ---------------------------------------------------------------------------

create_env_file() {
    msg "Creating new /opt/zte/.env …"

    echo
    echo "Please enter the required ZTE modem parameters."
    echo "Press ENTER to accept defaults shown in brackets."

    # Prompt helper
    ask() {
        local varname="$1"
        local prompt="$2"
        local default="$3"
        local value

        read -rp "$prompt [$default]: " value
        value="${value:-$default}"
        printf -v "$varname" "%s" "$value"
    }

    ask ZTE_HOST      "ZTE modem host/IP"            "192.168.0.1"
    ask ZTE_USERNAME  "ZTE modem username"           "admin"
    ask ZTE_PASSWORD  "ZTE modem password"           ""
    ask ZTE_PIN       "SIM PIN (leave empty if none)" ""
    ask ZTE_IMEI      "IMEI (optional, used for AD calc)" ""
    ask ZTE_DIAL_PROFILE "APN profile index"         "1"

    echo
    msg "Writing file $ENV_FILE …"

    cat <<EOF > "$ENV_FILE"
# ZTE Modem Configuration
ZTE_HOST="$ZTE_HOST"
ZTE_USERNAME="$ZTE_USERNAME"
ZTE_PASSWORD="$ZTE_PASSWORD"
ZTE_PIN="$ZTE_PIN"
ZTE_IMEI="$ZTE_IMEI"
ZTE_DIAL_PROFILE="$ZTE_DIAL_PROFILE"

# Logger tag
LOGGER_TAG="nd_zte"
EOF

    chmod 600 "$ENV_FILE"
    ok "Created and secured $ENV_FILE"

    echo
    msg "Summary of .env created:"
    echo "--------------------------------------------------"
    echo "ZTE_HOST          = $ZTE_HOST"
    echo "ZTE_USERNAME      = $ZTE_USERNAME"
    echo "ZTE_PASSWORD      = (hidden)"
    echo "ZTE_PIN           = ${ZTE_PIN:-<none>}"
    echo "ZTE_IMEI          = ${ZTE_IMEI:-<none>}"
    echo "ZTE_DIAL_PROFILE  = $ZTE_DIAL_PROFILE"
    echo "--------------------------------------------------"
}

### ---------------------------------------------------------------------------
### INSTALL ROUTINE
### ---------------------------------------------------------------------------

perform_install() {
    msg "Installing ZTE modem scripts…"

    check_dependencies install

    mkdir -p "$ZTE_DIR"
    ok "Created directory: $ZTE_DIR"

    msg "Copying scripts…"
    cp "$DISPATCHER_SRC" "$DISPATCHER_DST"
    cp "$HTTP_SRC" "$HTTP_DST"
    cp "$LOGIN_SRC" "$LOGIN_DST"

    ok "Scripts copied."

    msg "Setting permissions…"
    chmod 755 "$DISPATCHER_DST"
    chmod 755 "$HTTP_DST"
    chmod 755 "$LOGIN_DST"

    # .env is user-provided, only fix perms if it exists
    if [[ -f "$ENV_FILE" ]]; then
        chmod 600 "$ENV_FILE"
        ok ".env exists and is secured."
    else
        warn "Missing .env – creating one now…"
        create_env_file
    fi


    ok "Permissions set."

    msg "Reloading NetworkManager…"
    systemctl reload NetworkManager || warn "Could not reload NetworkManager"

    ok "Installation complete."
    msg "Dispatcher will trigger automatically on interface events."
}

### ---------------------------------------------------------------------------
### check_status
### ---------------------------------------------------------------------------

check_status() {
    msg "Running connectivity and routing status check…"
    echo

    # --- ZTE USB presence ---
    msg "ZTE USB device:"
    if command -v lsusb >/dev/null 2>&1; then
        local usb_line
        usb_line=$(lsusb | grep -i "19d2" || true)
        if [[ -n "$usb_line" ]]; then
            ok "ZTE USB present: $usb_line"
        else
            warn "ZTE USB device not detected via lsusb (vendor 19d2)"
        fi
    else
        warn "lsusb not available — install usbutils"
    fi
    echo

    # --- Identify ZTE (LTE) network interface ---
    local lte_iface
    lte_iface="$(zte_find_iface)"

    # --- Routing table ---
    msg "Default routes (all):"
    local route_output
    route_output=$(ip route show default 2>/dev/null || true)
    if [[ -n "$route_output" ]]; then
        echo "$route_output"
    else
        warn "No default routes found"
    fi
    echo

    # --- Determine effective default interface (lowest metric wins) ---
    local best_iface="" best_metric=99999
    while IFS= read -r line; do
        local m
        m=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')
        m="${m:-0}"
        local dev
        dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        if (( m < best_metric )); then
            best_metric=$m
            best_iface="$dev"
        fi
    done < <(ip route show default 2>/dev/null)

    # --- Priority verdict ---
    msg "Internet routing priority:"
    if [[ -n "$lte_iface" ]]; then
        local lte_metric
        lte_metric=$(ip route show default dev "$lte_iface" 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}' | head -1)
        lte_metric="${lte_metric:-0}"

        if [[ "$best_iface" == "$lte_iface" ]]; then
            ok "LTE ($lte_iface) is the active default route (metric: $lte_metric)"
        else
            local iface_type="unknown"
            local wifi_if
            wifi_if=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
                | awk -F: '$2=="wifi"{print $1; exit}' || true)
            [[ "$best_iface" == "$wifi_if" ]] && iface_type="Wi-Fi"
            warn "Default route: $best_iface/$iface_type (metric: $best_metric) — LTE ($lte_iface, metric: $lte_metric) is standby"
        fi
    else
        if [[ -n "$best_iface" ]]; then
            warn "No LTE interface up — traffic via: $best_iface (metric: $best_metric)"
        else
            err "No default route found"
        fi
    fi
    echo

    # --- NetworkManager connection metrics ---
    msg "NetworkManager active connections:"
    nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null \
        | while IFS=: read -r name dev type; do
            local metric
            metric=$(nmcli -g ipv4.route-metric con show "$name" 2>/dev/null || echo "?")
            printf "  %-30s dev=%-10s type=%-10s metric=%s\n" "$name" "$dev" "$type" "$metric"
        done || warn "nmcli not available"
    echo

    # --- Connectivity tests ---
    msg "Connectivity tests:"

    for target in "8.8.8.8" "1.1.1.1"; do
        local rtt
        rtt=$(ping -c 3 -W 3 -q "$target" 2>/dev/null | awk -F'/' '/rtt/{print $5}' || true)
        if [[ -n "$rtt" ]]; then
            ok "Ping ${target} — avg RTT: ${rtt} ms"
        else
            err "Ping ${target} — unreachable"
        fi
    done

    if getent hosts google.com >/dev/null 2>&1; then
        ok "DNS resolution: OK"
    else
        err "DNS resolution: FAILED"
    fi

    local http_code
    http_code=$(curl -sSo /dev/null -w "%{http_code}" --max-time 5 \
        https://connectivity.gstatic.com/generate_204 2>/dev/null || true)
    if [[ "$http_code" == "204" ]]; then
        ok "HTTPS connectivity: OK (HTTP 204)"
    else
        err "HTTPS connectivity: FAILED (HTTP ${http_code:-timeout})"
    fi

    # If LTE is up but not the default, test it directly too
    if [[ -n "$lte_iface" ]] && [[ "$best_iface" != "$lte_iface" ]]; then
        echo
        msg "LTE interface direct test ($lte_iface):"
        local lte_rtt
        lte_rtt=$(ping -I "$lte_iface" -c 3 -W 3 -q "8.8.8.8" 2>/dev/null \
            | awk -F'/' '/rtt/{print $5}' || true)
        if [[ -n "$lte_rtt" ]]; then
            ok "LTE reachable via $lte_iface — avg RTT: ${lte_rtt} ms"
        else
            warn "No ping response via $lte_iface (may be behind NAT or not fully up)"
        fi
    fi

    echo
    msg "Status check complete."
}

### ---------------------------------------------------------------------------
### activate_now
### ---------------------------------------------------------------------------


activate_now() {
    msg "Manually triggering ZTE activation…"

    SCRIPT="/opt/zte/zte_http.sh"
    LOGTAG="nd_zte"

    if [[ ! -x "$SCRIPT" ]]; then
        err "Worker script missing or not executable: $SCRIPT"
        exit 1
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        err "Missing $ENV_FILE — please run with --install first."
        exit 1
    fi

    export ZTE_ENV_FILE="$ENV_FILE"

    msg "Executing: $SCRIPT (background)…"
    /usr/bin/sudo -u root -H /bin/bash -lc "/bin/bash '$SCRIPT' 2>&1" \
        | /usr/bin/logger -t "$LOGTAG" &

    ok "Activation triggered. Check logs with:"
    echo "    journalctl -t $LOGTAG -n 50"
}

### ---------------------------------------------------------------------------
### check_dependencies
### ---------------------------------------------------------------------------
check_dependencies() {
    local mode="${1:-dry-run}"
    msg "Checking required packages…"

    # tool → apt package name (tool name used as fallback if not listed here)
    declare -A pkg_map=(
        [sha256sum]="coreutils"
        [md5sum]="coreutils"
        [logger]="bsdutils"
        [jq]="jq"
        [curl]="curl"
        [awk]="gawk"
        [sed]="sed"
        [grep]="grep"
    )

    local deps=(curl jq awk sed grep sha256sum md5sum logger)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        ok "All required dependencies are installed."
        return 0
    fi

    warn "Missing: ${missing[*]}"

    if [[ "$mode" == "dry-run" ]]; then
        # Just report what would be installed
        local pkgs=()
        for dep in "${missing[@]}"; do
            pkgs+=("${pkg_map[$dep]:-$dep}")
        done
        # deduplicate
        local unique_pkgs
        unique_pkgs=$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')
        msg "Would install: $unique_pkgs"
        return 0
    fi

    # install mode — actually install
    if command -v apt-get >/dev/null 2>&1; then
        local pkgs=()
        for dep in "${missing[@]}"; do
            pkgs+=("${pkg_map[$dep]:-$dep}")
        done
        # deduplicate
        local unique_pkgs
        mapfile -t unique_pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)

        msg "Installing: ${unique_pkgs[*]}"
        apt-get update -qq || { err "apt-get update failed"; exit 1; }
        apt-get install -y "${unique_pkgs[@]}" || { err "apt-get install failed"; exit 1; }

        # verify everything is now available
        local still_missing=()
        for dep in "${missing[@]}"; do
            command -v "$dep" >/dev/null 2>&1 || still_missing+=("$dep")
        done
        if (( ${#still_missing[@]} )); then
            err "Still missing after install: ${still_missing[*]}"
            exit 1
        fi
        ok "All dependencies installed."
    elif command -v dnf >/dev/null 2>&1; then
        local pkgs=()
        for dep in "${missing[@]}"; do pkgs+=("${pkg_map[$dep]:-$dep}"); done
        local unique_pkgs
        mapfile -t unique_pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        msg "Installing: ${unique_pkgs[*]}"
        dnf install -y "${unique_pkgs[@]}" || { err "dnf install failed"; exit 1; }
    elif command -v pacman >/dev/null 2>&1; then
        local pkgs=()
        for dep in "${missing[@]}"; do pkgs+=("${pkg_map[$dep]:-$dep}"); done
        local unique_pkgs
        mapfile -t unique_pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        msg "Installing: ${unique_pkgs[*]}"
        pacman -Sy --noconfirm "${unique_pkgs[@]}" || { err "pacman install failed"; exit 1; }
    else
        err "No supported package manager found. Install manually: ${missing[*]}"
        exit 1
    fi
}


### ---------------------------------------------------------------------------
### MAIN
### ---------------------------------------------------------------------------

case "${1:-}" in
    --dry-run)
        preflight_check
        ;;
    --install)
        perform_install
        ;;
    --activate)
        activate_now
        ;;
    --status)
        check_status
        ;;
    *)
        echo "Usage: $0 --dry-run | --install | --activate | --status"
        exit 1
        ;;
esac