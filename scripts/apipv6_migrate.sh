#!/bin/sh
# Conservative migration helper for the former br0-only V00 startup script.

KS_DIR=${APIPV6_KS_DIR:-/koolshare}
APIPV6_SYSTEM_PATHS=${APIPV6_SYSTEM_PATHS:-$KS_DIR/bin:$KS_DIR/scripts:/koolshare/bin:/koolshare/scripts:/jffs/softcenter/bin:/jffs/softcenter/scripts:/jffs/.koolshare/bin:/jffs/.koolshare/scripts:/usr/sbin:/sbin:/usr/bin:/bin}
PATH=${PATH:+$PATH:}$APIPV6_SYSTEM_PATHS
export PATH
RUN_DIR=${APIPV6_RUN_DIR:-$KS_DIR/var/apipv6}
LEGACY=$KS_DIR/init.d/V00apipv6.sh
STATE=$RUN_DIR/migration-state

hash_file() {
    [ -f "$1" ] || return 1
    sha256sum "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

write_state() {
    state_tmp=$STATE.tmp.$$
    mkdir -p "$RUN_DIR" || return 1
    {
        printf 'status=%s\n' "$1"
        printf 'path=%s\n' "$LEGACY"
        printf 'sha256=%s\n' "${2:-}"
        printf 'backup_dir=%s\n' "${3:-}"
        printf 'checked_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf unknown)"
    } > "$state_tmp" || return 1
    chmod 600 "$state_tmp" 2>/dev/null || :
    mv -f "$state_tmp" "$STATE"
}

state_value() {
    awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { if (value != "") print value }' "$STATE" 2>/dev/null
}

known_legacy() {
    awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^echo[[:space:]]+0[[:space:]]*>[[:space:]]*\/proc\/sys\/net\/ipv6\/conf\/br0\/disable_ipv6$/ ||
                line ~ /^sysctl[[:space:]]+-w[[:space:]]+net\.ipv6\.conf\.br0\.disable_ipv6=0$/) {
                disable++
            } else if (line ~ /^echo[[:space:]]+1[[:space:]]*>[[:space:]]*\/proc\/sys\/net\/ipv6\/conf\/br0\/autoconf$/ ||
                       line ~ /^sysctl[[:space:]]+-w[[:space:]]+net\.ipv6\.conf\.br0\.autoconf=1$/) {
                autoconf++
            } else if (line ~ /^echo[[:space:]]+2[[:space:]]*>[[:space:]]*\/proc\/sys\/net\/ipv6\/conf\/br0\/accept_ra$/ ||
                       line ~ /^sysctl[[:space:]]+-w[[:space:]]+net\.ipv6\.conf\.br0\.accept_ra=2$/) {
                accept_ra++
            } else {
                unknown++
            }
        }
        END { exit (unknown || disable != 1 || autoconf != 1 || accept_ra != 1) }
    ' "$1"
}

inspect_legacy() {
    if [ ! -e "$LEGACY" ] && [ ! -L "$LEGACY" ]; then
        prior_status=$(state_value status)
        case "$prior_status" in
            migrated|known_pending|restored|conflict|backup_failed) return 0 ;;
        esac
        write_state none '' ''
        return $?
    fi
    if [ -L "$LEGACY" ] || [ ! -f "$LEGACY" ]; then
        write_state conflict '' ''
        return 1
    fi
    legacy_hash=$(hash_file "$LEGACY") || {
        write_state backup_failed '' ''
        return 1
    }
    if ! known_legacy "$LEGACY"; then
        write_state conflict "$legacy_hash" ''
        return 0
    fi
    stamp=$(date '+%Y%m%d%H%M%S' 2>/dev/null || printf 'unknown')
    backup_root=$KS_DIR/backup/apipv6
    backup_dir=$backup_root/legacy-$stamp-$$
    mkdir -p "$backup_dir" || {
        write_state backup_failed "$legacy_hash" ''
        return 1
    }
    chmod 700 "$backup_dir" 2>/dev/null || :
    cp -p "$LEGACY" "$backup_dir/V00apipv6.sh" || {
        rm -f "$backup_dir/V00apipv6.sh"
        rmdir "$backup_dir" 2>/dev/null || :
        write_state backup_failed "$legacy_hash" ''
        return 1
    }
    backup_hash=$(hash_file "$backup_dir/V00apipv6.sh") || backup_hash=
    if [ "$backup_hash" != "$legacy_hash" ]; then
        rm -f "$backup_dir/V00apipv6.sh"
        rmdir "$backup_dir" 2>/dev/null || :
        write_state backup_failed "$legacy_hash" ''
        return 1
    fi
    write_state known_pending "$legacy_hash" "$backup_dir"
}

deactivate_legacy() {
    migration_status=$(state_value status)
    case "$migration_status" in
        known_pending) ;;
        conflict) printf '%s\n' 'custom_legacy_script_preserved'; return 2 ;;
        migrated|restored|none) printf '%s\n' "$migration_status"; return 0 ;;
        *) printf '%s\n' 'no_verified_backup'; return 1 ;;
    esac
    expected_hash=$(state_value sha256)
    backup_dir=$(state_value backup_dir)
    [ -n "$expected_hash" ] && [ -n "$backup_dir" ] || return 1
    [ -f "$backup_dir/V00apipv6.sh" ] || return 1
    [ "$(hash_file "$backup_dir/V00apipv6.sh")" = "$expected_hash" ] || return 1
    [ -f "$LEGACY" ] && [ ! -L "$LEGACY" ] || return 1
    [ "$(hash_file "$LEGACY")" = "$expected_hash" ] || {
        write_state conflict "$expected_hash" "$backup_dir"
        return 2
    }
    mv "$LEGACY" "$backup_dir/V00apipv6.sh.migrated" || return 1
    write_state migrated "$expected_hash" "$backup_dir" || {
        mv "$backup_dir/V00apipv6.sh.migrated" "$LEGACY" 2>/dev/null || :
        return 1
    }
    printf '%s\n' 'migrated'
}

restore_legacy() {
    migration_status=$(state_value status)
    case "$migration_status" in
        migrated) ;;
        none|known_pending|restored) return 0 ;;
        conflict|backup_failed)
            printf '%s\n' "legacy script left untouched (status=$migration_status)" >&2
            return 2
            ;;
        *) return 0 ;;
    esac
    expected_hash=$(state_value sha256)
    backup_dir=$(state_value backup_dir)
    [ -n "$expected_hash" ] && [ -n "$backup_dir" ] || return 1
    if [ -e "$LEGACY" ] || [ -L "$LEGACY" ]; then
        if [ -f "$LEGACY" ] && [ ! -L "$LEGACY" ] && [ "$(hash_file "$LEGACY")" = "$expected_hash" ]; then
            write_state restored "$expected_hash" "$backup_dir"
            return $?
        fi
        printf '%s\n' 'refusing to overwrite a different V00apipv6.sh' >&2
        return 2
    fi
    restore_source=$backup_dir/V00apipv6.sh.migrated
    [ -f "$restore_source" ] || restore_source=$backup_dir/V00apipv6.sh
    [ -f "$restore_source" ] || return 1
    [ "$(hash_file "$restore_source")" = "$expected_hash" ] || return 1
    mkdir -p "$(dirname "$LEGACY")" || return 1
    cp -p "$restore_source" "$LEGACY.restore.$$" || return 1
    [ "$(hash_file "$LEGACY.restore.$$")" = "$expected_hash" ] || {
        rm -f "$LEGACY.restore.$$"
        return 1
    }
    mv "$LEGACY.restore.$$" "$LEGACY" || return 1
    write_state restored "$expected_hash" "$backup_dir"
}

case "${1:-inspect}" in
    inspect) inspect_legacy ;;
    deactivate) deactivate_legacy ;;
    restore) restore_legacy ;;
    *) printf '%s\n' 'Usage: apipv6_migrate.sh inspect|deactivate|restore' >&2; exit 2 ;;
esac
