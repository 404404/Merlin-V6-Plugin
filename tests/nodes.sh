#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
core_pid=
cleanup() {
    if [ -n "$core_pid" ]; then kill "$core_pid" 2>/dev/null || :; wait "$core_pid" 2>/dev/null || :; fi
    rm -rf "$TMP"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP/ks/bin" "$TMP/ks/scripts" "$TMP/ks/configs" "$TMP/run" "$TMP/mockbin"
cp "$ROOT/scripts/easytier_nodes.sh" "$TMP/ks/scripts/"
cat > "$TMP/ks/bin/easytier-core" <<'CORE'
#!/bin/sh
[ "$1" = -c ] || { echo 'unsafe core invocation' >> "$CORE_CALLS"; exit 1; }
trap 'exit 0' TERM
while :; do /bin/sleep 1; done
CORE
cat > "$TMP/ks/scripts/base.sh" <<'BASE'
command() { return 127; }
sha256sum() { return 127; }
# Real legacy httpdb inserts callback text without JSON escaping.
http_response() { printf '{"result":"%s"}\n' "$1" > "$HTTP_RESPONSE_FILE"; }
BASE
cat > "$TMP/mockbin/dbus" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DBUS_CALLS"
exit 1
MOCK
cat > "$TMP/mockbin/netstat" <<'MOCK'
#!/bin/sh
printf 'tcp 0 0 %s:%s 0.0.0.0:* LISTEN %s/easytier-core\n' "${NETSTAT_ADDRESS:-0.0.0.0}" "${TEST_PORT:-15888}" "$NETSTAT_OWNER"
MOCK
cat > "$TMP/ks/bin/easytier-cli-plugin" <<'CLI'
#!/bin/sh
printf '%s\n' "$$" >> "$CLI_CALLS"
[ "$*" = "-p 127.0.0.1:${TEST_PORT:-15888} --output json peer" ] || exit 25
case "${CLI_MODE:-ok}" in
    fail) printf 'DO_NOT_EXPOSE_PRIVATE_ERROR\n' >&2; exit 23 ;;
    hang) exec /bin/sleep 30 ;;
    slow) /bin/sleep 1 ;;
    huge) head -c 260000 /dev/zero; exit 0 ;;
esac
cat "$PEERS_FIXTURE"
CLI
chmod 755 "$TMP/ks/bin/"* "$TMP/mockbin/"*
cat > "$TMP/peers.json" <<'JSON'
[
 {"hostname":"AX56U","cidr":"192.0.2.10/24","cost":"Local","id":"1","version":"2.5.3","lat_ms":"-","rx_bytes":"-","tx_bytes":"-"},
 {"hostname":"peer-test","cidr":"192.0.2.11/24","cost":"p2p","id":"2","version":"2.6.4","lat_ms":"12.30","loss_rate":"0.1%","rx_bytes":"1.2 MB","tx_bytes":"3 MB","tunnel_proto":"udp"}
]
JSON
export PATH="$TMP/mockbin:$PATH"
export EASYTIER_KS_DIR="$TMP/ks" EASYTIER_RUN_DIR="$TMP/run" EASYTIER_TMP_DIR="$TMP"
export EASYTIER_CONFIG_FILE="$TMP/ks/configs/easytier.conf" EASYTIER_PID_FILE="$TMP/run/easytier.pid"
export EASYTIER_BIN="$TMP/ks/bin/easytier-core" EASYTIER_NODES_DIR="$TMP/cache"
export CLI_CALLS="$TMP/cli-calls" CORE_CALLS="$TMP/core-calls" DBUS_CALLS="$TMP/dbus-calls"
export PEERS_FIXTURE="$TMP/peers.json" HTTP_RESPONSE_FILE="$TMP/http-response"
: > "$CLI_CALLS"; : > "$CORE_CALLS"; : > "$DBUS_CALLS"
printf '%s\n' 'network_name = "TEST_PRIVATE_NETWORK"' > "$EASYTIER_CONFIG_FILE"
cp "$EASYTIER_CONFIG_FILE" "$TMP/config-before"
"$EASYTIER_BIN" -c "$EASYTIER_CONFIG_FILE" &
core_pid=$!
printf '%s\n' "$core_pid" > "$EASYTIER_PID_FILE"
export NETSTAT_OWNER=$core_pid
SERVICE=$ROOT/scripts/easytier_config.sh
query() { busybox ash "$SERVICE" nodes > "$TMP/result"; }
state_is() {
    python3 - "$TMP/result" "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r['state'] == sys.argv[2], r
PY
}
invalidate() { rm -f "$TMP/cache/meta"; }
query
state_is ready
python3 - "$TMP/result" <<'PY'
import base64, json, sys
r=json.load(open(sys.argv[1]))
assert r['core_version'] == ''  # No SHA256 tool: never guess from CLI build version.
peers=json.loads(base64.b64decode(r['payload']))
assert peers[0]['version'] == '2.5.3'
assert 'TEST_PRIVATE_NETWORK' not in json.dumps(r)
PY
query
state_is ready
[ "$(wc -l < "$CLI_CALLS" | tr -d ' ')" = 1 ] || fail 'cache spawned another CLI'
busybox ash "$SERVICE" 123 nodes
python3 - "$HTTP_RESPONSE_FILE" "$TMP/result" <<'PY'
import base64, json, sys
wire = json.load(open(sys.argv[1]))['result']
assert wire.startswith('easytier-b64-v1:')
assert len(wire) < 131072 and not any(c in wire for c in '\n\r"\\')
assert json.loads(base64.b64decode(wire[16:])) == json.load(open(sys.argv[2]))
PY
if busybox ash "$SERVICE" 123 nodes web_submit; then fail 'nodes accepted Web config operation'; fi

# The largest accepted rows still fit legacy curl's single-argument limit.
python3 - "$TMP/peers.json" "$TMP/large-peers.json" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(data + b' ' * (65536 - len(data)))
PY
invalidate
PEERS_FIXTURE="$TMP/large-peers.json" busybox ash "$SERVICE" 124 nodes
python3 - "$HTTP_RESPONSE_FILE" <<'PY'
import base64, json, sys
wire = json.load(open(sys.argv[1]))['result']
assert len(wire) < 131072
envelope = json.loads(base64.b64decode(wire[16:]))
assert envelope['state'] == 'ready'
assert len(base64.b64decode(envelope['payload'])) == 65536
assert json.loads(base64.b64decode(envelope['payload']))[0]['cost'] == 'Local'
PY
printf ' ' >> "$TMP/large-peers.json"
invalidate
PEERS_FIXTURE="$TMP/large-peers.json" query
state_is invalid_output
invalidate
query
calls_before=$(wc -l < "$CLI_CALLS")

# Reject an unrelated listener and non-local management setting without running CLI.
invalidate
NETSTAT_OWNER=999999 query
state_is rpc_unverified
[ "$(wc -l < "$CLI_CALLS")" = "$calls_before" ] || fail 'queried unrelated listener'
NETSTAT_ADDRESS=192.0.2.99 query
state_is rpc_unverified
[ "$(wc -l < "$CLI_CALLS")" = "$calls_before" ] || fail 'trusted a listener not bound to loopback'
printf '%s\n' 'rpc_portal = "192.0.2.99:15888"' > "$EASYTIER_CONFIG_FILE"
query
state_is rpc_unsupported
printf '%s\n' 'rpc_portal = "0.0.0.0:15999"' > "$EASYTIER_CONFIG_FILE"
TEST_PORT=15999 query
state_is ready
cp "$TMP/config-before" "$EASYTIER_CONFIG_FILE"

# Failure details stay private, with a backoff cache rather than repeated crashes.
invalidate
CLI_MODE=fail query
state_is query_failed
! grep -q DO_NOT_EXPOSE_PRIVATE_ERROR "$TMP/result" || fail 'private CLI stderr leaked'
calls_before=$(wc -l < "$CLI_CALLS")
query
state_is query_failed
[ "$(wc -l < "$CLI_CALLS")" = "$calls_before" ] || fail 'failure backoff did not work'

invalidate
started=$(date +%s)
CLI_MODE=hang query
state_is timeout
[ "$(($(date +%s) - started))" -le 7 ] || fail 'CLI timeout was unbounded'
last_cli=$(tail -n 1 "$CLI_CALLS")
! kill -0 "$last_cli" 2>/dev/null || fail 'timed-out CLI was left running'
kill -0 "$core_pid" || fail 'timeout killed the core'

invalidate
CLI_MODE=huge query
state_is invalid_output

# Concurrent reads spawn at most one CLI; a dead lock is recovered.
invalidate
CLI_MODE=slow busybox ash "$SERVICE" nodes > "$TMP/concurrent1" &
request_pid=$!
/bin/sleep 0.2
query
state_is busy
wait "$request_pid"
cp "$TMP/concurrent1" "$TMP/result"
state_is ready
invalidate
mkdir "$TMP/cache/lock"
printf '%s\n' 999999999 > "$TMP/cache/lock/pid"
query
state_is ready
[ ! -d "$TMP/cache/lock" ] || fail 'query lock leaked'

# Optional fingerprint recognition reads the running image, not an unrelated
# newly replaced on-disk binary. This remains separate from RPC's local version.
cat >> "$TMP/ks/scripts/base.sh" <<'BASE'
sha256sum() {
    [ "$1" = "/proc/$NETSTAT_OWNER/exe" ] || return 1
    printf '%s  %s\n' '7f1040fec526ded3990663aa19dabb028fea52a6c6b06ddc1de32668829934b9' "$1"
}
BASE
invalidate
query
state_is ready
python3 - "$TMP/result" <<'PY'
import json, sys
r=json.load(open(sys.argv[1]))
assert r['core_version'] == '2.6.4' and r['version_source'] == 'fingerprint'
PY
busybox ash "$SERVICE" 125 nodes
python3 - "$HTTP_RESPONSE_FILE" <<'PY'
import base64, json, sys
r=json.loads(base64.b64decode(json.load(open(sys.argv[1]))['result'][16:]))
assert r['state'] == 'ready' and r['core_version'] == '2.6.4'
assert r['version_source'] == 'fingerprint'
PY
EASYTIER_NODES_SCRIPT="$TMP/missing.sh" busybox ash "$SERVICE" 126 nodes
python3 - "$HTTP_RESPONSE_FILE" <<'PY'
import base64, json, sys
r=json.loads(base64.b64decode(json.load(open(sys.argv[1]))['result'][16:]))
assert r['state'] == 'helper_missing'
PY

# A different process must never inherit cached nodes or a cached core version.
old_pid=$core_pid
kill "$core_pid"
wait "$core_pid" || :
core_pid=
query
state_is stopped
"$EASYTIER_BIN" -c "$EASYTIER_CONFIG_FILE" &
core_pid=$!
export NETSTAT_OWNER=$core_pid
printf '%s\n' "$core_pid" > "$EASYTIER_PID_FILE"
query
state_is ready
python3 - "$TMP/result" "$old_pid" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['pid'] != int(sys.argv[2])
PY
cmp -s "$EASYTIER_CONFIG_FILE" "$TMP/config-before" || fail 'monitor changed configuration'
[ ! -s "$DBUS_CALLS" ] || fail 'monitor touched DBUS'
[ ! -s "$CORE_CALLS" ] || fail 'monitor executed core version query'
echo 'Read-only nodes, legacy httpdb transport, payload limits, fingerprints, ownership, caching, timeout and concurrency tests passed.'
