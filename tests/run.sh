#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
MOCK_BIN=$TMP/mockbin
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/dbus" <<'MOCK'
#!/bin/sh
: "${DBUS_STATE:?}"
: "${DBUS_LOG:?}"
printf '%s\n' "$*" >> "$DBUS_LOG"
cmd=$1
shift || :
case "$cmd" in
    get)
        key=$1
        sed -n "s/^$key=//p" "$DBUS_STATE" | tail -n 1
        ;;
    set)
        pair=$1
        key=${pair%%=*}
        value=${pair#*=}
        tmp=$DBUS_STATE.tmp.$$
        awk -F= -v key="$key" '$1 != key {print}' "$DBUS_STATE" > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
        mv "$tmp" "$DBUS_STATE"
        ;;
    remove)
        key=$1
        tmp=$DBUS_STATE.tmp.$$
        awk -F= -v key="$key" '$1 != key {print}' "$DBUS_STATE" > "$tmp"
        mv "$tmp" "$DBUS_STATE"
        ;;
    export) : ;;
    *) exit 2 ;;
esac
MOCK
cat > "$MOCK_BIN/ip" <<'MOCK'
#!/bin/sh
if [ "${IPV4_READY:-0}" = 1 ]; then
    case "$*" in
        *"route show default"*) echo 'default via 192.0.2.1 dev eth0' ;;
        *"addr show"*) echo '    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0' ;;
    esac
fi
exit 0
MOCK
cat > "$MOCK_BIN/iptables" <<'MOCK'
#!/bin/sh
state=${IPTABLES_STATE:?}
table=filter
if [ "$1" = -t ]; then table=$2; shift 2; fi
op=$1
shift
case "$op" in
    -N|-X) exit 0 ;;
    -F)
        chain=$1
        tmp=$state.tmp.$$
        awk -F'|' -v table="$table" -v chain="$chain" '!(($1 == table) && ($2 == chain))' "$state" > "$tmp"
        mv "$tmp" "$state"
        exit 0
        ;;
    -C|-A|-I|-D)
        chain=$1
        shift
        if [ "$op" = -I ]; then
            case "${1:-}" in
                ''|*[!0-9]*) ;;
                *) shift ;;
            esac
        fi
        rule=$*
        key="$table|$chain|$rule"
        case "$op" in
            -C)
                grep -Fqx "$key" "$state"
                exit $?
                ;;
            -A|-I)
                printf '%s\n' "$key" >> "$state"
                exit 0
                ;;
            -D)
                tmp=$state.tmp.$$
                awk -v key="$key" 'BEGIN {deleted=0} $0 == key && !deleted {deleted=1; next} {print}' "$state" > "$tmp"
                mv "$tmp" "$state"
                exit 0
                ;;
        esac
        ;;
esac
exit 0
MOCK
cat > "$MOCK_BIN/modprobe" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat > "$MOCK_BIN/sleep" <<'MOCK'
#!/bin/sh
if [ "${MOCK_SLEEP_ZERO:-0}" = 1 ]; then exit 0; fi
exec /bin/sleep "$@"
MOCK
cat > "$MOCK_BIN/nvram" <<'MOCK'
#!/bin/sh
if [ "$1" = get ] && [ "$2" = lan_ipaddr ]; then
    printf '%s\n' 192.0.2.1
    exit 0
fi
exit 1
MOCK
chmod 755 "$MOCK_BIN/"*
if command -v busybox >/dev/null 2>&1; then
    cat > "$MOCK_BIN/sh" <<'MOCK'
#!/bin/sh
exec busybox ash "$@"
MOCK
    chmod 755 "$MOCK_BIN/sh"
fi

export PATH="$MOCK_BIN:$PATH"
export DBUS_LOG="$TMP/dbus.log"
export IPTABLES_STATE="$TMP/iptables.rules"
: > "$IPTABLES_STATE"
: > "$DBUS_LOG"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_file() {
    path=$1
    tries=0
    while [ "$tries" -lt 40 ]; do
        [ -e "$path" ] && return 0
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

plugin_process_count() {
    count=0
    for cmdfile in /proc/[0-9]*/cmdline; do
        [ -r "$cmdfile" ] || continue
        cmdline=$(tr '\000' ' ' < "$cmdfile" 2>/dev/null || :)
        case " $cmdline " in
            *" $SERVICE_ROOT/bin/easytier-core -c $SERVICE_ROOT/configs/easytier.conf "*) count=$((count + 1)) ;;
        esac
    done
    printf '%s\n' "$count"
}

# Exercise nvram/dbus/ip/iptables mocks without reading real device data.
[ "$(nvram get lan_ipaddr)" = 192.0.2.1 ] || fail "nvram mock"
export DBUS_STATE="$TMP/dbus.values"
printf '%s\n' 'easytier_autostart=0' > "$DBUS_STATE"
[ "$(dbus get easytier_autostart)" = 0 ] || fail "dbus mock"
IPV4_READY=1 ip -4 route show default | grep -q '^default ' || fail "IPv4 route mock"

# Lifecycle tests use an inert shell stand-in, never an ARM EasyTier binary.
SERVICE_ROOT=$TMP/service-root
RUN_DIR=$TMP/service-run
LOG_DIR=$TMP/service-log
mkdir -p "$SERVICE_ROOT/bin" "$SERVICE_ROOT/configs" "$SERVICE_ROOT/scripts" "$RUN_DIR" "$LOG_DIR"
printf '%s\n' 'keep-this-config' > "$SERVICE_ROOT/configs/easytier.conf"
cat > "$SERVICE_ROOT/bin/easytier-core" <<'CORE'
#!/bin/sh
trap 'exit 0' TERM
while :; do /bin/sleep 1; done
CORE
chmod 755 "$SERVICE_ROOT/bin/easytier-core"
cat > "$SERVICE_ROOT/scripts/base.sh" <<'BASE'
http_response() {
    printf '%s\n' "$1" > "$HTTP_RESPONSE_FILE"
}
echo_date() {
    printf '[test] %s\n' "$*"
}
BASE

export EASYTIER_KS_DIR="$SERVICE_ROOT"
export EASYTIER_RUN_DIR="$RUN_DIR"
export EASYTIER_TMP_DIR="$TMP"
export EASYTIER_LOG_DIR="$LOG_DIR"
export EASYTIER_PROC_ROOT=/proc
export EASYTIER_START_WAIT=1
export EASYTIER_STOP_WAIT=3
export EASYTIER_AUTO_RETRIES=2
export EASYTIER_AUTO_DELAY=0
export EASYTIER_LOCK_ATTEMPTS=10
export EASYTIER_LOCK_DIR="$RUN_DIR/easytier.lock"
export EASYTIER_AUTO_LOCK_DIR="$RUN_DIR/easytier-autostart.lock"
export EASYTIER_CONFIG_FILE="$SERVICE_ROOT/configs/easytier.conf"
export EASYTIER_PID_FILE="$RUN_DIR/easytier.pid"
SERVICE=$ROOT/scripts/easytier_config.sh
config_before=$(cat "$EASYTIER_CONFIG_FILE")
printf '%s\n' 'easytier_autostart=0' 'easytier_config_content_encoded=KEEP_DBUS' 'easytier_network_name=KEEP_NAME' 'easytier_network_secret=KEEP_SECRET' > "$DBUS_STATE"
cp "$DBUS_STATE" "$TMP/dbus.before"

# A PID file for an unrelated process must never authorize a signal.
/bin/sleep 30 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$EASYTIER_PID_FILE"
sh "$SERVICE" stop || fail "stop with unrelated stale PID"
kill -0 "$unrelated_pid" 2>/dev/null || fail "unrelated process was signaled"
kill "$unrelated_pid" 2>/dev/null || :
grep -Fx 'easytier.pid' "$DBUS_LOG" >/dev/null 2>&1 && fail "unexpected DBUS write"

# Failed starts return non-zero and preserve their diagnostic, including the child exit code.
cp "$SERVICE_ROOT/bin/easytier-core" "$TMP/live-core"
: > "$EASYTIER_CONFIG_FILE"
if sh "$SERVICE" start; then fail "start without config should fail"; fi
grep -F '配置文件不存在或为空' "$LOG_DIR/easytier_log.txt" >/dev/null ||
    fail "missing-config failure was not logged"
printf '%s\n' 'keep-this-config' > "$EASYTIER_CONFIG_FILE"
cat > "$SERVICE_ROOT/bin/easytier-core" <<'CORE'
#!/bin/sh
exit 23
CORE
chmod 755 "$SERVICE_ROOT/bin/easytier-core"
if sh "$SERVICE" start; then fail "early core exit should fail start"; fi
grep -F '退出码 23' "$LOG_DIR/easytier_log.txt" >/dev/null ||
    fail "early core exit status was not logged"
cp "$TMP/live-core" "$SERVICE_ROOT/bin/easytier-core"
chmod 755 "$SERVICE_ROOT/bin/easytier-core"

# A stale PID is discarded; CLI start does not save or rewrite config/DBUS.
printf '%s\n' 999999999 > "$EASYTIER_PID_FILE"
sh "$SERVICE" start || fail "CLI start"
pid=$(cat "$EASYTIER_PID_FILE")
[ "$pid" != 999999999 ] || fail "stale PID was retained"
[ "$(sh "$SERVICE" status)" = 运行 ] || fail "status after start"
[ "$(cat "$EASYTIER_CONFIG_FILE")" = "$config_before" ] || fail "CLI start changed config"
cmp -s "$DBUS_STATE" "$TMP/dbus.before" || fail "CLI start changed DBUS configuration"
if easytier_config_content_encoded=Tk9UX1dSSVRURU4= sh "$SERVICE" save_config; then
    fail "CLI save_config should be rejected as a Web-only operation"
fi
[ "$(cat "$EASYTIER_CONFIG_FILE")" = "$config_before" ] || fail "CLI save_config changed config"
cmp -s "$DBUS_STATE" "$TMP/dbus.before" || fail "CLI save_config changed DBUS configuration"
iptables_count=$(grep -Fxc 'filter|INPUT|-i tun+ -j EASYTIER_INPUT' "$IPTABLES_STATE" || :)
[ "$iptables_count" = 1 ] || fail "plugin INPUT firewall rule not added once"

# Repeated and simultaneous starts are idempotent.
sh "$SERVICE" start || fail "repeated start"
pid_after=$(cat "$EASYTIER_PID_FILE")
[ "$pid_after" = "$pid" ] || fail "repeated start changed managed PID"
sh "$SERVICE" start &
start_one=$!
sh "$SERVICE" start &
start_two=$!
wait "$start_one" || fail "concurrent start one"
wait "$start_two" || fail "concurrent start two"
[ "$(cat "$EASYTIER_PID_FILE")" = "$pid" ] || fail "concurrent start created another PID"
[ "$(grep -Fxc 'filter|INPUT|-i tun+ -j EASYTIER_INPUT' "$IPTABLES_STATE" || :)" = 1 ] ||
    fail "repeated starts duplicated firewall rule"

# Restart and stop are safe to repeat.
sh "$SERVICE" restart || fail "restart"
pid=$(cat "$EASYTIER_PID_FILE")
[ "$(sh "$SERVICE" status)" = 运行 ] || fail "status after restart"
sh "$SERVICE" stop || fail "stop"
if grep -F '发送 KILL' "$LOG_DIR/easytier_log.txt" >/dev/null; then
    fail "graceful TERM stop unnecessarily escalated to KILL"
fi
sh "$SERVICE" stop || fail "idempotent stop"
[ "$(sh "$SERVICE" status)" = 停止 ] || fail "status after stop"
[ ! -e "$EASYTIER_PID_FILE" ] || fail "PID file left after stop"

# Autostart off and an IPv4-not-ready condition both prevent startup.
printf '%s\n' 'easytier_autostart=0' > "$DBUS_STATE"
MOCK_SLEEP_ZERO=1 sh "$SERVICE" autostart || fail "autostart off must be a successful skip"
[ ! -e "$EASYTIER_PID_FILE" ] || fail "autostart=0 started the service"
printf '%s\n' 'easytier_autostart=1' > "$DBUS_STATE"
IPV4_READY=0 MOCK_SLEEP_ZERO=1
export IPV4_READY MOCK_SLEEP_ZERO
if sh "$SERVICE" autostart; then fail "autostart should fail after bounded IPv4 retries"; fi
[ ! -e "$EASYTIER_PID_FILE" ] || fail "service started without IPv4 readiness"
grep -F '有限重试' "$LOG_DIR/easytier_log.txt" >/dev/null || fail "retry failure was not logged"

# A v4 route is enough; no IPv6 route is provided by the mock.
IPV4_READY=1
MOCK_SLEEP_ZERO=0
export IPV4_READY MOCK_SLEEP_ZERO
sh "$SERVICE" autostart || fail "IPv4-only autostart"
[ "$(sh "$SERVICE" status)" = 运行 ] || fail "IPv4-only network was blocked"
sh "$SERVICE" stop || fail "stop after autostart"

# Check V/S/N dispatch and asynchronous duplicate-event handling.
export EASYTIER_CONFIG_SCRIPT="$SERVICE"
printf '%s\n' 'easytier_autostart=0' > "$DBUS_STATE"
sh "$ROOT/init.d/V99easytier.sh" services-start
/bin/sleep 0.2
[ ! -e "$EASYTIER_PID_FILE" ] || fail "V event ignored autostart=0"
printf '%s\n' 'easytier_autostart=1' > "$DBUS_STATE"
sh "$ROOT/init.d/V99easytier.sh" services-start &
event_v=$!
sh "$ROOT/init.d/S99easytier.sh" wan-start &
event_s=$!
sh "$SERVICE" start &
manual_start=$!
wait "$event_v" || fail "V event handler"
wait "$event_s" || fail "S event handler"
wait "$manual_start" || fail "concurrent manual start"
wait_for_file "$EASYTIER_PID_FILE" || fail "V/S event did not start service"
/bin/sleep 0.5
[ "$(plugin_process_count)" = 1 ] || fail "manual and boot starts launched duplicate cores"
pid=$(cat "$EASYTIER_PID_FILE")
sh "$ROOT/init.d/N99easytier.sh" start_nat || fail "N event handler"
sh "$ROOT/init.d/S99easytier.sh" stop || fail "S unknown/stop event handling"
sh "$ROOT/init.d/V99easytier.sh" nat-start || fail "V unknown event handling"
[ "$(cat "$EASYTIER_PID_FILE")" = "$pid" ] || fail "N/S event stopped or duplicated EasyTier"
sh "$SERVICE" stop || fail "stop after event tests"

# Legacy untagged firewall rules are preserved and not duplicated or deleted.
cat > "$IPTABLES_STATE" <<'RULES'
filter|INPUT|-i tun+ -j ACCEPT
filter|FORWARD|-i br0 -o tun+ -j ACCEPT
filter|FORWARD|-i tun+ -o br0 -j ACCEPT
nat|POSTROUTING|-o tun+ -j MASQUERADE
RULES
sh "$SERVICE" start || fail "start with legacy firewall rules"
[ "$(grep -Fxc 'filter|INPUT|-i tun+ -j ACCEPT' "$IPTABLES_STATE" || :)" = 1 ] ||
    fail "legacy INPUT rule was duplicated"
[ "$(grep -Fxc 'filter|FORWARD|-i br0 -o tun+ -j ACCEPT' "$IPTABLES_STATE" || :)" = 1 ] ||
    fail "legacy FORWARD rule was duplicated"
[ "$(grep -Fxc 'nat|POSTROUTING|-o tun+ -j MASQUERADE' "$IPTABLES_STATE" || :)" = 1 ] ||
    fail "legacy NAT rule was duplicated"
sh "$SERVICE" stop || fail "stop with legacy firewall rules"
[ "$(grep -Fxc 'filter|INPUT|-i tun+ -j ACCEPT' "$IPTABLES_STATE" || :)" = 1 ] ||
    fail "stop deleted an unowned legacy INPUT rule"

# Web submissions still answer immediately, save config, and write the log terminator.
export HTTP_RESPONSE_FILE="$TMP/http-response"
encoded=$(printf '%s' 'web-config' | base64 | tr -d '\n')
easytier_config_content_encoded=$encoded easytier_autostart=0 sh "$SERVICE" save_config web_submit
[ "$(cat "$HTTP_RESPONSE_FILE")" = success ] || fail "web submit did not respond immediately"
wait_for_file "$LOG_DIR/easytier_log.txt" || fail "web log was not created"
tries=0
while ! grep -q XU6J03M6 "$LOG_DIR/easytier_log.txt"; do
    [ "$tries" -lt 40 ] || fail "web async log terminator"
    /bin/sleep 0.1
    tries=$((tries + 1))
done
[ "$(cat "$EASYTIER_CONFIG_FILE")" = web-config ] || fail "web config was not saved"
[ "$(dbus get easytier_config_content_encoded)" = "$encoded" ] || fail "web DBUS config was not saved"
[ "$(dbus get easytier_autostart)" = 0 ] || fail "web autostart setting was not saved"

# Build mock-core packages and verify upgrade preservation, ARMv7 selection, rollback and uninstall.
make -C "$ROOT" test-package >/dev/null
sh "$ROOT/scripts/check_package.sh" >/dev/null
PKG_STAGE=$TMP/package-stage
mkdir -p "$PKG_STAGE"
tar -xzf "$ROOT/easytier_hnd.tar.gz" -C "$PKG_STAGE"
PKG=$PKG_STAGE/easytier

UPGRADE_ROOT=$TMP/upgrade-root
mkdir -p "$UPGRADE_ROOT/bin" "$UPGRADE_ROOT/configs" "$UPGRADE_ROOT/scripts"
printf '%s\n' 'current-device-core-do-not-replace' > "$UPGRADE_ROOT/bin/easytier-core"
chmod 755 "$UPGRADE_ROOT/bin/easytier-core"
printf '%s\n' 'current-user-config-do-not-replace' > "$UPGRADE_ROOT/configs/easytier.conf"
printf '%s\n' 'OLD_PLUGIN_SCRIPT' > "$UPGRADE_ROOT/scripts/easytier_config.sh"
printf '%s\n' 'easytier_autostart=1' 'easytier_network_name=KEEP_NAME' 'easytier_network_secret=KEEP_SECRET' 'easytier_config_content_encoded=KEEP_CONFIG' > "$TMP/install-dbus"
export DBUS_STATE="$TMP/install-dbus"
export DBUS_LOG="$TMP/install-dbus.log"
: > "$DBUS_LOG"
KS_DIR="$UPGRADE_ROOT" EASYTIER_TEST_ARCH=armv7l EASYTIER_TMP_ROOT="$TMP/install-tmp" \
    sh "$PKG/install.sh" > "$TMP/upgrade-output" || fail "upgrade install"
[ "$(cat "$UPGRADE_ROOT/bin/easytier-core")" = current-device-core-do-not-replace ] || fail "upgrade replaced existing core"
[ "$(cat "$UPGRADE_ROOT/configs/easytier.conf")" = current-user-config-do-not-replace ] || fail "upgrade replaced config"
[ "$(dbus get easytier_autostart)" = 1 ] || fail "upgrade changed autostart DBUS"
[ "$(dbus get easytier_network_name)" = KEEP_NAME ] || fail "upgrade changed network name"
[ "$(dbus get easytier_network_secret)" = KEEP_SECRET ] || fail "upgrade changed secret"
[ "$(dbus get easytier_config_content_encoded)" = KEEP_CONFIG ] || fail "upgrade changed DBUS config"
[ ! -e "$UPGRADE_ROOT/var/run/easytier.pid" ] || fail "install started/restarted service"
backup=$(find "$UPGRADE_ROOT/backup/easytier" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$backup" ] || fail "upgrade did not back up replaced scripts"
KS_DIR="$UPGRADE_ROOT" sh "$UPGRADE_ROOT/scripts/easytier_rollback.sh" >/dev/null ||
    fail "manual rollback"
[ "$(cat "$UPGRADE_ROOT/scripts/easytier_config.sh")" = OLD_PLUGIN_SCRIPT ] || fail "rollback did not restore script"
[ "$(cat "$UPGRADE_ROOT/bin/easytier-core")" = current-device-core-do-not-replace ] || fail "rollback changed core"
[ "$(cat "$UPGRADE_ROOT/configs/easytier.conf")" = current-user-config-do-not-replace ] || fail "rollback changed config"

# Automatic rollback selects the latest timestamped backup without non-POSIX test operators.
latest_backup=$UPGRADE_ROOT/backup/easytier/20990101000000-999999
mkdir -p "$latest_backup/scripts"
printf '%s\n' 'scripts/easytier_config.sh' > "$latest_backup/manifest"
printf '%s\n' 'LATEST_SCRIPT' > "$latest_backup/scripts/easytier_config.sh"
KS_DIR="$UPGRADE_ROOT" sh "$UPGRADE_ROOT/scripts/easytier_rollback.sh" >/dev/null ||
    fail "automatic rollback did not select a valid backup"
[ "$(cat "$UPGRADE_ROOT/scripts/easytier_config.sh")" = LATEST_SCRIPT ] ||
    fail "automatic rollback did not select the latest timestamped backup"

# A mid-install copy failure automatically restores scripts and releases its lock.
FAIL_ROOT=$TMP/fail-root
mkdir -p "$FAIL_ROOT/bin" "$FAIL_ROOT/configs" "$FAIL_ROOT/scripts" "$TMP/fail-mockbin" "$TMP/fail-tmp"
printf '%s\n' 'existing-core' > "$FAIL_ROOT/bin/easytier-core"
printf '%s\n' 'existing-config' > "$FAIL_ROOT/configs/easytier.conf"
printf '%s\n' 'EXISTING_SCRIPT' > "$FAIL_ROOT/scripts/easytier_config.sh"
cat > "$TMP/fail-mockbin/mv" <<'MOCK'
#!/bin/sh
case "$*" in
    *Module_easytier.asp.easytier-new*) exit 1 ;;
esac
exec /bin/mv "$@"
MOCK
chmod 755 "$TMP/fail-mockbin/mv"
if PATH="$TMP/fail-mockbin:$PATH" KS_DIR="$FAIL_ROOT" EASYTIER_TEST_ARCH=armv7l \
    EASYTIER_TMP_ROOT="$TMP/fail-tmp" sh "$PKG/install.sh" > "$TMP/fail-output" 2>&1; then
    fail "mid-install failure should fail the installer"
fi
[ "$(cat "$FAIL_ROOT/scripts/easytier_config.sh")" = EXISTING_SCRIPT ] ||
    fail "failed install did not restore the old service script"
[ "$(cat "$FAIL_ROOT/bin/easytier-core")" = existing-core ] ||
    fail "failed install changed the existing core"
[ "$(cat "$FAIL_ROOT/configs/easytier.conf")" = existing-config ] ||
    fail "failed install changed the existing config"
[ ! -e "$TMP/fail-tmp/easytier-install.lock" ] || fail "failed install left its lock behind"
grep -F '安装已回滚' "$TMP/fail-output" >/dev/null || fail "failed install did not explain rollback"

NEW_ROOT=$TMP/new-root
mkdir -p "$NEW_ROOT"
printf '%s\n' 'easytier_autostart=0' > "$TMP/new-dbus"
export DBUS_STATE="$TMP/new-dbus"
KS_DIR="$NEW_ROOT" EASYTIER_TEST_ARCH=armv7l EASYTIER_TMP_ROOT="$TMP/new-tmp" sh "$PKG/install.sh" >/dev/null ||
    fail "new installation"
cmp -s "$NEW_ROOT/bin/easytier-core" "$PKG/bin/easytier-core_arm32" ||
    fail "RT-AX56U armv7l did not select ARMv7 core"
[ "$(cat "$NEW_ROOT/configs/easytier.conf" 2>/dev/null || :)" != "unexpected" ] || fail "new install config state"
[ "$(dbus get easytier_autostart)" = 0 ] || fail "new install changed autostart DBUS"

# Uninstall leaves the core, user config and EasyTier DBUS values untouched.
printf '%s\n' 'new-user-config' > "$NEW_ROOT/configs/easytier.conf"
cp "$NEW_ROOT/bin/easytier-core" "$TMP/new-core-before"
KS_DIR="$NEW_ROOT" EASYTIER_KS_DIR="$NEW_ROOT" EASYTIER_CONFIG_SCRIPT="$NEW_ROOT/scripts/easytier_config.sh" \
    EASYTIER_CONFIG_FILE="$NEW_ROOT/configs/easytier.conf" EASYTIER_BIN="$NEW_ROOT/bin/easytier-core" \
    EASYTIER_PID_FILE="$TMP/new-run/easytier.pid" EASYTIER_RUN_DIR="$TMP/new-run" \
    EASYTIER_LOCK_DIR="$TMP/new-run/easytier.lock" EASYTIER_AUTO_LOCK_DIR="$TMP/new-run/easytier-autostart.lock" \
    EASYTIER_LOG_DIR="$TMP/new-log" EASYTIER_TMP_DIR="$TMP" \
    sh "$NEW_ROOT/scripts/uninstall_easytier.sh" >/dev/null ||
    fail "uninstall"
cmp -s "$NEW_ROOT/bin/easytier-core" "$TMP/new-core-before" || fail "uninstall removed core"
[ "$(cat "$NEW_ROOT/configs/easytier.conf")" = new-user-config ] || fail "uninstall removed config"
[ "$(dbus get easytier_autostart)" = 0 ] || fail "uninstall removed autostart setting"
[ ! -e "$NEW_ROOT/scripts/easytier_config.sh" ] || fail "uninstall kept lifecycle script"
[ ! -e "$NEW_ROOT/init.d/V99easytier.sh" ] || fail "uninstall kept boot hook"

echo "All lifecycle, event, upgrade, rollback, uninstall and mock-environment tests passed."
