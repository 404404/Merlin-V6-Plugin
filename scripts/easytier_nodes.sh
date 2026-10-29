#!/bin/sh
# Sourced by the lifecycle manager; read-only monitoring, no core execution.
# Official v2.6.4 core fingerprints, extracted from the SHA-256-pinned ZIPs.
nodes_core_version() {
    nodes_version=
    nodes_image=$EASYTIER_BIN
    [ -z "$nodes_service_pid" ] || nodes_image=$PROC_ROOT/$nodes_service_pid/exe
    nodes_hash=
    if type sha256sum >/dev/null 2>&1; then
        nodes_hash=$(sha256sum "$nodes_image" 2>/dev/null) || nodes_hash=
    fi
    if [ -z "$nodes_hash" ] && [ -x /bin/busybox ]; then
        nodes_hash=$(/bin/busybox sha256sum "$nodes_image" 2>/dev/null) || nodes_hash=
    fi
    if [ -z "$nodes_hash" ] && type openssl >/dev/null 2>&1; then
        nodes_hash=$(openssl dgst -sha256 "$nodes_image" 2>/dev/null) || nodes_hash=
        nodes_hash=${nodes_hash##* }
    fi
    nodes_hash=${nodes_hash%% *}
    case "$nodes_hash" in
        7f1040fec526ded3990663aa19dabb028fea52a6c6b06ddc1de32668829934b9|\
        7bd504e87cad52edacb9ea84ece7397d0afb911101de623a3dfc4a4dbd9e6bb6)
            nodes_version=2.6.4 ;;
    esac
}

nodes_reply() {
    printf '{"state":"%s","pid":%s,"core_version":"%s","version_source":"%s","collected_at":%s,"payload":"%s"}\n' \
        "$1" "${nodes_service_pid:-0}" "$nodes_version" \
        "${nodes_version:+fingerprint}" "$nodes_now" "${2:-}"
}

nodes_cleanup() {
    # Only signal the child we created and have not yet reaped. Its PID cannot
    # be reused until wait completes; never signal a core or a PID from a file.
    if [ "${nodes_child_pending:-0}" = 1 ]; then
        kill -KILL "$nodes_child" 2>/dev/null || :
        wait "$nodes_child" 2>/dev/null || :
    fi
    rm -f "$nodes_dir/raw.$$" "$nodes_dir/err.$$" "$nodes_dir/reply.$$"
    if [ "${nodes_lock_held:-0}" = 1 ]; then
        rm -f "$nodes_dir/lock/pid"
        rmdir "$nodes_dir/lock" 2>/dev/null || :
    fi
}

nodes_rpc_port() {
    # Only read the top-level management setting, never eval/source TOML.
    nodes_portal=$(awk '
        /^[[:space:]]*\[/ {exit}
        /^[[:space:]]*rpc_portal[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "");
            gsub(/["\047[:space:]]/, ""); print; exit
        }' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$nodes_portal" ] || nodes_portal=127.0.0.1:15888
    case "$nodes_portal" in
        127.0.0.1:*|0.0.0.0:*) ;;
        *) return 1 ;;
    esac
    nodes_port=${nodes_portal##*:}
    case "$nodes_port" in ''|*[!0-9]*|??????*) return 1 ;; esac
    [ "$nodes_port" -ge 1 ] && [ "$nodes_port" -le 65535 ]
}

nodes_query() {
    umask 077
    nodes_dir=${EASYTIER_NODES_DIR:-$TMP_DIR/easytier-nodes}
    nodes_cli=${EASYTIER_CLI_BIN:-$KS_DIR/bin/easytier-cli-plugin}
    nodes_service_pid=$(managed_pid) || nodes_service_pid=
    nodes_now=$(date +%s)
    nodes_lock_held=0
    nodes_child_pending=0
    nodes_version=
    if [ -L "$nodes_dir" ] || ! mkdir -p "$nodes_dir" || ! chmod 700 "$nodes_dir"; then
        nodes_reply storage_error
        return
    fi
    # Include process start time to invalidate data even after PID reuse.
    nodes_start=
    if [ -n "$nodes_service_pid" ]; then
        nodes_start=$(awk '{print $22}' "$PROC_ROOT/$nodes_service_pid/stat" 2>/dev/null)
        [ -n "$nodes_start" ] || { nodes_reply process_unverified; return; }
    fi
    nodes_signature=${nodes_service_pid:-0}:$nodes_start
    if [ -r "$nodes_dir/meta" ] && [ -r "$nodes_dir/snapshot" ]; then
        IFS=' ' read -r nodes_old_signature nodes_collected nodes_ttl < "$nodes_dir/meta" || :
        case "$nodes_collected:$nodes_ttl" in
            *[!0-9:]*|:*|*:) ;;
            *) if [ "$nodes_signature" = "$nodes_old_signature" ] &&
                [ "$nodes_now" -ge "$nodes_collected" ] &&
                [ "$((nodes_now - nodes_collected))" -lt "$nodes_ttl" ]; then
                    cat "$nodes_dir/snapshot"
                    return
                fi ;;
        esac
    fi
    nodes_core_version
    [ -n "$nodes_service_pid" ] || { nodes_reply stopped; return; }
    [ -x "$nodes_cli" ] || { nodes_reply cli_missing; return; }
    nodes_rpc_port || { nodes_reply rpc_unsupported; return; }
    # Attribute the listener to the managed process before trusting its version.
    if ! netstat -lntp 2>/dev/null | awk -v port="$nodes_port" -v owner="$nodes_service_pid/" '
        $1 == "tcp" && ($4 == "127.0.0.1:" port || $4 == "0.0.0.0:" port) &&
            index($7, owner) == 1 {found=1}
        END {exit !found}'; then
        nodes_reply rpc_unverified
        return
    fi
    if ! mkdir "$nodes_dir/lock" 2>/dev/null; then
        nodes_owner=
        [ ! -r "$nodes_dir/lock/pid" ] || IFS= read -r nodes_owner < "$nodes_dir/lock/pid"
        if valid_pid "$nodes_owner" && pid_is_alive "$nodes_owner"; then
            nodes_reply busy
            return
        fi
        # Allow an owner to publish its PID before reclaiming an empty lock.
        sleep 1
        nodes_owner=
        [ ! -r "$nodes_dir/lock/pid" ] || IFS= read -r nodes_owner < "$nodes_dir/lock/pid"
        if valid_pid "$nodes_owner" && pid_is_alive "$nodes_owner"; then
            nodes_reply busy
            return
        fi
        rm -f "$nodes_dir/lock/pid"
        rmdir "$nodes_dir/lock" 2>/dev/null || { nodes_reply busy; return; }
        mkdir "$nodes_dir/lock" 2>/dev/null || { nodes_reply busy; return; }
    fi
    nodes_lock_held=1
    printf '%s\n' "$$" > "$nodes_dir/lock/pid" || { nodes_cleanup; nodes_reply storage_error; return; }
    trap 'nodes_cleanup' 0
    trap 'exit 1' HUP INT TERM
    (
        # Supported by the target BusyBox ash; suppress query-tool core dumps.
        # shellcheck disable=SC3045
        ulimit -c 0
        ulimit -f 512 || exit 1
        # peer JSON is the CLI's formatted, read-only row list. Never use
        # --verbose or node/config JSON: those can contain network secrets.
        exec "$nodes_cli" -p "127.0.0.1:$nodes_port" --output json peer
    ) > "$nodes_dir/raw.$$" 2> "$nodes_dir/err.$$" </dev/null &
    nodes_child=$!
    nodes_child_pending=1
    nodes_waited=0
    while pid_is_alive "$nodes_child" && [ "$nodes_waited" -lt 3 ]; do
        sleep 1
        nodes_waited=$((nodes_waited + 1))
    done
    nodes_state=ready
    if pid_is_alive "$nodes_child"; then
        nodes_state=timeout
        kill -TERM "$nodes_child" 2>/dev/null || :
        sleep 1
        kill -KILL "$nodes_child" 2>/dev/null || :
    fi
    wait "$nodes_child" 2>/dev/null
    nodes_exit=$?
    nodes_child_pending=0
    [ "$nodes_exit" = 0 ] || { [ "$nodes_state" != ready ] || nodes_state=query_failed; }
    nodes_bytes=$(wc -c < "$nodes_dir/raw.$$")
    # Two Base64 layers (peer rows, then Web envelope) must remain below the
    # kernel's single-argument limit when legacy http_response calls curl -d.
    if [ "$nodes_bytes" -gt 65536 ] || { [ "$nodes_state" = ready ] && [ "$nodes_bytes" = 0 ]; }; then
        nodes_state=invalid_output
    fi
    # Discard a result if the core stopped/restarted while the CLI was reading.
    nodes_current_pid=$(managed_pid) || nodes_current_pid=
    nodes_current_start=
    [ -z "$nodes_current_pid" ] || nodes_current_start=$(awk '{print $22}' "$PROC_ROOT/$nodes_current_pid/stat" 2>/dev/null)
    if [ "$nodes_signature" != "${nodes_current_pid:-0}:$nodes_current_start" ]; then
        nodes_version=
        nodes_reply process_changed
        return
    fi
    nodes_payload=
    nodes_ttl=60
    if [ "$nodes_state" = ready ]; then
        nodes_payload=$(base64 < "$nodes_dir/raw.$$" | tr -d '\r\n')
        nodes_ttl=10
    fi
    nodes_reply "$nodes_state" "$nodes_payload" > "$nodes_dir/reply.$$"
    mv -f "$nodes_dir/reply.$$" "$nodes_dir/snapshot" || { nodes_reply storage_error; return; }
    printf '%s %s %s\n' "$nodes_signature" "$nodes_now" "$nodes_ttl" > "$nodes_dir/meta"
    cat "$nodes_dir/snapshot"
}
