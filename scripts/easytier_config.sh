#!/bin/sh
# KoolShare EasyTier lifecycle manager. Compatible with BusyBox ash.

KS_DIR=${EASYTIER_KS_DIR:-/koolshare}
RUN_DIR=${EASYTIER_RUN_DIR:-/var/run}
TMP_DIR=${EASYTIER_TMP_DIR:-/tmp}
PROC_ROOT=${EASYTIER_PROC_ROOT:-/proc}
CONFIG_FILE=${EASYTIER_CONFIG_FILE:-$KS_DIR/configs/easytier.conf}
EASYTIER_BIN=${EASYTIER_BIN:-$KS_DIR/bin/easytier-core}
PID_FILE=${EASYTIER_PID_FILE:-$RUN_DIR/easytier.pid}
LOCK_DIR=${EASYTIER_LOCK_DIR:-$RUN_DIR/easytier.lock}
AUTO_LOCK_DIR=${EASYTIER_AUTO_LOCK_DIR:-$RUN_DIR/easytier-autostart.lock}
LOG_DIR=${EASYTIER_LOG_DIR:-$TMP_DIR/upload}
LOG_FILE=${EASYTIER_LOG_FILE:-$LOG_DIR/easytier_log.txt}
RUNTIME_LOG=${EASYTIER_RUNTIME_LOG:-$LOG_DIR/easytier_runtime.log}
LOCK_ATTEMPTS=${EASYTIER_LOCK_ATTEMPTS:-20}
START_WAIT=${EASYTIER_START_WAIT:-2}
STOP_WAIT=${EASYTIER_STOP_WAIT:-10}
AUTO_RETRIES=${EASYTIER_AUTO_RETRIES:-30}
AUTO_DELAY=${EASYTIER_AUTO_DELAY:-2}

BASE_SH=$KS_DIR/scripts/base.sh
if [ -r "$BASE_SH" ]; then
    . "$BASE_SH"
fi

OPERATION=
WEB_SUBMIT=0
for arg in "$@"; do
    case "$arg" in
        start|stop|restart|status|save_config|save_autostart|clear_runtime_log|autostart)
            [ -n "$OPERATION" ] || OPERATION=$arg
            ;;
        web_submit)
            WEB_SUBMIT=1
            ;;
    esac
done

log_msg() {
    mkdir -p "$LOG_DIR" 2>/dev/null || :
    if command -v echo_date >/dev/null 2>&1; then
        echo_date "$*" >> "$LOG_FILE"
    else
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$LOG_FILE"
    fi
}

runtime_msg() {
    mkdir -p "$LOG_DIR" 2>/dev/null || :
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$RUNTIME_LOG"
}

valid_pid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 1 ] 2>/dev/null ;;
    esac
}

pid_is_alive() {
    pid=$1
    kill -0 "$pid" 2>/dev/null || return 1
    statfile=$PROC_ROOT/$pid/stat
    if [ -r "$statfile" ]; then
        state=$(awk '{print $3}' "$statfile" 2>/dev/null)
        [ "$state" = Z ] && return 1
    fi
    return 0
}

pid_matches_plugin() {
    pid=$1
    valid_pid "$pid" || return 1
    pid_is_alive "$pid" || return 1
    cmdfile=$PROC_ROOT/$pid/cmdline
    [ -r "$cmdfile" ] || return 1
    cmdline=$( { tr '\000' ' ' < "$cmdfile"; } 2>/dev/null) || return 1
    case " $cmdline " in
        *" $EASYTIER_BIN -c $CONFIG_FILE "*) return 0 ;;
        *) return 1 ;;
    esac
}

find_plugin_pid() {
    for cmdfile in "$PROC_ROOT"/[0-9]*/cmdline; do
        [ -r "$cmdfile" ] || continue
        candidate_dir=${cmdfile%/cmdline}
        candidate=${candidate_dir##*/}
        valid_pid "$candidate" || continue
        if pid_matches_plugin "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

managed_pid() {
    pid=
    if [ -r "$PID_FILE" ]; then
        IFS= read -r pid < "$PID_FILE" || :
        if pid_matches_plugin "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
        # A stale or unrelated PID file is never permission to signal a process.
        rm -f "$PID_FILE"
    fi
    pid=$(find_plugin_pid) || return 1
    printf '%s\n' "$pid" > "$PID_FILE" || return 1
    printf '%s\n' "$pid"
}

acquire_lock() {
    tries=0
    mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || return 1
    while [ "$tries" -lt "$LOCK_ATTEMPTS" ]; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK_DIR/pid" || {
                rmdir "$LOCK_DIR" 2>/dev/null || :
                return 1
            }
            LOCK_HELD=1
            return 0
        fi
        owner=
        if [ -r "$LOCK_DIR/pid" ]; then
            IFS= read -r owner < "$LOCK_DIR/pid" || :
        fi
        if valid_pid "$owner" && pid_is_alive "$owner"; then
            :
        else
            # Give a newly created lock time to publish its owner before reclaiming.
            if [ "$tries" -ge 2 ]; then
                rm -f "$LOCK_DIR/pid" 2>/dev/null || :
                rmdir "$LOCK_DIR" 2>/dev/null || :
            fi
        fi
        tries=$((tries + 1))
        sleep 1
    done
    return 1
}

release_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    owner=
    if [ -r "$LOCK_DIR/pid" ]; then
        IFS= read -r owner < "$LOCK_DIR/pid" || :
    fi
    if [ "$owner" = "$$" ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || :
    fi
    LOCK_HELD=0
}

iptables_rule_exists() {
    iptables "$@" >/dev/null 2>&1
}

add_firewall_rules() {
    # Dedicated chains make new rules idempotent. Leave untagged legacy rules
    # untouched because their ownership cannot be proven, and avoid duplicating them.
    if iptables_rule_exists -C INPUT -i tun+ -j ACCEPT; then
        log_msg "检测到旧版 INPUT 规则，保留且避免重复添加"
    else
        iptables -N EASYTIER_INPUT 2>/dev/null || :
        iptables -F EASYTIER_INPUT 2>/dev/null || :
        iptables -A EASYTIER_INPUT -j ACCEPT 2>/dev/null || log_msg "警告：无法设置 EasyTier INPUT 规则"
        iptables_rule_exists -C INPUT -i tun+ -j EASYTIER_INPUT ||
            iptables -I INPUT 1 -i tun+ -j EASYTIER_INPUT 2>/dev/null || log_msg "警告：无法连接 EasyTier INPUT 链"
    fi

    legacy_forward_in=0
    legacy_forward_out=0
    iptables_rule_exists -C FORWARD -i br0 -o tun+ -j ACCEPT && legacy_forward_in=1
    iptables_rule_exists -C FORWARD -i tun+ -o br0 -j ACCEPT && legacy_forward_out=1
    if [ "$legacy_forward_in" = 1 ] && [ "$legacy_forward_out" = 1 ]; then
        log_msg "检测到旧版 FORWARD 规则，保留且避免重复添加"
    else
        iptables -N EASYTIER_FORWARD 2>/dev/null || :
        iptables -F EASYTIER_FORWARD 2>/dev/null || :
        [ "$legacy_forward_in" = 1 ] ||
            iptables -A EASYTIER_FORWARD -i br0 -o tun+ -j ACCEPT 2>/dev/null || log_msg "警告：无法设置 EasyTier 转发规则"
        [ "$legacy_forward_out" = 1 ] ||
            iptables -A EASYTIER_FORWARD -i tun+ -o br0 -j ACCEPT 2>/dev/null || log_msg "警告：无法设置 EasyTier 转发规则"
        iptables_rule_exists -C FORWARD -j EASYTIER_FORWARD ||
            iptables -I FORWARD 1 -j EASYTIER_FORWARD 2>/dev/null || log_msg "警告：无法连接 EasyTier FORWARD 链"
    fi

    if iptables_rule_exists -t nat -C POSTROUTING -o tun+ -j MASQUERADE; then
        log_msg "检测到旧版 NAT 规则，保留且避免重复添加"
    else
        iptables -t nat -N EASYTIER_NAT 2>/dev/null || :
        iptables -t nat -F EASYTIER_NAT 2>/dev/null || :
        iptables -t nat -A EASYTIER_NAT -o tun+ -j MASQUERADE 2>/dev/null || log_msg "警告：无法设置 EasyTier NAT 规则"
        iptables_rule_exists -t nat -C POSTROUTING -j EASYTIER_NAT ||
            iptables -t nat -I POSTROUTING 1 -j EASYTIER_NAT 2>/dev/null || log_msg "警告：无法连接 EasyTier NAT 链"
    fi
}

remove_jump_references() {
    table=$1
    parent=$2
    target=$3
    if [ "$table" = nat ]; then
        while iptables -t nat -C "$parent" -j "$target" >/dev/null 2>&1; do
            iptables -t nat -D "$parent" -j "$target" >/dev/null 2>&1 || break
        done
    else
        while iptables -C "$parent" -j "$target" >/dev/null 2>&1; do
            iptables -D "$parent" -j "$target" >/dev/null 2>&1 || break
        done
    fi
}

remove_firewall_rules() {
    # Delete only references to our uniquely named chains, then delete those chains.
    remove_jump_references filter INPUT EASYTIER_INPUT
    while iptables -C INPUT -i tun+ -j EASYTIER_INPUT >/dev/null 2>&1; do
        iptables -D INPUT -i tun+ -j EASYTIER_INPUT >/dev/null 2>&1 || break
    done
    remove_jump_references filter FORWARD EASYTIER_FORWARD
    remove_jump_references nat POSTROUTING EASYTIER_NAT
    iptables -F EASYTIER_INPUT 2>/dev/null || :
    iptables -X EASYTIER_INPUT 2>/dev/null || :
    iptables -F EASYTIER_FORWARD 2>/dev/null || :
    iptables -X EASYTIER_FORWARD 2>/dev/null || :
    iptables -t nat -F EASYTIER_NAT 2>/dev/null || :
    iptables -t nat -X EASYTIER_NAT 2>/dev/null || :
}

start_service() {
    if pid=$(managed_pid); then
        log_msg "EasyTier 已在运行（PID $pid）"
        return 0
    fi
    if [ ! -s "$CONFIG_FILE" ]; then
        log_msg "启动失败：配置文件不存在或为空：$CONFIG_FILE"
        return 1
    fi
    if [ ! -x "$EASYTIER_BIN" ]; then
        log_msg "启动失败：核心文件不存在或不可执行：$EASYTIER_BIN"
        return 1
    fi

    mkdir -p "$LOG_DIR" "$(dirname "$PID_FILE")" 2>/dev/null || {
        log_msg "启动失败：无法创建运行目录"
        return 1
    }
    modprobe tun >/dev/null 2>&1 || runtime_msg "提示：modprobe tun 未成功，继续尝试启动"

    cd "$TMP_DIR" 2>/dev/null || :
    nohup "$EASYTIER_BIN" -c "$CONFIG_FILE" >> "$RUNTIME_LOG" 2>&1 </dev/null &
    child=$!
    printf '%s\n' "$child" > "$PID_FILE" || {
        kill "$child" 2>/dev/null || :
        log_msg "启动失败：无法写入 PID 文件"
        return 1
    }

    waited=0
    while [ "$waited" -lt "$START_WAIT" ]; do
        pid_matches_plugin "$child" && break
        pid_is_alive "$child" || break
        sleep 1
        waited=$((waited + 1))
    done
    if pid_matches_plugin "$child"; then
        add_firewall_rules
        log_msg "EasyTier 启动成功（PID $child）"
        return 0
    fi

    if pid_is_alive "$child"; then
        log_msg "启动失败：无法核实新进程与插件核心参数的对应关系；未向该进程发送信号"
        return 1
    fi
    wait "$child"
    child_status=$?
    rm -f "$PID_FILE"
    log_msg "启动失败：核心进程退出，退出码 $child_status；请查看 $RUNTIME_LOG"
    return 1
}

stop_service() {
    if ! pid=$(managed_pid); then
        log_msg "EasyTier 已停止"
        remove_firewall_rules
        return 0
    fi
    log_msg "正在停止 EasyTier（PID $pid）"
    kill -TERM "$pid" 2>/dev/null || :
    waited=0
    while [ "$waited" -lt "$STOP_WAIT" ]; do
        pid_matches_plugin "$pid" || break
        sleep 1
        waited=$((waited + 1))
    done
    if pid_matches_plugin "$pid"; then
        log_msg "EasyTier 未响应 TERM，发送 KILL（PID $pid）"
        kill -KILL "$pid" 2>/dev/null || :
        sleep 1
    fi
    if pid_matches_plugin "$pid"; then
        log_msg "停止失败：进程仍在运行（PID $pid）"
        return 1
    fi
    current=
    if [ -r "$PID_FILE" ]; then
        IFS= read -r current < "$PID_FILE" || :
    fi
    [ "$current" = "$pid" ] && rm -f "$PID_FILE"
    remove_firewall_rules
    log_msg "EasyTier 已停止"
    return 0
}

network_ready() {
    if ip -4 route show default 2>/dev/null | grep -q 'default'; then
        return 0
    fi
    if ip -4 addr show 2>/dev/null |
        awk '/inet / && $2 !~ /^127\./ { found=1 } END { exit !found }'; then
        return 0
    fi
    ip addr show 2>/dev/null |
        awk '/inet / && $2 !~ /^127\./ { found=1 } END { exit !found }'
}

autostart_enabled() {
    [ "$(dbus get easytier_autostart 2>/dev/null)" = 1 ]
}

autostart_service() {
    autostart_enabled || {
        log_msg "自启动已关闭，跳过启动"
        return 0
    }

    mkdir -p "$(dirname "$AUTO_LOCK_DIR")" 2>/dev/null || return 1
    lock_try=0
    while [ "$lock_try" -lt 3 ]; do
        if mkdir "$AUTO_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$AUTO_LOCK_DIR/pid" || {
                rmdir "$AUTO_LOCK_DIR" 2>/dev/null || :
                log_msg "自启动失败：无法写入互斥锁"
                return 1
            }
            break
        fi
        owner=
        if [ -r "$AUTO_LOCK_DIR/pid" ]; then
            IFS= read -r owner < "$AUTO_LOCK_DIR/pid" || :
        fi
        if valid_pid "$owner" && pid_is_alive "$owner"; then
            log_msg "已有自启动检查任务，跳过重复事件"
            return 0
        fi
        if [ "$lock_try" -ge 1 ]; then
            rm -f "$AUTO_LOCK_DIR/pid" 2>/dev/null || :
            rmdir "$AUTO_LOCK_DIR" 2>/dev/null || :
        fi
        lock_try=$((lock_try + 1))
        sleep 1
    done
    if [ ! -r "$AUTO_LOCK_DIR/pid" ] || [ "$(cat "$AUTO_LOCK_DIR/pid" 2>/dev/null)" != "$$" ]; then
        log_msg "自启动失败：无法取得互斥锁"
        return 1
    fi

    result=1
    attempt=0
    while [ "$attempt" -le "$AUTO_RETRIES" ]; do
        if ! autostart_enabled; then
            log_msg "等待网络期间自启动被关闭，取消启动"
            result=0
            break
        fi
        if network_ready; then
            if acquire_lock; then
                start_service
                result=$?
                release_lock
            else
                log_msg "自启动失败：等待服务互斥锁超时"
                result=1
            fi
            break
        fi
        [ "$attempt" -ge "$AUTO_RETRIES" ] && break
        sleep "$AUTO_DELAY"
        attempt=$((attempt + 1))
    done
    [ "$result" -eq 0 ] || log_msg "自启动失败：IPv4 网络在有限重试后仍未就绪或服务启动失败"
    rm -f "$AUTO_LOCK_DIR/pid"
    rmdir "$AUTO_LOCK_DIR" 2>/dev/null || :
    return "$result"
}

restore_dbus_value() {
    restore_key=$1
    restore_value=$2
    if [ -n "$restore_value" ]; then
        dbus set "$restore_key=$restore_value"
    else
        dbus remove "$restore_key"
    fi
}

save_config() {
    encoded=${easytier_config_content_encoded:-}
    if [ -z "$encoded" ]; then
        log_msg "配置保存失败：表单配置为空"
        return 1
    fi
    case "${easytier_autostart:-}" in
        ''|0|1) ;;
        *) log_msg "配置保存失败：自启动值必须是 0 或 1"; return 1 ;;
    esac
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || {
        log_msg "配置保存失败：无法创建配置目录"
        return 1
    }
    tmpfile=$CONFIG_FILE.tmp.$$
    if ! printf '%s' "$encoded" | base64 -d > "$tmpfile" 2>/dev/null || [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        log_msg "配置保存失败：Base64 内容无效或为空"
        return 1
    fi
    chmod 600 "$tmpfile" || {
        rm -f "$tmpfile"
        log_msg "配置保存失败：无法设置权限"
        return 1
    }

    old_encoded=$(dbus get easytier_config_content_encoded 2>/dev/null)
    old_autostart=$(dbus get easytier_autostart 2>/dev/null)
    if ! dbus set easytier_config_content_encoded="$encoded"; then
        rm -f "$tmpfile"
        restore_dbus_value easytier_config_content_encoded "$old_encoded" 2>/dev/null ||
            log_msg "警告：无法恢复原有 DBUS 配置"
        log_msg "配置保存失败：无法写入 DBUS 配置"
        return 1
    fi

    case "${easytier_autostart:-}" in
        0|1)
            if ! dbus set easytier_autostart="$easytier_autostart"; then
                restore_dbus_value easytier_config_content_encoded "$old_encoded" 2>/dev/null ||
                    log_msg "警告：无法恢复原有 DBUS 配置"
                restore_dbus_value easytier_autostart "$old_autostart" 2>/dev/null ||
                    log_msg "警告：无法恢复原有自启动设置"
                rm -f "$tmpfile"
                log_msg "配置保存失败：无法写入自启动设置"
                return 1
            fi
            ;;
    esac

    if ! mv "$tmpfile" "$CONFIG_FILE"; then
        restore_dbus_value easytier_config_content_encoded "$old_encoded" 2>/dev/null ||
            log_msg "警告：无法恢复原有 DBUS 配置"
        case "${easytier_autostart:-}" in
            0|1)
                restore_dbus_value easytier_autostart "$old_autostart" 2>/dev/null ||
                    log_msg "警告：无法恢复原有自启动设置"
                ;;
        esac
        rm -f "$tmpfile"
        log_msg "配置保存失败：无法原子替换配置文件"
        return 1
    fi

    log_msg "配置文件已保存"
    return 0
}

save_autostart() {
    case "${easytier_autostart:-}" in
        0|1)
            if [ "$easytier_autostart" = 1 ] && [ ! -s "$CONFIG_FILE" ]; then
                log_msg "自启动设置保存失败：请先保存非空配置文件"
                return 1
            fi
            dbus set easytier_autostart="$easytier_autostart" || {
                log_msg "自启动设置保存失败"
                return 1
            }
            log_msg "自启动设置已保存"
            return 0
            ;;
        *)
            log_msg "自启动设置保存失败：值必须是 0 或 1"
            return 1
            ;;
    esac
}

dispatch() {
    case "$OPERATION" in
        status)
            if pid=$(managed_pid); then
                if [ "$WEB_SUBMIT" = 1 ] && command -v http_response >/dev/null 2>&1; then
                    http_response "运行"
                else
                    printf '运行\n'
                fi
            else
                if [ "$WEB_SUBMIT" = 1 ] && command -v http_response >/dev/null 2>&1; then
                    http_response "停止"
                else
                    printf '停止\n'
                fi
            fi
            return 0
            ;;
        start)
            acquire_lock || {
                log_msg "启动失败：等待互斥锁超时"
                return 1
            }
            start_service
            result=$?
            release_lock
            return "$result"
            ;;
        stop)
            acquire_lock || {
                log_msg "停止失败：等待互斥锁超时"
                return 1
            }
            stop_service
            result=$?
            release_lock
            return "$result"
            ;;
        restart)
            acquire_lock || {
                log_msg "重启失败：等待互斥锁超时"
                return 1
            }
            stop_service
            result=$?
            if [ "$result" -eq 0 ]; then
                start_service
                result=$?
            fi
            release_lock
            return "$result"
            ;;
        save_config)
            save_config
            ;;
        save_autostart)
            save_autostart
            ;;
        clear_runtime_log)
            : > "$RUNTIME_LOG" 2>/dev/null || {
                log_msg "运行日志清空失败"
                return 1
            }
            log_msg "运行日志已清空"
            ;;
        autostart)
            autostart_service
            ;;
        *)
            printf 'Usage: %s {start|stop|restart|status}\n' "$0" >&2
            return 2
            ;;
    esac
}

if [ "$WEB_SUBMIT" = 1 ]; then
    if command -v http_response >/dev/null 2>&1; then
        http_response "success"
    fi
    (
        : > "$LOG_FILE" 2>/dev/null || :
        log_msg "========= EasyTier Web 任务 ========="
        case "$OPERATION" in
            start|restart)
                save_config
                result=$?
                ;;
            *)
                result=0
                ;;
        esac
        if [ "$result" -eq 0 ]; then
            dispatch
            result=$?
        fi
        [ "$result" -eq 0 ] || log_msg "Web 操作失败，退出码：$result"
        log_msg "Web 操作完成"
        printf '%s\n' XU6J03M6 >> "$LOG_FILE"
    ) >/dev/null 2>&1 </dev/null &
    exit 0
fi

[ -n "$OPERATION" ] || {
    printf 'Usage: %s {start|stop|restart|status}\n' "$0" >&2
    exit 2
}
if [ "$WEB_SUBMIT" != 1 ]; then
    case "$OPERATION" in
        save_config|save_autostart|clear_runtime_log)
            printf 'Web-only operation: %s\n' "$OPERATION" >&2
            exit 2
            ;;
    esac
fi
dispatch
exit $?
