#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CONFIG=$ROOT/scripts/apipv6_config.sh
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/apipv6-cli-test.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM

export PATH="$ROOT/tests/mocks:$PATH"
export APIPV6_KS_DIR=$TEMP/koolshare
export APIPV6_RUN_DIR=$APIPV6_KS_DIR/var/apipv6
export APIPV6_CONFIG_FILE=$APIPV6_KS_DIR/configs/apipv6.conf
export APIPV6_SYSCTL_ROOT=$TEMP/proc/sys/net/ipv6/conf
export MOCK_DBUS_FILE=$TEMP/dbus.values
export MOCK_IP_COUNTER_FILE=$TEMP/ip-addr-count
export MOCK_CRU_LOG=$TEMP/cru.log
export MOCK_SW_MODE=3
export MOCK_WLC_PSTA=0
export MOCK_IP_SCENARIO=good
export MOCK_PING=success
export APIPV6_TEST_NO_SLEEP=1
export APIPV6_RA_WAIT_SECONDS=10

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; }
assert_health() {
    out=$1
    wanted=$2
    printf '%s' "$out" | perl -MJSON::PP -e 'local $/; my $j=decode_json(<STDIN>); exit(($j->{health} // "") eq $ARGV[0] ? 0 : 1)' "$wanted" || fail "health should be $wanted"
}
assert_field() {
    out=$1
    path=$2
    wanted=$3
    printf '%s' "$out" | perl -MJSON::PP -e '
        local $/; my $j=decode_json(<STDIN>); my $v=$j;
        for my $part (split /\./, $ARGV[0]) { $v=$v->{$part} if ref($v) eq "HASH"; }
        my $got = ref($v) ? JSON::PP->new->encode($v) : defined($v) ? "$v" : "";
        exit($got eq $ARGV[1] ? 0 : 1);
    ' "$path" "$wanted" || fail "JSON field $path should be $wanted"
}
run_rc() {
    wanted_rc=$1
    shift
    set +e
    command_output=$("$@" 2>&1)
    got_rc=$?
    set -e
    [ "$got_rc" -eq "$wanted_rc" ] || fail "command '$*' exit $got_rc, expected $wanted_rc: $command_output"
    printf '%s' "$command_output"
}
write_sysctls() {
    mkdir -p "$APIPV6_SYSCTL_ROOT/br0" "$APIPV6_SYSCTL_ROOT/eth0" "$APIPV6_SYSCTL_ROOT/all"
    printf '%s\n' "${1:-0}" > "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6"
    printf '%s\n' "${2:-1}" > "$APIPV6_SYSCTL_ROOT/br0/autoconf"
    printf '%s\n' "${3:-2}" > "$APIPV6_SYSCTL_ROOT/br0/accept_ra"
    printf '7\n' > "$APIPV6_SYSCTL_ROOT/eth0/disable_ipv6"
    printf '8\n' > "$APIPV6_SYSCTL_ROOT/eth0/autoconf"
    printf '9\n' > "$APIPV6_SYSCTL_ROOT/eth0/accept_ra"
    printf '6\n' > "$APIPV6_SYSCTL_ROOT/all/disable_ipv6"
    mkdir -p "$TEMP/proc/sys/net/ipv4"
    printf '44\n' > "$TEMP/proc/sys/net/ipv4/ip_forward"
    printf 'iptables-sentinel\n' > "$TEMP/firewall-sentinel"
}
reset_counter() { rm -f "$MOCK_IP_COUNTER_FILE"; }

mkdir -p "$APIPV6_KS_DIR/scripts" "$APIPV6_KS_DIR/init.d"
cp "$CONFIG" "$APIPV6_KS_DIR/scripts/apipv6_config.sh"
chmod 755 "$APIPV6_KS_DIR/scripts/apipv6_config.sh"
write_sysctls 0 1 2
: > "$MOCK_DBUS_FILE"
: > "$MOCK_CRU_LOG"
printf 'preexisting_user_job\n' > "$TEMP/other-cru-job"

out=$("$CONFIG" status --json)
assert_health "$out" normal
assert_field "$out" ap_mode true
assert_field "$out" preferred_ipv6 '240a:42cc:1001:7141::10'
assert_field "$out" prefix '240a:42cc:1001:7141:0:0:0:0/64'
assert_field "$out" default_route true
assert_field "$out" default_gateway 'fe80::abcd'
printf '%s' "$out" | grep -q '"state":"deprecated"' || fail 'deprecated address missing from state JSON'
printf '%s' "$out" | grep -q '"type":"ula"' || fail 'ULA classification missing'
printf '%s' "$out" | grep -q '"address":"feb1::5678","type":"link_local"' || fail 'the full fe80::/10 link-local range should be recognized'
printf '%s' "$out" | grep -q '"temporary":true' || fail 'temporary classification missing'
printf '%s' "$out" | grep -q '"address":"240a:42cc:1001:7141::10","type":"global_unicast","state":"preferred","prefix_length":"64","preferred_lifetime":"7200sec","valid_lifetime":"86400sec","temporary":false' || fail 'mngtmpaddr template was incorrectly classified as a temporary address'

printf '1\n' > "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6"
out=$("$CONFIG" status --json)
assert_health "$out" parameter_error
printf '0\n' > "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6"
printf '0\n' > "$APIPV6_SYSCTL_ROOT/br0/accept_ra"
out=$("$CONFIG" status --json)
assert_health "$out" parameter_error
printf '2\n' > "$APIPV6_SYSCTL_ROOT/br0/accept_ra"

MOCK_IP_SCENARIO=no_address; export MOCK_IP_SCENARIO
out=$("$CONFIG" status --json)
assert_health "$out" address_error
MOCK_IP_SCENARIO=route_missing; export MOCK_IP_SCENARIO
out=$("$CONFIG" status --json)
assert_health "$out" route_error
MOCK_IP_SCENARIO=good; MOCK_PING=failure; export MOCK_IP_SCENARIO MOCK_PING
out=$("$CONFIG" status --json)
assert_health "$out" partial
MOCK_PING=success; MOCK_IP_SCENARIO=prefix2; export MOCK_PING MOCK_IP_SCENARIO
out=$("$CONFIG" status --json)
assert_field "$out" prefix '240a:42dd:2002:8152:0:0:0:0/64'

MOCK_IP_SCENARIO=good; MOCK_WLC_PSTA=1; export MOCK_IP_SCENARIO MOCK_WLC_PSTA
out=$("$CONFIG" status --json)
assert_health "$out" not_applicable
before=$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")
out=$(run_rc 5 "$CONFIG" repair)
expect "$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")" "$before" 'non-AP mode repair must not change br0'
MOCK_WLC_PSTA=0; MOCK_SW_MODE=1; export MOCK_WLC_PSTA MOCK_SW_MODE
out=$("$CONFIG" status --json)
assert_health "$out" not_applicable
MOCK_SW_MODE=3; export MOCK_SW_MODE
MOCK_IP_SCENARIO=br0_down; export MOCK_IP_SCENARIO
out=$("$CONFIG" status --json)
assert_health "$out" detection_error
out=$(run_rc 3 "$CONFIG" repair)
MOCK_IP_SCENARIO=br0_missing; export MOCK_IP_SCENARIO
out=$("$CONFIG" status --json)
assert_health "$out" detection_error
out=$(run_rc 3 "$CONFIG" repair)
MOCK_IP_SCENARIO=good; export MOCK_IP_SCENARIO

write_sysctls 1 0 0
out=$(run_rc 0 "$CONFIG" repair)
assert_field "$out" repair_result success
expect "$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")/$(cat "$APIPV6_SYSCTL_ROOT/br0/autoconf")/$(cat "$APIPV6_SYSCTL_ROOT/br0/accept_ra")" '0/1/2' 'repair must set only the three br0 SLAAC values'
expect "$(cat "$APIPV6_SYSCTL_ROOT/eth0/disable_ipv6")/$(cat "$APIPV6_SYSCTL_ROOT/eth0/autoconf")/$(cat "$APIPV6_SYSCTL_ROOT/eth0/accept_ra")" '7/8/9' 'repair must not change non-br0 interfaces'
expect "$(cat "$TEMP/proc/sys/net/ipv6/conf/all/disable_ipv6")" 6 'repair must not change global IPv6 sysctl'
expect "$(cat "$TEMP/proc/sys/net/ipv4/ip_forward")" 44 'repair must not change IPv4 settings'
expect "$(cat "$TEMP/firewall-sentinel")" iptables-sentinel 'repair must not change firewall state'
out=$(run_rc 0 "$CONFIG" repair)
assert_field "$out" changed false

write_sysctls 1 0 0
MOCK_IP_SCENARIO=no_address; export MOCK_IP_SCENARIO
reset_counter
out=$(run_rc 2 "$CONFIG" repair)
assert_field "$out" repair_result waiting_ra
expect "$(dbus get apipv6_last_failure)" waiting_ra 'repair timeout should be recorded'
out=$("$CONFIG" status --json)
assert_health "$out" waiting_ra
MOCK_IP_SCENARIO=delayed; MOCK_DELAY_ADDR_CALLS=3; export MOCK_IP_SCENARIO MOCK_DELAY_ADDR_CALLS
reset_counter
out=$(run_rc 0 "$CONFIG" repair)
assert_field "$out" repair_result success

out=$(run_rc 0 "$CONFIG" check)
[ -n "$(dbus get apipv6_last_check)" ] || fail 'health check timestamp was not stored'

MOCK_IP_SCENARIO=good; export MOCK_IP_SCENARIO
out=$(env apipv6_enabled=0 apipv6_start_delay=60 apipv6_health_enabled=1 apipv6_health_interval=15 apipv6_repair_on_error=0 \
    "$CONFIG" save_config web_submit)
assert_field "$out" ok true
grep -q 'a apipv6_health ' "$MOCK_CRU_LOG" || fail 'periodic health check should be independent from boot auto-repair'
before_interval=$(dbus get apipv6_health_interval)
set +e
env apipv6_enabled=1 apipv6_start_delay=30 apipv6_health_enabled=1 apipv6_health_interval=1 apipv6_repair_on_error=1 \
    "$CONFIG" save_config web_submit >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'invalid check interval was accepted'
expect "$(dbus get apipv6_health_interval)" "$before_interval" 'invalid config must not mutate settings'
MOCK_CRU_FAIL=1; export MOCK_CRU_FAIL
set +e
env apipv6_enabled=1 apipv6_start_delay=30 apipv6_health_enabled=1 apipv6_health_interval=20 apipv6_repair_on_error=1 \
    "$CONFIG" save_config web_submit >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'failed cron update was reported as success'
expect "$(dbus get apipv6_health_interval)" "$before_interval" 'failed schedule update must restore settings'
unset MOCK_CRU_FAIL

# Repeated boot checks may re-assert only the three bridge values after a later overwrite.
dbus set apipv6_enabled=1
write_sysctls 1 0 0
out=$(run_rc 0 "$CONFIG" boot)
expect "$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")/$(cat "$APIPV6_SYSCTL_ROOT/br0/autoconf")/$(cat "$APIPV6_SYSCTL_ROOT/br0/accept_ra")" '0/1/2' 'boot task must restore values overwritten by later initialization'
mkdir -p "$APIPV6_RUN_DIR/repair.lock"
printf '%s\n' "$$" > "$APIPV6_RUN_DIR/repair.lock/pid"
write_sysctls 1 0 0
out=$(run_rc 3 "$CONFIG" repair)
expect "$(cat "$APIPV6_SYSCTL_ROOT/br0/disable_ipv6")" 1 'concurrent repair lock must prevent writes'
rm -f "$APIPV6_RUN_DIR/repair.lock/pid"; rmdir "$APIPV6_RUN_DIR/repair.lock"
mkdir -p "$APIPV6_RUN_DIR/boot.lock"
printf '%s\n' "$$" > "$APIPV6_RUN_DIR/boot.lock/pid"
out=$(run_rc 0 "$CONFIG" boot)
rm -f "$APIPV6_RUN_DIR/boot.lock/pid"; rmdir "$APIPV6_RUN_DIR/boot.lock"

# Bounded log rotation.
perl -e 'print "x" x 140000' > "$APIPV6_RUN_DIR/apipv6.log"
write_sysctls 0 1 2
out=$(run_rc 0 "$CONFIG" repair)
log_size=$(wc -c < "$APIPV6_RUN_DIR/apipv6.log" | tr -d ' ')
[ "$log_size" -lt 40000 ] || fail "log rotation failed ($log_size bytes)"

# Exercise the asynchronous Web repair lifecycle and result polling.
web_start=$($CONFIG web_repair web_submit)
task_id=$(printf '%s' "$web_start" | perl -MJSON::PP -e 'local $/; my $j=decode_json(<STDIN>); print $j->{task_id}')
[ -n "$task_id" ] || fail 'web repair did not return a task id'
task_status=queued
attempt=0
while [ "$attempt" -lt 8 ]; do
    task_out=$($CONFIG web_task "$task_id" web_submit)
    task_status=$(printf '%s' "$task_out" | perl -MJSON::PP -e 'local $/; my $j=decode_json(<STDIN>); print $j->{status}')
    case "$task_status" in succeeded|failed) break ;; esac
    sleep 1
    attempt=$((attempt + 1))
done
expect "$task_status" succeeded 'Web repair must finish before reporting success'
printf '%s' "$task_out" | perl -MJSON::PP -e 'local $/; my $j=decode_json(<STDIN>); exit(($j->{result}{repair_result} // "") eq "success" ? 0 : 1)' || fail 'Web task result was incomplete or unsuccessful'

printf '%s\n' 'CLI status, classification, repair safety, bounded retry, scheduling, locking, log rotation, and Web task tests passed.'
