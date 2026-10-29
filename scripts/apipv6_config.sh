#!/bin/sh
# AP IPv6 Manager shared CLI and KoolShare _api handler.

PLUGIN_VERSION=0.1.0
KS_DIR=${APIPV6_KS_DIR:-/koolshare}
APIPV6_SYSTEM_PATHS=${APIPV6_SYSTEM_PATHS:-}
APIPV6_DEFAULT_SYSTEM_PATHS=$KS_DIR/bin:$KS_DIR/scripts:/koolshare/bin:/koolshare/scripts:/jffs/softcenter/bin:/jffs/softcenter/scripts:/jffs/.koolshare/bin:/jffs/.koolshare/scripts:/usr/sbin:/sbin:/usr/bin:/bin
PATH=${PATH:+$PATH:}${APIPV6_SYSTEM_PATHS:+$APIPV6_SYSTEM_PATHS:}$APIPV6_DEFAULT_SYSTEM_PATHS
export PATH

# Firmware ash may be built without the optional 'command' builtin.
# Scan PATH with shell primitives; preserve spaces and avoid pathname expansion.
find_executable() (
    remaining_path=$PATH
    while :; do
        case "$remaining_path" in
            *:*) path_dir=${remaining_path%%:*}; remaining_path=${remaining_path#*:}; more=1 ;;
            *) path_dir=$remaining_path; remaining_path=; more=0 ;;
        esac
        [ -n "$path_dir" ] || path_dir=.
        candidate=$path_dir/$1
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            exit 0
        fi
        [ "$more" -eq 1 ] || exit 1
    done
)

SYSCTL_ROOT=${APIPV6_SYSCTL_ROOT:-/proc/sys/net/ipv6/conf}
RUN_DIR=${APIPV6_RUN_DIR:-$KS_DIR/var/apipv6}
CONFIG_FILE=${APIPV6_CONFIG_FILE:-$KS_DIR/configs/apipv6.conf}
BRIDGE=br0
PROBE_HOST=2606:4700:4700::1111
LOG_FILE=$RUN_DIR/apipv6.log
WEB_SUBMIT=0
API_REQUEST_ID=
umask 077

json_string() {
    json_value=$(printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e ':a' -e 'N' -e '$!ba' \
        -e 's/\n/\\n/g' \
        -e 's/\r/\\r/g' \
        -e 's/\t/\\t/g')
    printf '"%s"' "$json_value"
}

json_bool() {
    case "$1" in 1|true|yes) printf 'true' ;; *) printf 'false' ;; esac
}

now_string() {
    date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || printf 'unknown'
}

setting() {
    setting_key=$1
    setting_default=$2
    setting_value=
    if find_executable dbus >/dev/null 2>&1; then
        setting_value=$(dbus get "$setting_key" 2>/dev/null) || setting_value=
    fi
    if [ -z "$setting_value" ] && [ -r "$CONFIG_FILE" ]; then
        setting_value=$(awk -F= -v key="$setting_key" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { if (value != "") print value }' "$CONFIG_FILE" 2>/dev/null)
    fi
    [ -n "$setting_value" ] || setting_value=$setting_default
    printf '%s' "$setting_value"
}

set_setting() {
    set_key=$1
    set_value=$2
    case "$set_key" in apipv6_*) ;; *) return 1 ;; esac
    case "$set_value" in *[!a-zA-Z0-9_.:-]*) return 1 ;; esac
    if find_executable dbus >/dev/null 2>&1; then
        dbus set "$set_key=$set_value" || return 1
        dbus save >/dev/null 2>&1 || :
        return 0
    fi
    config_dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$config_dir" || return 1
    config_tmp=$CONFIG_FILE.tmp.$$
    if [ -r "$CONFIG_FILE" ]; then
        awk -F= -v key="$set_key" '$1 != key' "$CONFIG_FILE" > "$config_tmp" || {
            rm -f "$config_tmp"
            return 1
        }
    else
        : > "$config_tmp" || return 1
    fi
    printf '%s=%s\n' "$set_key" "$set_value" >> "$config_tmp" || {
        rm -f "$config_tmp"
        return 1
    }
    chmod 600 "$config_tmp" 2>/dev/null || :
    mv -f "$config_tmp" "$CONFIG_FILE"
}

valid_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

log_message() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 0
    if [ -f "$LOG_FILE" ]; then
        log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        case "$log_size" in ''|*[!0-9]*) log_size=0 ;; esac
        if [ "$log_size" -gt 131072 ]; then
            tail -c 32768 "$LOG_FILE" > "$LOG_FILE.tmp.$$" 2>/dev/null &&
                mv -f "$LOG_FILE.tmp.$$" "$LOG_FILE"
        fi
    fi
    printf '%s %s\n' "$(now_string)" "$*" >> "$LOG_FILE" 2>/dev/null || :
}

read_state_value() {
    state_file=$1
    state_key=$2
    state_default=$3
    state_value=
    if [ -r "$state_file" ]; then
        state_value=$(awk -F= -v key="$state_key" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { if (value != "") print value }' "$state_file" 2>/dev/null)
    fi
    [ -n "$state_value" ] || state_value=$state_default
    printf '%s' "$state_value"
}

read_sysctl() {
    sysctl_name=$1
    sysctl_file=$SYSCTL_ROOT/$BRIDGE/$sysctl_name
    # Some firmware procfs entries have no final newline. ash read returns
    # nonzero at EOF even when it has read the value; never discard that value.
    if [ -r "$sysctl_file" ] && sysctl_value=$(cat "$sysctl_file" 2>/dev/null); then
        case "$sysctl_value" in
            0|1|2) printf '%s' "$sysctl_value"; return 0 ;;
        esac
    fi
    printf 'unknown'
}

resolve_nvram() {
    nvram_path=$(find_executable nvram 2>/dev/null) || nvram_path=
    if [ -n "$nvram_path" ]; then
        printf '%s\n' "$nvram_path"
        return 0
    fi

    search_dirs=${APIPV6_NVRAM_SEARCH_DIRS:-/usr/sbin:/sbin:/usr/bin:/bin}
    saved_ifs=$IFS
    IFS=:
    for nvram_dir in $search_dirs; do
        [ -n "$nvram_dir" ] || continue
        nvram_path=$nvram_dir/nvram
        if [ -x "$nvram_path" ] && [ ! -d "$nvram_path" ]; then
            IFS=$saved_ifs
            printf '%s\n' "$nvram_path"
            return 0
        fi
    done
    IFS=$saved_ifs
    return 1
}

resolve_dbus() {
    dbus_path=$(find_executable dbus 2>/dev/null) || dbus_path=
    if [ -n "$dbus_path" ]; then
        printf '%s\n' "$dbus_path"
        return 0
    fi

    search_dirs=${APIPV6_DBUS_SEARCH_DIRS:-$KS_DIR/bin:/koolshare/bin:/jffs/softcenter/bin:/jffs/.koolshare/bin:/usr/sbin:/sbin:/usr/bin:/bin}
    saved_ifs=$IFS
    IFS=:
    for dbus_dir in $search_dirs; do
        [ -n "$dbus_dir" ] || continue
        dbus_path=$dbus_dir/dbus
        if [ -x "$dbus_path" ] && [ ! -d "$dbus_path" ]; then
            IFS=$saved_ifs
            printf '%s\n' "$dbus_path"
            return 0
        fi
    done
    IFS=$saved_ifs
    return 1
}

resolve_ip() {
    ip_path=$(find_executable ip 2>/dev/null) || ip_path=
    if [ -n "$ip_path" ]; then
        printf '%s\n' "$ip_path"
        return 0
    fi

    search_dirs=${APIPV6_IP_SEARCH_DIRS:-/usr/sbin:/sbin:/usr/bin:/bin}
    saved_ifs=$IFS
    IFS=:
    for ip_dir in $search_dirs; do
        [ -n "$ip_dir" ] || continue
        ip_path=$ip_dir/ip
        if [ -x "$ip_path" ] && [ ! -d "$ip_path" ]; then
            IFS=$saved_ifs
            printf '%s\n' "$ip_path"
            return 0
        fi
    done
    IFS=$saved_ifs
    return 1
}

setup_dbus_path() {
    APIPV6_DBUS_CMD=$(resolve_dbus) || return 1
    case "$APIPV6_DBUS_CMD" in
        */*) PATH=${APIPV6_DBUS_CMD%/*}${PATH:+:$PATH}; export PATH ;;
    esac
}

setup_ip_path() {
    APIPV6_IP_CMD=$(resolve_ip) || return 1
    case "$APIPV6_IP_CMD" in
        */*) PATH=${APIPV6_IP_CMD%/*}${PATH:+:$PATH}; export PATH ;;
    esac
}

setup_ip_path || :
setup_dbus_path || :

read_mode() {
    if nvram_command=$(resolve_nvram); then
        mode_value=$("$nvram_command" get sw_mode 2>/dev/null | tr -d '\r\n')
        [ -n "$mode_value" ] || mode_value=unknown
        printf '%s' "$mode_value"
    else
        printf 'unknown'
    fi
}

read_proxysta() {
    if nvram_command=$(resolve_nvram); then
        proxysta_value=$("$nvram_command" get wlc_psta 2>/dev/null | tr -d '\r\n')
        [ -n "$proxysta_value" ] || proxysta_value=0
        case "$proxysta_value" in 0|1) ;; *) proxysta_value=unknown ;; esac
        printf '%s' "$proxysta_value"
    else
        printf 'unknown'
    fi
}

is_ap_mode() {
    MODE=$(read_mode)
    WLC_PSTA=$(read_proxysta)
    [ "$MODE" = 3 ] && [ "$WLC_PSTA" = 0 ]
}

interface_is_up() {
    link_check=$(ip link show dev "$BRIDGE" 2>/dev/null) || return 1
    printf '%s\n' "$link_check" | grep -Eq '(<[^>]*,UP([,>])|state UP)'
}

address_rows() {
    address_output=$(ip -6 addr show dev "$BRIDGE" 2>/dev/null) || return 1
    printf '%s\n' "$address_output" | awk '
        function addr_type(value, lower) {
            lower = tolower(value)
            if (lower ~ /^fe[89ab][0-9a-f]:/) return "link_local"
            if (lower ~ /^(fc|fd)/) return "ula"
            if (lower ~ /^[23]/ && lower !~ /^2001:db8:/) return "global_unicast"
            if (lower ~ /^ff/) return "multicast"
            return "other"
        }
        /^[[:space:]]*inet6[[:space:]]/ {
            address = $2
            split(address, parts, "/")
            value = parts[1]
            prefix = parts[2]
            type = addr_type(value)
            state = "preferred"
            if (index($0, "deprecated") || $0 ~ /preferred_lft 0sec/) state = "deprecated"
            if (index($0, "tentative")) state = "tentative"
            if (index($0, "dadfailed")) state = "dadfailed"
            preferred = "unknown"
            valid = "unknown"
            temporary = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "preferred_lft" && i < NF) preferred = $(i + 1)
                if ($i == "valid_lft" && i < NF) valid = $(i + 1)
                if ($i == "temporary") temporary = 1
            }
            if (preferred == "unknown" && state == "preferred") preferred = "forever"
            if (valid == "unknown") valid = "forever"
            print value "\t" prefix "\t" type "\t" state "\t" preferred "\t" valid "\t" temporary
        }
    '
}

network_prefix() {
    printf '%s %s\n' "$1" "$2" | awk '
        function hex_value(text, lower, i, digit, value) {
            lower = tolower(text)
            value = 0
            for (i = 1; i <= length(lower); i++) {
                digit = index("0123456789abcdef", substr(lower, i, 1)) - 1
                if (digit < 0) return 0
                value = value * 16 + digit
            }
            return value
        }
        function hex_text(value, text, digit) {
            if (value == 0) return "0"
            text = ""
            while (value > 0) {
                digit = value % 16
                text = substr("0123456789abcdef", digit + 1, 1) text
                value = int(value / 16)
            }
            return text
        }
        {
            address = $1
            bits = $2 + 0
            sub(/%.*/, "", address)
            left = address
            right = ""
            compressed = index(address, "::")
            if (compressed) {
                split(address, halves, "::")
                left = halves[1]
                right = halves[2]
            }
            left_count = 0
            right_count = 0
            if (left != "") left_count = split(left, left_parts, ":")
            if (right != "") right_count = split(right, right_parts, ":")
            missing = 8 - left_count - right_count
            if (!compressed && missing != 0) exit 1
            if (compressed && missing < 1) exit 1
            result = ""
            for (i = 1; i <= 8; i++) {
                if (i <= left_count) group = left_parts[i]
                else if (i > left_count + missing) group = right_parts[i - left_count - missing]
                else group = "0"
                value = hex_value(group)
                remaining = bits - (i - 1) * 16
                if (remaining <= 0) value = 0
                else if (remaining < 16) {
                    divisor = 2 ^ (16 - remaining)
                    value = int(value / divisor) * divisor
                }
                if (i > 1) result = result ":"
                result = result hex_text(value)
            }
            print result "/" bits
        }
    '
}

collect_status() {
    MODE=$(read_mode)
    WLC_PSTA=$(read_proxysta)
    AP_MODE=0
    [ "$MODE" = 3 ] && [ "$WLC_PSTA" = 0 ] && AP_MODE=1

    IP_AVAILABLE=0
    find_executable ip >/dev/null 2>&1 && IP_AVAILABLE=1
    BRIDGE_EXISTS=0
    BRIDGE_UP=0
    ADDRESS_READ_OK=0
    ROUTE_READ_OK=0
    ADDRESS_ROWS=
    PRIMARY_IPV6=
    PRIMARY_PREFIX=
    PRIMARY_NETWORK=
    DEFAULT_ROUTE=0
    DEFAULT_GATEWAY=
    PUBLIC_CONNECTIVITY=unknown
    PING_DETAIL=''

    if [ "$IP_AVAILABLE" -eq 1 ] && ip link show dev "$BRIDGE" >/dev/null 2>&1; then
        BRIDGE_EXISTS=1
        interface_is_up && BRIDGE_UP=1
        ADDRESS_ROWS=$(address_rows) && ADDRESS_READ_OK=1
        route_output=$(ip -6 route show default 2>/dev/null) && ROUTE_READ_OK=1
        if [ "$ROUTE_READ_OK" -eq 1 ]; then
            route_fields=$(printf '%s\n' "$route_output" | awk '$1 == "default" { for (i = 1; i <= NF; i++) if ($i == "via" && i < NF) { print $(i + 1); exit } }')
            if printf '%s\n' "$route_output" | awk '$1 == "default" { found=1 } END { exit !found }'; then
                DEFAULT_ROUTE=1
                DEFAULT_GATEWAY=$route_fields
            fi
        fi
    fi

    if [ "$ADDRESS_READ_OK" -eq 1 ]; then
        while IFS="$(printf '\t')" read -r address prefix addr_type addr_state preferred_lft valid_lft temporary; do
            [ -n "$address" ] || continue
            case "$address" in *[!0-9a-fA-F:%._-]*) continue ;; esac
            if [ "$addr_type" = global_unicast ] && [ "$addr_state" = preferred ] && [ -z "$PRIMARY_IPV6" ]; then
                PRIMARY_IPV6=$address
                PRIMARY_PREFIX=$prefix
            fi
        done <<EOF
$ADDRESS_ROWS
EOF
    fi
    if [ -n "$PRIMARY_IPV6" ] && [ -n "$PRIMARY_PREFIX" ]; then
        PRIMARY_NETWORK=$(network_prefix "$PRIMARY_IPV6" "$PRIMARY_PREFIX" 2>/dev/null)
    fi

    DISABLE_IPV6=$(read_sysctl disable_ipv6)
    ACCEPT_RA=$(read_sysctl accept_ra)
    AUTOCONF=$(read_sysctl autoconf)
    AUTO_ENABLED=$(setting apipv6_enabled 0)
    HEALTH_ENABLED=$(setting apipv6_health_enabled 0)
    REPAIR_ON_ERROR=$(setting apipv6_repair_on_error 0)
    HEALTH_INTERVAL=$(setting apipv6_health_interval 15)
    START_DELAY=$(setting apipv6_start_delay 30)
    LAST_CHECK=$(setting apipv6_last_check '')
    LAST_REPAIR=$(setting apipv6_last_repair '')
    LAST_FAILURE=$(setting apipv6_last_failure '')
    MIGRATION_FILE=$RUN_DIR/migration-state
    MIGRATION_STATUS=$(read_state_value "$MIGRATION_FILE" status none)
    MIGRATION_SHA=$(read_state_value "$MIGRATION_FILE" sha256 '')
    MIGRATION_PATH=$(read_state_value "$MIGRATION_FILE" path '')

    HEALTH=normal
    HEALTH_REASON='IPv6 地址、默认路由和公网连通性探测均正常。'
    if [ "$MODE" = unknown ] || [ "$WLC_PSTA" = unknown ] || [ "$IP_AVAILABLE" -ne 1 ]; then
        HEALTH=detection_error
        HEALTH_REASON='无法使用必要的 nvram 或 ip 命令。'
    elif [ "$AP_MODE" -ne 1 ]; then
        HEALTH=not_applicable
        HEALTH_REASON='自动修复仅适用于 AP 模式：sw_mode=3 且无线客户端模式已关闭。'
    elif [ "$BRIDGE_EXISTS" -ne 1 ]; then
        HEALTH=detection_error
        HEALTH_REASON='br0 桥接接口不存在。'
    elif [ "$BRIDGE_UP" -ne 1 ]; then
        HEALTH=detection_error
        HEALTH_REASON='br0 桥接接口存在，但尚未启用。'
    elif [ "$ADDRESS_READ_OK" -ne 1 ] || [ "$ROUTE_READ_OK" -ne 1 ]; then
        HEALTH=detection_error
        HEALTH_REASON='IPv6 地址或路由信息读取失败。'
    elif [ "$DISABLE_IPV6" = unknown ] || [ "$ACCEPT_RA" = unknown ] || [ "$AUTOCONF" = unknown ]; then
        HEALTH=detection_error
        HEALTH_REASON='无法读取 br0 的一项或多项 IPv6 参数。'
    elif [ "$DISABLE_IPV6" != 0 ] || [ "$ACCEPT_RA" != 2 ] || [ "$AUTOCONF" != 1 ]; then
        HEALTH=parameter_error
        HEALTH_REASON='br0 的 IPv6 参数不符合 SLAAC 客户端要求。'
    elif [ -z "$PRIMARY_IPV6" ]; then
        if [ "$(setting apipv6_last_failure '')" = waiting_ra ]; then
            HEALTH=waiting_ra
            HEALTH_REASON='SLAAC 参数已设置，正在等待首选全球单播 IPv6 地址。'
        else
            HEALTH=address_error
            HEALTH_REASON='br0 尚未获取首选全球单播 IPv6 地址。'
        fi
    elif [ "$DEFAULT_ROUTE" -ne 1 ]; then
        HEALTH=route_error
        HEALTH_REASON='已获取首选全球单播 IPv6 地址，但缺少 IPv6 默认路由。'
    else
        if find_executable ping6 >/dev/null 2>&1; then
            if ping6 -c 1 -W 2 "$PROBE_HOST" >/dev/null 2>&1; then
                PUBLIC_CONNECTIVITY=success
            else
                PUBLIC_CONNECTIVITY=failure
            fi
        elif find_executable ping >/dev/null 2>&1; then
            if ping -6 -c 1 -W 2 "$PROBE_HOST" >/dev/null 2>&1; then
                PUBLIC_CONNECTIVITY=success
            else
                PUBLIC_CONNECTIVITY=failure
            fi
        else
            PUBLIC_CONNECTIVITY=unknown
            PING_DETAIL='固件未提供 ping6 或 ping 命令。'
        fi
        if [ "$PUBLIC_CONNECTIVITY" = failure ]; then
            HEALTH=partial
            HEALTH_REASON='IPv6 地址和默认路由正常，但公网 ICMPv6 探测失败；目标可能过滤了 ICMPv6。'
        elif [ "$PUBLIC_CONNECTIVITY" = unknown ]; then
            HEALTH=partial
            HEALTH_REASON='IPv6 地址和默认路由正常，但无法进行公网连通性探测。'
        fi
    fi
}

health_label() {
    case "$1" in
        normal) printf '正常' ;;
        partial) printf '部分异常' ;;
        address_error) printf '地址异常' ;;
        route_error) printf '路由异常' ;;
        parameter_error) printf '参数异常' ;;
        waiting_ra) printf '等待 RA' ;;
        disabled) printf '未启用' ;;
        not_applicable) printf '不适用' ;;
        detection_error) printf '检测错误' ;;
        *) printf '未知' ;;
    esac
}

status_json() {
    collect_status
    printf '{"version":'; json_string "$PLUGIN_VERSION"
    printf ',"health":'; json_string "$HEALTH"
    printf ',"health_label":'; json_string "$(health_label "$HEALTH")"
    printf ',"reason":'; json_string "$HEALTH_REASON"
    printf ',"mode":'; json_string "$MODE"
    printf ',"wlc_psta":'; json_string "$WLC_PSTA"
    printf ',"ap_mode":'; json_bool "$AP_MODE"
    printf ',"bridge":{"name":"br0","exists":'; json_bool "$BRIDGE_EXISTS"
    printf ',"up":'; json_bool "$BRIDGE_UP"; printf '}'
    printf ',"sysctl":{"disable_ipv6":'; json_string "$DISABLE_IPV6"
    printf ',"accept_ra":'; json_string "$ACCEPT_RA"
    printf ',"autoconf":'; json_string "$AUTOCONF"; printf '}'
    printf ',"addresses":['
    first_address=1
    while IFS="$(printf '\t')" read -r address prefix addr_type addr_state preferred_lft valid_lft temporary; do
        [ -n "$address" ] || continue
        case "$address" in *[!0-9a-fA-F:%._-]*) continue ;; esac
        [ "$first_address" -eq 1 ] || printf ','
        first_address=0
        printf '{"address":'; json_string "$address"
        printf ',"type":'; json_string "$addr_type"
        printf ',"state":'; json_string "$addr_state"
        printf ',"prefix_length":'; json_string "$prefix"
        printf ',"preferred_lifetime":'; json_string "$preferred_lft"
        printf ',"valid_lifetime":'; json_string "$valid_lft"
        printf ',"temporary":'; json_bool "$temporary"; printf '}'
    done <<EOF
$ADDRESS_ROWS
EOF
    printf '],"preferred_ipv6":'; json_string "$PRIMARY_IPV6"
    if [ -n "$PRIMARY_PREFIX" ]; then
        printf ',"prefix":'; json_string "${PRIMARY_NETWORK:-$PRIMARY_IPV6/$PRIMARY_PREFIX}"
    else
        printf ',"prefix":""'
    fi
    printf ',"default_route":'; json_bool "$DEFAULT_ROUTE"
    printf ',"default_gateway":'; json_string "$DEFAULT_GATEWAY"
    printf ',"public_connectivity":'; json_string "$PUBLIC_CONNECTIVITY"
    printf ',"probe_host":'; json_string "$PROBE_HOST"
    printf ',"auto_enabled":'; json_bool "$AUTO_ENABLED"
    printf ',"health_check_enabled":'; json_bool "$HEALTH_ENABLED"
    printf ',"repair_on_error":'; json_bool "$REPAIR_ON_ERROR"
    printf ',"health_interval_minutes":'; json_string "$HEALTH_INTERVAL"
    printf ',"start_delay_seconds":'; json_string "$START_DELAY"
    printf ',"last_check":'; json_string "$LAST_CHECK"
    printf ',"last_repair":'; json_string "$LAST_REPAIR"
    printf ',"last_failure":'; json_string "$LAST_FAILURE"
    printf ',"migration_status":'; json_string "$MIGRATION_STATUS"
    printf ',"migration_sha256":'; json_string "$MIGRATION_SHA"
    printf ',"migration_path":'; json_string "$MIGRATION_PATH"
    printf ',"ping_detail":'; json_string "$PING_DETAIL"
    printf '}\n'
}

repair_exit_code() {
    case "$1" in success|normal|partial) return 0 ;; not_applicable) return 5 ;; waiting_ra) return 2 ;; *) return 3 ;; esac
}

acquire_lock() {
    lock_dir=$1
    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 1
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid" || {
            rm -f "$lock_dir/pid"
            rmdir "$lock_dir" 2>/dev/null || :
            return 1
        }
        LOCK_HELD=$lock_dir
        return 0
    fi
    lock_owner=$(cat "$lock_dir/pid" 2>/dev/null)
    case "$lock_owner" in ''|*[!0-9]*) lock_owner= ;; esac
    if [ -n "$lock_owner" ] && kill -0 "$lock_owner" 2>/dev/null; then
        return 1
    fi
    rm -f "$lock_dir/pid" 2>/dev/null || :
    rmdir "$lock_dir" 2>/dev/null || return 1
    mkdir "$lock_dir" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$lock_dir/pid" || {
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || :
        return 1
    }
    LOCK_HELD=$lock_dir
}

release_lock() {
    release_dir=${1:-${LOCK_HELD:-}}
    [ -n "$release_dir" ] || return 0
    lock_owner=$(cat "$release_dir/pid" 2>/dev/null)
    if [ "$lock_owner" = "$$" ]; then
        rm -f "$release_dir/pid"
        rmdir "$release_dir" 2>/dev/null || :
    fi
    [ "$release_dir" = "${LOCK_HELD:-}" ] && LOCK_HELD=
}

sleep_seconds() {
    case "${APIPV6_TEST_NO_SLEEP:-0}" in
        1) return 0 ;;
    esac
    sleep "$1"
}

probe_ready() {
    candidate_rows=$(address_rows 2>/dev/null) || return 1
    has_preferred=$(printf '%s\n' "$candidate_rows" | awk -F '\t' '$3 == "global_unicast" && $4 == "preferred" { found=1 } END { exit !found }' && printf yes || printf no)
    [ "$has_preferred" = yes ] || return 1
    route_state=$(ip -6 route show default 2>/dev/null) || return 1
    printf '%s\n' "$route_state" | awk '$1 == "default" { found=1 } END { exit !found }'
}

set_bridge_sysctl() {
    sysctl_name=$1
    case "$sysctl_name" in disable_ipv6|autoconf|accept_ra) ;; *) return 1 ;; esac
    case "$sysctl_name" in
        disable_ipv6) sysctl_value=0 ;;
        autoconf) sysctl_value=1 ;;
        accept_ra) sysctl_value=2 ;;
    esac
    sysctl_file=$SYSCTL_ROOT/$BRIDGE/$sysctl_name
    [ -e "$sysctl_file" ] || return 1
    printf '%s\n' "$sysctl_value" > "$sysctl_file"
}

repair_operation() {
    wait_seconds=${APIPV6_RA_WAIT_SECONDS:-30}
    valid_uint "$wait_seconds" 0 120 || wait_seconds=30
    if ! acquire_lock "$RUN_DIR/repair.lock"; then
        log_message 'Repair skipped: another repair is already running.'
        printf '{"repair_result":"already_running","message":"Another repair task is active."}\n'
        return 3
    fi
    trap 'release_lock' EXIT HUP INT TERM
    before_disable=$(read_sysctl disable_ipv6)
    before_autoconf=$(read_sysctl autoconf)
    before_accept_ra=$(read_sysctl accept_ra)
    repair_result=error
    repair_message=
    changed=0
    write_failed=0
    repair_time=$(now_string)

    if ! is_ap_mode; then
        repair_result=not_applicable
        repair_message='Refusing to change IPv6 settings because AP mode is not confirmed (sw_mode must be 3 and wlc_psta must be off).'
    elif ! find_executable ip >/dev/null 2>&1 || ! interface_is_up; then
        repair_result=error
        repair_message='Refusing to change IPv6 settings because br0 is unavailable or not UP.'
    elif [ "$before_disable" = unknown ] || [ "$before_autoconf" = unknown ] || [ "$before_accept_ra" = unknown ]; then
        repair_result=error
        repair_message='Refusing to change IPv6 settings because the current br0 sysctl values could not be read.'
    elif [ ! -w "$SYSCTL_ROOT/$BRIDGE/disable_ipv6" ] ||
        [ ! -w "$SYSCTL_ROOT/$BRIDGE/autoconf" ] ||
        [ ! -w "$SYSCTL_ROOT/$BRIDGE/accept_ra" ]; then
        repair_result=error
        repair_message='One or more br0 IPv6 sysctl files are not writable.'
    else
        if [ "$before_disable" != 0 ]; then
            if set_bridge_sysctl disable_ipv6; then changed=1; else write_failed=1; fi
        fi
        if [ "$before_autoconf" != 1 ]; then
            if set_bridge_sysctl autoconf; then changed=1; else write_failed=1; fi
        fi
        if [ "$before_accept_ra" != 2 ]; then
            if set_bridge_sysctl accept_ra; then changed=1; else write_failed=1; fi
        fi
        after_disable=$(read_sysctl disable_ipv6)
        after_autoconf=$(read_sysctl autoconf)
        after_accept_ra=$(read_sysctl accept_ra)
        if [ "$write_failed" -eq 1 ] || [ "$after_disable" != 0 ] || [ "$after_autoconf" != 1 ] || [ "$after_accept_ra" != 2 ]; then
            repair_result=error
            repair_message='The requested br0 sysctl values could not be verified.'
        else
            if [ "$changed" -eq 1 ]; then
                repair_message='Updated only br0 disable_ipv6, autoconf, and accept_ra.'
            else
                repair_message='br0 IPv6 SLAAC parameters were already correct; no sysctl writes were needed.'
            fi
            if probe_ready; then
                repair_result=success
            else
                waited=0
                while [ "$waited" -lt "$wait_seconds" ]; do
                    sleep_seconds 5
                    waited=$((waited + 5))
                    if probe_ready; then
                        repair_result=success
                        break
                    fi
                done
                if [ "$repair_result" != success ]; then
                    repair_result=waiting_ra
                    repair_message="$repair_message RA or a preferred IPv6 address/default route did not arrive within ${wait_seconds}s."
                fi
            fi
        fi
    fi

    after_disable=$(read_sysctl disable_ipv6)
    after_autoconf=$(read_sysctl autoconf)
    after_accept_ra=$(read_sysctl accept_ra)
    if [ "$repair_result" = success ]; then
        collect_status
        if [ "$HEALTH" = partial ]; then
            repair_result=partial
            repair_message="$repair_message Address and route are ready, but the public ICMPv6 probe did not succeed."
        fi
    fi
    if [ "$repair_result" = success ] || [ "$repair_result" = partial ]; then
        set_setting apipv6_last_repair "$repair_time" || :
        set_setting apipv6_last_failure '' || :
        log_message "Repair $repair_result (changed=$changed): $repair_message"
        if [ "$(setting apipv6_enabled 0)" = 1 ] && [ -x "$KS_DIR/scripts/apipv6_migrate.sh" ]; then
            "$KS_DIR/scripts/apipv6_migrate.sh" deactivate >/dev/null 2>&1 ||
                log_message 'Legacy V00 entry was not deactivated; inspect the migration status before retrying.'
        fi
    else
        set_setting apipv6_last_failure "$repair_result" || :
        log_message "Repair $repair_result (changed=$changed): $repair_message"
    fi
    release_lock
    trap - EXIT HUP INT TERM

    printf '{"repair_result":'; json_string "$repair_result"
    printf ',"message":'; json_string "$repair_message"
    printf ',"changed":'; json_bool "$changed"
    printf ',"before":{"disable_ipv6":'; json_string "$before_disable"
    printf ',"autoconf":'; json_string "$before_autoconf"
    printf ',"accept_ra":'; json_string "$before_accept_ra"; printf '}'
    printf ',"after":{"disable_ipv6":'; json_string "$after_disable"
    printf ',"autoconf":'; json_string "$after_autoconf"
    printf ',"accept_ra":'; json_string "$after_accept_ra"; printf '}'
    printf ',"wait_limit_seconds":'; json_string "$wait_seconds"
    printf ',"time":'; json_string "$repair_time"
    printf '}\n'
    repair_exit_code "$repair_result"
}

check_operation() {
    check_time=$(now_string)
    set_setting apipv6_last_check "$check_time" || :
    collect_status
    case "$HEALTH" in
        parameter_error|address_error|route_error)
            if [ "${1:-}" = --scheduled ] && [ "$(setting apipv6_repair_on_error 0)" = 1 ]; then
                repair_operation >/dev/null
                collect_status
            fi
            ;;
    esac
    status_json
    case "$HEALTH" in normal|partial|not_applicable) return 0 ;; detection_error) return 4 ;; *) return 2 ;; esac
}

cron_update() {
    health_enabled=$(setting apipv6_health_enabled 0)
    interval=$(setting apipv6_health_interval 15)
    valid_uint "$interval" 5 60 || interval=15
    if ! find_executable cru >/dev/null 2>&1; then
        [ "$health_enabled" = 0 ] || return 1
        return 0
    fi
    cru d apipv6_health >/dev/null 2>&1 || :
    if [ "$health_enabled" = 1 ]; then
        cru a apipv6_health "*/$interval * * * * $KS_DIR/scripts/apipv6_config.sh check --scheduled" || return 1
    fi
}

terminate_plugin_process() {
    pid_file=$1
    process_marker=$2
    [ -r "$pid_file" ] || return 0
    process_pid=$(cat "$pid_file" 2>/dev/null)
    case "$process_pid" in ''|*[!0-9]*) return 0 ;; esac
    [ -r "/proc/$process_pid/cmdline" ] || return 0
    process_cmd=$(tr '\000' ' ' < "/proc/$process_pid/cmdline" 2>/dev/null)
    case "$process_cmd" in *"$process_marker"*) kill "$process_pid" 2>/dev/null || : ;; esac
}

start_operation() {
    set_setting apipv6_enabled 1 || {
        printf '{"ok":false,"error":"Unable to save apipv6_enabled."}\n'
        return 1
    }
    if ! cron_update; then
        set_setting apipv6_enabled 0 || :
        printf '{"ok":false,"error":"cru is unavailable or the health schedule could not be installed."}\n'
        log_message 'Start failed: periodic check could not be scheduled.'
        return 1
    fi
    "$KS_DIR/scripts/apipv6_config.sh" boot >/dev/null 2>&1 </dev/null &
    start_pid=$!
    mkdir -p "$RUN_DIR" 2>/dev/null || :
    printf '%s\n' "$start_pid" > "$RUN_DIR/boot-launch.pid" 2>/dev/null || :
    log_message 'Automatic AP IPv6 management enabled.'
    printf '{"ok":true,"enabled":true,"boot_task":"started"}\n'
}

stop_operation() {
    set_setting apipv6_enabled 0 || {
        printf '{"ok":false,"error":"Unable to save apipv6_enabled."}\n'
        return 1
    }
    set_setting apipv6_health_enabled 0 || {
        printf '{"ok":false,"error":"Unable to save apipv6_health_enabled."}\n'
        return 1
    }
    if find_executable cru >/dev/null 2>&1; then cru d apipv6_health >/dev/null 2>&1 || :; fi
    terminate_plugin_process "$RUN_DIR/boot-launch.pid" "$KS_DIR/scripts/apipv6_config.sh boot"
    terminate_plugin_process "$RUN_DIR/task/pid" "$KS_DIR/scripts/apipv6_config.sh __web_repair"
    log_message 'Automatic AP IPv6 management disabled; system IPv6 settings were left unchanged.'
    printf '{"ok":true,"enabled":false,"system_ipv6_unchanged":true}\n'
}

boot_operation() {
    cron_update || log_message 'Periodic health check could not be restored by the boot hook.'
    [ "$(setting apipv6_enabled 0)" = 1 ] || {
        log_message 'Boot hook skipped because automatic repair is disabled.'
        return 0
    }
    LOCK_HELD=
    if ! acquire_lock "$RUN_DIR/boot.lock"; then
        log_message 'Boot hook skipped because another boot task is active.'
        return 0
    fi
    boot_lock=$LOCK_HELD
    trap 'release_lock "$boot_lock"' EXIT HUP INT TERM
    delay=$(setting apipv6_start_delay 30)
    valid_uint "$delay" 0 180 || delay=30
    sleep_seconds "$delay"
    attempt=1
    while [ "$attempt" -le 3 ]; do
        [ "$(setting apipv6_enabled 0)" = 1 ] || break
        if ! is_ap_mode; then
            log_message 'Boot repair stopped: device is not in AP mode.'
            break
        fi
        if ! find_executable ip >/dev/null 2>&1 || ! interface_is_up; then
            log_message "Boot repair attempt $attempt skipped: br0 is not UP yet."
        else
            repair_operation >/dev/null
            collect_status
            case "$HEALTH" in
                normal|partial)
                    log_message "Boot repair finished with health=$HEALTH."
                    break
                    ;;
                *) log_message "Boot repair attempt $attempt ended with health=$HEALTH." ;;
            esac
        fi
        [ "$attempt" -ge 3 ] || sleep_seconds 15
        attempt=$((attempt + 1))
    done
    release_lock "$boot_lock"
    trap - EXIT HUP INT TERM
    launch_owner=$(cat "$RUN_DIR/boot-launch.pid" 2>/dev/null)
    [ "$launch_owner" = "$$" ] && rm -f "$RUN_DIR/boot-launch.pid" || :
    return 0
}

web_repair_start() {
    mkdir -p "$RUN_DIR/task" || {
        printf '{"ok":false,"error":"Unable to create task state directory."}\n'
        return 1
    }
    task_pid=$(read_state_value "$RUN_DIR/task/state" pid '')
    task_id=$(read_state_value "$RUN_DIR/task/state" id '')
    task_status=$(read_state_value "$RUN_DIR/task/state" status '')
    if [ -n "$task_id" ] && { [ "$task_status" = queued ] || { [ -n "$task_pid" ] && [ "$task_pid" != 0 ] && kill -0 "$task_pid" 2>/dev/null && [ "$task_status" = running ]; }; }; then
        printf '{"ok":true,"task_id":'; json_string "$task_id"
        printf ',"status":"running"}\n'
        return 0
    fi
    task_id="$(date +%s 2>/dev/null)-$$"
    task_state_tmp=$RUN_DIR/task/state.tmp.$$
    printf 'id=%s\nstatus=queued\npid=0\n' "$task_id" > "$task_state_tmp" || return 1
    mv -f "$task_state_tmp" "$RUN_DIR/task/state" || return 1
    "$KS_DIR/scripts/apipv6_config.sh" __web_repair "$task_id" >/dev/null 2>&1 </dev/null &
    task_pid=$!
    printf '%s\n' "$task_pid" > "$RUN_DIR/task/pid" || return 1
    printf 'id=%s\nstatus=running\npid=%s\n' "$task_id" "$task_pid" > "$task_state_tmp" || return 1
    mv -f "$task_state_tmp" "$RUN_DIR/task/state" || return 1
    : > "$RUN_DIR/task/go.$task_id" || return 1
    printf '{"ok":true,"task_id":'; json_string "$task_id"
    printf ',"status":"running"}\n'
}

web_repair_worker() {
    worker_id=$1
    [ -n "$worker_id" ] || return 1
    barrier_tries=0
    while [ ! -f "$RUN_DIR/task/go.$worker_id" ] && [ "$barrier_tries" -lt 5 ]; do
        sleep 1
        barrier_tries=$((barrier_tries + 1))
    done
    if [ ! -f "$RUN_DIR/task/go.$worker_id" ]; then
        return 1
    fi
    rm -f "$RUN_DIR/task/go.$worker_id"
    repair_operation > "$RUN_DIR/task/result.tmp.$$" 2>&1
    worker_rc=$?
    task_tmp=$RUN_DIR/task/state.tmp.$$
    if [ "$worker_rc" -eq 0 ]; then worker_status=succeeded; else worker_status=failed; fi
    printf 'id=%s\nstatus=%s\npid=%s\nexit_code=%s\n' "$worker_id" "$worker_status" "$$" "$worker_rc" > "$task_tmp"
    mv -f "$task_tmp" "$RUN_DIR/task/state"
    rm -f "$RUN_DIR/task/pid"
    mv -f "$RUN_DIR/task/result.tmp.$$" "$RUN_DIR/task/result"
    return "$worker_rc"
}

web_task_status() {
    requested_id=$1
    task_current_id=$(read_state_value "$RUN_DIR/task/state" id '')
    task_current_status=$(read_state_value "$RUN_DIR/task/state" status unknown)
    task_current_pid=$(read_state_value "$RUN_DIR/task/state" pid '')
    task_exit=$(read_state_value "$RUN_DIR/task/state" exit_code '')
    if [ "$requested_id" != "$task_current_id" ]; then
        printf '{"task_id":'; json_string "$requested_id"
        printf ',"status":"not_found"}\n'
        return 1
    fi
    if [ "$task_current_status" = running ] && [ -n "$task_current_pid" ] && ! kill -0 "$task_current_pid" 2>/dev/null; then
        task_current_status=failed
    fi
    printf '{"task_id":'; json_string "$task_current_id"
    printf ',"status":'; json_string "$task_current_status"
    printf ',"exit_code":'; json_string "$task_exit"
    printf ',"result":'
    if [ -r "$RUN_DIR/task/result" ]; then
        task_result=$(cat "$RUN_DIR/task/result" 2>/dev/null)
        case "$task_result" in \{*\}) printf '%s' "$task_result" ;; *) printf 'null' ;; esac
    else
        printf 'null'
    fi
    printf '}\n'
}

save_web_config() {
    if [ -n "$API_REQUEST_ID" ]; then
        # httpdb writes fields to DBus BEFORE invoking this script. Read only
        # request-scoped staging keys; validate everything before live writes.
        new_enabled=$(dbus get "apipv6_websubmit_${API_REQUEST_ID}_enabled")
        new_delay=$(dbus get "apipv6_websubmit_${API_REQUEST_ID}_start_delay")
        new_health=$(dbus get "apipv6_websubmit_${API_REQUEST_ID}_health_enabled")
        new_interval=$(dbus get "apipv6_websubmit_${API_REQUEST_ID}_health_interval")
        new_repair=$(dbus get "apipv6_websubmit_${API_REQUEST_ID}_repair_on_error")
    else
        new_enabled=${apipv6_enabled:-$(setting apipv6_enabled 0)}
        new_delay=${apipv6_start_delay:-$(setting apipv6_start_delay 30)}
        new_health=${apipv6_health_enabled:-$(setting apipv6_health_enabled 0)}
        new_interval=${apipv6_health_interval:-$(setting apipv6_health_interval 15)}
        new_repair=${apipv6_repair_on_error:-$(setting apipv6_repair_on_error 0)}
    fi
    case "$new_enabled" in 0|1) ;; *) printf '{"ok":false,"error":"apipv6_enabled must be 0 or 1."}\n'; return 1 ;; esac
    case "$new_health" in 0|1) ;; *) printf '{"ok":false,"error":"apipv6_health_enabled must be 0 or 1."}\n'; return 1 ;; esac
    case "$new_repair" in 0|1) ;; *) printf '{"ok":false,"error":"apipv6_repair_on_error must be 0 or 1."}\n'; return 1 ;; esac
    valid_uint "$new_delay" 0 180 || { printf '{"ok":false,"error":"start delay must be between 0 and 180 seconds."}\n'; return 1; }
    valid_uint "$new_interval" 5 60 || { printf '{"ok":false,"error":"health interval must be between 5 and 60 minutes."}\n'; return 1; }
    old_enabled=$(setting apipv6_enabled 0)
    old_delay=$(setting apipv6_start_delay 30)
    old_health=$(setting apipv6_health_enabled 0)
    old_interval=$(setting apipv6_health_interval 15)
    old_repair=$(setting apipv6_repair_on_error 0)
    for pair in \
        "apipv6_start_delay=$new_delay" \
        "apipv6_health_enabled=$new_health" \
        "apipv6_health_interval=$new_interval" \
        "apipv6_repair_on_error=$new_repair" \
        "apipv6_enabled=$new_enabled"
    do
        save_key=${pair%%=*}
        save_value=${pair#*=}
        set_setting "$save_key" "$save_value" || {
            set_setting apipv6_start_delay "$old_delay" || :
            set_setting apipv6_health_enabled "$old_health" || :
            set_setting apipv6_health_interval "$old_interval" || :
            set_setting apipv6_repair_on_error "$old_repair" || :
            set_setting apipv6_enabled "$old_enabled" || :
            printf '{"ok":false,"error":"Failed to save %s."}\n' "$save_key"
            return 1
        }
    done
    cron_update || {
        set_setting apipv6_start_delay "$old_delay" || :
        set_setting apipv6_health_enabled "$old_health" || :
        set_setting apipv6_health_interval "$old_interval" || :
        set_setting apipv6_repair_on_error "$old_repair" || :
        set_setting apipv6_enabled "$old_enabled" || :
        cron_update || :
        printf '{"ok":false,"error":"Could not update the health schedule; verify cru is available."}\n'
        return 1
    }
    printf '{"ok":true,"saved":true}\n'
    log_message 'Web configuration saved.'
}

emit_web_result() {
    # The API adapter owns the one callback; CLI operations write JSON to stdout.
    printf '%s\n' "$1"
}

show_logs() {
    log_value=
    [ -r "$LOG_FILE" ] && log_value=$(tail -c 32768 "$LOG_FILE" 2>/dev/null)
    printf '{"log":'; json_string "$log_value"; printf '}\n'
}

usage() {
    cat <<'EOF'
AP IPv6 Manager 0.1.0
Usage: apipv6_config.sh COMMAND [OPTIONS]
  status [--json]     Read current AP IPv6 state (never changes settings)
  check               Run a health check and record its timestamp
  repair              Restore only br0 SLAAC sysctl values when AP mode is active
  start|stop|restart  Enable or stop this plugin's jobs (does not toggle system IPv6)
  version             Show plugin version
  help                Show this help
EOF
}

main() {
    operation=${1:-help}
    shift 2>/dev/null || :
    case "$operation" in
        status)
            case "${1:-}" in
                --json) status_json ;;
                *) collect_status; printf 'health=%s (%s)\n' "$HEALTH" "$(health_label "$HEALTH")"; printf 'mode=%s br0=%s preferred_ipv6=%s default_route=%s gateway=%s\n' "$MODE" "$BRIDGE_EXISTS" "${PRIMARY_IPV6:-none}" "$DEFAULT_ROUTE" "${DEFAULT_GATEWAY:-none}" ;;
            esac
            ;;
        check)
            if [ "${1:-}" = web_submit ]; then WEB_SUBMIT=1; fi
            check_operation "${1:-}"
            ;;
        repair)
            repair_operation
            ;;
        start)
            start_operation
            ;;
        stop)
            stop_operation
            ;;
        restart)
            restart_health=$(setting apipv6_health_enabled 0)
            stop_operation >/dev/null || return 1
            set_setting apipv6_health_enabled "$restart_health" || return 1
            cron_update || return 1
            start_operation
            ;;
        version)
            printf '%s\n' "$PLUGIN_VERSION"
            ;;
        save_config)
            [ "${1:-}" = web_submit ] && WEB_SUBMIT=1
            result=$(save_web_config)
            result_rc=$?
            emit_web_result "$result"
            return "$result_rc"
            ;;
        web_repair)
            [ "${1:-}" = web_submit ] && WEB_SUBMIT=1
            result=$(web_repair_start)
            result_rc=$?
            emit_web_result "$result"
            return "$result_rc"
            ;;
        web_task)
            [ "${2:-}" = web_submit ] && WEB_SUBMIT=1
            result=$(web_task_status "${1:-}")
            result_rc=$?
            emit_web_result "$result"
            return "$result_rc"
            ;;
        logs)
            [ "${1:-}" = web_submit ] && WEB_SUBMIT=1
            result=$(show_logs)
            emit_web_result "$result"
            ;;
        clear_log)
            [ "${1:-}" = web_submit ] && WEB_SUBMIT=1
            : > "$LOG_FILE" 2>/dev/null || {
                emit_web_result '{"ok":false,"error":"Unable to clear plugin log."}'
                return 1
            }
            emit_web_result '{"ok":true}'
            ;;
        boot)
            boot_operation
            ;;
        __web_repair)
            web_repair_worker "${1:-}"
            ;;
        *)
            usage
            [ "$operation" = help ] || return 1
            ;;
    esac
}

# Only ASCII hex crosses httpdb's legacy {"result":"%s"} envelope. That
# implementation does not escape quotes/newlines. awk is already required;
# do not add a dependency on base64, od, jq, or a firmware-specific helper.
encode_web_response() {
    LC_ALL=C awk '
        BEGIN {
            for (i=1; i<256; i++) byte[sprintf("%c", i)]=i
            printf "apipv6-hex-v1:"
        }
        {
            if (NR>1) printf "0a"
            for (i=1; i<=length($0); i++) printf "%02x", byte[substr($0,i,1)]
        }
    '
}

api_main() {
    API_REQUEST_ID=$1
    [ "${#API_REQUEST_ID}" -le 16 ] || return 1
    # KoolShare passes ID as argv[1]. base.sh captures it in ID and defines
    # http_response(), which POSTs the result to httpdb /_resp/ID. Stdout alone
    # does not complete an /_api request. Keep $1 intact while sourcing it.
    if [ ! -r "$KS_DIR/scripts/base.sh" ]; then
        printf '%s\n' 'KoolShare API error: scripts/base.sh is missing.' >&2
        return 1
    fi
    # shellcheck disable=SC1091
    . "$KS_DIR/scripts/base.sh"
    ID=$API_REQUEST_ID
    type http_response >/dev/null 2>&1 || {
        printf '%s\n' 'KoolShare API error: http_response is unavailable.' >&2
        return 1
    }
    shift
    case "${1:-}" in
        status) api_result=$(status_json); api_rc=$? ;;
        check) api_result=$(check_operation); api_rc=$? ;;
        save_config|web_repair|web_task|logs|clear_log)
            api_result=$(main "$@")
            api_rc=$?
            ;;
        *) api_result='{"ok":false,"error":"Unsupported Web operation."}'; api_rc=1 ;;
    esac
    for api_field in enabled start_delay health_enabled health_interval repair_on_error; do
        dbus remove "apipv6_websubmit_${API_REQUEST_ID}_$api_field" >/dev/null 2>&1 || :
    done
    # Every allowed operation returns JSON, including unhealthy status and
    # validation errors. A health exit code must not suppress the HTTP callback.
    [ -n "$api_result" ] || api_result='{"ok":false,"error":"Empty backend response."}'
    # curl -d @file avoids the kernel's per-argument limit for large log JSON.
    # base.sh still owns the callback endpoint and request ID.
    wire_dir=$RUN_DIR/response-$API_REQUEST_ID-$$
    mkdir -p "$RUN_DIR" && mkdir -m 700 "$wire_dir" || return 1
    if ! printf '%s' "$api_result" | encode_web_response > "$wire_dir/body"; then
        rm -f "$wire_dir/body"; rmdir "$wire_dir" 2>/dev/null || :
        log_message "KoolShare response encoding failed for request $API_REQUEST_ID."
        return 1
    fi
    http_response "@$wire_dir/body"
    callback_rc=$?
    rm -f "$wire_dir/body"; rmdir "$wire_dir" 2>/dev/null || :
    if [ "$callback_rc" -ne 0 ]; then
        log_message "KoolShare callback failed for request $API_REQUEST_ID."
        return 1
    fi
    return "$api_rc"
}

case "${1:-}" in
    ''|*[!0-9]*) main "$@" ;;
    *) api_main "$@" ;;
esac
