#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/helpers.sh"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/apipv6-lifecycle-test.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
SOURCE=$TEMP/source
SOURCE2=$TEMP/source-upgrade
KS=$TEMP/koolshare
mkdir -p "$SOURCE/scripts" "$SOURCE/webs" "$SOURCE/res" "$SOURCE/init.d" "$SOURCE2"
export PATH="$ROOT/tests/mocks:$PATH"
export MOCK_DBUS_FILE=$TEMP/dbus.values
export MOCK_SW_MODE=3
export MOCK_WLC_PSTA=0
export MOCK_IP_SCENARIO=good
export MOCK_IP_COUNTER_FILE=$TEMP/ip-count
export MOCK_CRU_LOG=$TEMP/cru.log
export MOCK_PING=success
export APIPV6_KS_DIR=$KS
export APIPV6_RUN_DIR=$KS/var/apipv6
export APIPV6_CONFIG_FILE=$KS/configs/apipv6.conf
export APIPV6_SYSCTL_ROOT=$TEMP/proc/sys/net/ipv6/conf
export APIPV6_TMP_ROOT=$TEMP/tmp
export APIPV6_TEST_NO_SLEEP=1
export APIPV6_RA_WAIT_SECONDS=5

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
copy_source() {
    dest=$1
    mkdir -p "$dest/scripts" "$dest/webs" "$dest/res" "$dest/init.d" "$dest/docs"
    cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/rollback.sh" "$ROOT/config.json.js" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$dest/"
    cp "$ROOT"/scripts/apipv6_config.sh "$ROOT"/scripts/apipv6_migrate.sh "$ROOT"/scripts/apipv6_status.sh "$ROOT"/scripts/apipv6_repair.sh "$dest/scripts/"
    cp "$ROOT/webs/Module_apipv6.asp" "$dest/webs/"
    cp "$ROOT/res/apipv6.png" "$dest/res/"
    cp "$ROOT/init.d/V99apipv6.sh" "$dest/init.d/"
    cp "$ROOT/docs/AX56U-ACCEPTANCE.md" "$dest/docs/"
    printf 'hnd\n' > "$dest/.valid"
}
install_from() {
    APIPV6_SOURCE_DIR=$1 sh "$1/install.sh"
}
read_hash() { test_hash "$1"; }

copy_source "$SOURCE"
mkdir -p "$KS/init.d" "$APIPV6_SYSCTL_ROOT/br0" "$APIPV6_SYSCTL_ROOT/eth0" "$APIPV6_SYSCTL_ROOT/all" "$TEMP/proc/sys/net/ipv4"

# Simulate KoolShare invoking the installer with a restricted PATH. Firmware
# ip/nvram and KoolShare dbus exist in their normal directories outside PATH.
NO_FIRMWARE_COMMANDS=$TEMP/mocks-without-ip-nvram-dbus
FIRMWARE_ONLY_PATH=$TEMP/firmware-only-path
FIRMWARE_SBIN=$TEMP/firmware/usr/sbin
make_path_without_firmware_commands "$NO_FIRMWARE_COMMANDS"
mkdir -p "$FIRMWARE_ONLY_PATH" "$FIRMWARE_SBIN" "$KS/bin"
cp "$ROOT/tests/mocks/nvram" "$FIRMWARE_SBIN/nvram"
cp "$ROOT/tests/mocks/ip" "$FIRMWARE_SBIN/ip"
cp "$ROOT/tests/mocks/dbus" "$KS/bin/dbus"
chmod 755 "$FIRMWARE_SBIN/nvram" "$FIRMWARE_SBIN/ip" "$KS/bin/dbus"
install_log=$(PATH="$FIRMWARE_ONLY_PATH" \
    APIPV6_SYSTEM_PATHS="$FIRMWARE_SBIN" \
    APIPV6_NVRAM_SEARCH_DIRS="$FIRMWARE_SBIN" \
    APIPV6_IP_SEARCH_DIRS="$FIRMWARE_SBIN" \
    APIPV6_SOURCE_DIR="$SOURCE" /bin/sh "$SOURCE/install.sh")
printf '%s\n' "$install_log" | grep -q 'AP 模式已通过 sw_mode=3、wlc_psta=0 检测' ||
    fail 'installer did not resolve nvram outside PATH and detect AP mode'
printf '%s\n' "$install_log" | grep -q 'AP IPv6 Manager v0.1.0 安装成功' ||
    fail 'installer did not resolve dbus from the KoolShare bin directory'
cat > "$KS/init.d/V00apipv6.sh" <<'EOF'
#!/bin/sh
echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/br0/autoconf
echo 2 > /proc/sys/net/ipv6/conf/br0/accept_ra
EOF
chmod 755 "$KS/init.d/V00apipv6.sh"
legacy_hash=$(read_hash "$KS/init.d/V00apipv6.sh")
printf '1\n' > "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6"
printf '0\n' > "$APIPV6_SYSCTL_ROOT/br0/autoconf"
printf '0\n' > "$APIPV6_SYSCTL_ROOT/br0/accept_ra"
printf '7\n' > "$APIPV6_SYSCTL_ROOT/eth0/disable_ipv6"
printf '55\n' > "$TEMP/proc/sys/net/ipv4/ip_forward"

install_from "$SOURCE" >/dev/null
[ -x "$KS/scripts/apipv6_config.sh" ] || fail 'installer did not install the CLI/API script'
[ -x "$KS/init.d/V99apipv6.sh" ] || fail 'installer did not install its boot hook'
[ -f "$KS/webs/Module_apipv6.asp" ] || fail 'installer did not install the Web page'
expect "$(dbus get apipv6_enabled)" 0 'automatic repair must default to off'
expect "$(dbus get apipv6_health_enabled)" 0 'periodic checks must default to off'
expect "$(read_hash "$KS/init.d/V00apipv6.sh")" "$legacy_hash" 'install must leave the old startup entry active until verification'
grep -q '^status=known_pending$' "$APIPV6_RUN_DIR/migration-state" || fail 'installer did not record known legacy state'

# Repeated install preserves user values and takes a new upgrade backup.
dbus set apipv6_enabled=1
dbus set apipv6_start_delay=77
install_from "$SOURCE" >/dev/null
expect "$(dbus get apipv6_enabled)" 1 'upgrade must preserve automatic repair setting'
expect "$(dbus get apipv6_start_delay)" 77 'upgrade must preserve start delay'

# A failure after files were copied restores overwritten files and DBUS values.
copy_source "$SOURCE2"
printf '\n# upgrade marker\n' >> "$SOURCE2/scripts/apipv6_config.sh"
old_core_hash=$(read_hash "$KS/scripts/apipv6_config.sh")
dbus remove softcenter_module_apipv6_version
set +e
MOCK_DBUS_FAIL_KEY=softcenter_module_apipv6_version APIPV6_SOURCE_DIR=$SOURCE2 sh "$SOURCE2/install.sh" >/dev/null 2>&1
failed_rc=$?
set -e
[ "$failed_rc" -ne 0 ] || fail 'installer failure injection did not fail'
expect "$(read_hash "$KS/scripts/apipv6_config.sh")" "$old_core_hash" 'failed upgrade must restore the previous core script'
expect "$(dbus get softcenter_module_apipv6_version)" '' 'failed upgrade must restore absent metadata state'
unset MOCK_DBUS_FAIL_KEY

# Successful upgrade is individually reversible, including user settings.
dbus set apipv6_enabled=1
dbus set apipv6_start_delay=77
install_from "$SOURCE2" >/dev/null
new_core_hash=$(read_hash "$KS/scripts/apipv6_config.sh")
[ "$new_core_hash" != "$old_core_hash" ] || fail 'test upgrade did not replace the core file'
upgrade_backup=$(cat "$APIPV6_RUN_DIR/last-backup")
dbus set apipv6_start_delay=99
PATH="$NO_FIRMWARE_COMMANDS" sh "$KS/scripts/apipv6_rollback.sh" "$upgrade_backup" >/dev/null
expect "$(read_hash "$KS/scripts/apipv6_config.sh")" "$old_core_hash" 'rollback must restore the previous plugin version'
expect "$(dbus get apipv6_start_delay)" 77 'rollback must restore the prior DBUS configuration'

# Successful enabled repair is the only point where the known old startup entry is moved.
printf '0\n' > "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6"
printf '1\n' > "$APIPV6_SYSCTL_ROOT/br0/autoconf"
printf '2\n' > "$APIPV6_SYSCTL_ROOT/br0/accept_ra"
repair_out=$("$KS/scripts/apipv6_config.sh" repair)
printf '%s' "$repair_out" | grep -q '"repair_result":"success"' || fail 'repair did not finish successfully'
[ ! -e "$KS/init.d/V00apipv6.sh" ] || fail 'verified migration did not deactivate the old startup entry'
grep -q '^status=migrated$' "$APIPV6_RUN_DIR/migration-state" || fail 'migration record did not switch to migrated'

# Uninstall stops only plugin work, restores the old entry, and preserves settings/logs.
PATH="$NO_FIRMWARE_COMMANDS" sh "$KS/scripts/apipv6_uninstall.sh" >/dev/null
[ -f "$KS/init.d/V00apipv6.sh" ] || fail 'uninstall did not restore the migrated old startup entry'
expect "$(read_hash "$KS/init.d/V00apipv6.sh")" "$legacy_hash" 'restored startup entry must match its backed-up hash'
[ ! -e "$KS/scripts/apipv6_config.sh" ] || fail 'uninstall left the plugin CLI installed'
[ ! -e "$KS/webs/Module_apipv6.asp" ] || fail 'uninstall left the plugin page installed'
expect "$(dbus get apipv6_enabled)" 0 'uninstall must stop plugin auto tasks'
expect "$(dbus get apipv6_start_delay)" 77 'uninstall must retain user configuration'
expect "$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")/$(cat "$APIPV6_SYSCTL_ROOT/br0/autoconf")/$(cat "$APIPV6_SYSCTL_ROOT/br0/accept_ra")" '0/1/2' 'uninstall must leave IPv6 sysctls unchanged'
[ -d "$KS/backup/apipv6" ] || fail 'uninstall removed recovery backups'
[ -d "$APIPV6_RUN_DIR" ] || fail 'uninstall removed the plugin log/state directory'

# User-owned V00 contents remain untouched on install and uninstall.
cat > "$KS/init.d/V00apipv6.sh" <<'EOF'
#!/bin/sh
echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/br0/autoconf
echo 2 > /proc/sys/net/ipv6/conf/br0/accept_ra
echo 'user-owned extra action'
EOF
custom_hash=$(read_hash "$KS/init.d/V00apipv6.sh")
install_from "$SOURCE" >/dev/null
grep -q '^status=conflict$' "$APIPV6_RUN_DIR/migration-state" || fail 'custom legacy script was not reported as a conflict'
expect "$(read_hash "$KS/init.d/V00apipv6.sh")" "$custom_hash" 'installer overwrote a custom startup script'
sh "$KS/scripts/apipv6_uninstall.sh" >/dev/null
expect "$(read_hash "$KS/init.d/V00apipv6.sh")" "$custom_hash" 'uninstall changed a custom startup script'

printf '%s\n' 'Lifecycle tests passed: first/repeated install, failed-upgrade restore, successful rollback, known migration, uninstall, and custom-script protection.'
