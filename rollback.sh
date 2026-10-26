#!/bin/sh
# Restore only files listed by this plugin's own pre-upgrade backup.

KS_DIR=${APIPV6_KS_DIR:-/koolshare}
BACKUP_DIR=${1:-}

allowed_path() {
    case "$1" in
        scripts/apipv6_config.sh|scripts/apipv6_migrate.sh|scripts/apipv6_status.sh|\
        scripts/apipv6_repair.sh|scripts/apipv6_uninstall.sh|scripts/apipv6_rollback.sh|\
        webs/Module_apipv6.asp|res/icon-apipv6.png|config.json.js|init.d/V99apipv6.sh|\
        var/apipv6/migration-state|var/apipv6/last-backup) return 0 ;;
        *) return 1 ;;
    esac
}

restore_dbus() {
    [ -r "$BACKUP_DIR/dbus.values" ] || return 0
    while IFS= read -r row; do
        case "$row" in *=*) ;; *) continue ;; esac
        key=${row%%=*}
        value=${row#*=}
        case "$key" in apipv6_*|softcenter_module_apipv6_*) ;; *) continue ;; esac
        if [ "$value" = __APIPV6_MISSING__ ]; then
            dbus remove "$key" >/dev/null 2>&1 || :
        else
            dbus set "$key=$value" >/dev/null 2>&1 || return 1
        fi
    done < "$BACKUP_DIR/dbus.values"
    dbus save >/dev/null 2>&1 || :
}

restore_files() {
    [ -r "$BACKUP_DIR/manifest" ] && [ -r "$BACKUP_DIR/absent" ] || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        allowed_path "$rel" || return 1
        case "$rel" in /*|*../*|../*|*/..) return 1 ;; esac
        if [ -f "$BACKUP_DIR/$rel" ]; then
            mkdir -p "$KS_DIR/$(dirname "$rel")" || return 1
            cp -p "$BACKUP_DIR/$rel" "$KS_DIR/$rel.rollback.$$" || return 1
            mv -f "$KS_DIR/$rel.rollback.$$" "$KS_DIR/$rel" || return 1
        elif grep -Fx "$rel" "$BACKUP_DIR/absent" >/dev/null 2>&1; then
            rm -f "$KS_DIR/$rel" || return 1
        else
            return 1
        fi
    done < "$BACKUP_DIR/manifest"
}

main() {
    if [ -z "$BACKUP_DIR" ]; then
        [ -r "$KS_DIR/var/apipv6/last-backup" ] || {
            printf '%s\n' 'Usage: apipv6_rollback.sh /koolshare/backup/apipv6/upgrade-...' >&2
            return 2
        }
        IFS= read -r BACKUP_DIR < "$KS_DIR/var/apipv6/last-backup" || :
    fi
    case "$BACKUP_DIR" in "$KS_DIR"/backup/apipv6/upgrade-*) ;; *)
        printf '%s\n' 'Refusing rollback outside this plugin upgrade backup directory.' >&2
        return 2
        ;;
    esac
    [ -d "$BACKUP_DIR" ] || { printf '%s\n' 'Backup directory does not exist.' >&2; return 1; }

    if [ -x "$KS_DIR/scripts/apipv6_config.sh" ]; then
        "$KS_DIR/scripts/apipv6_config.sh" stop >/dev/null 2>&1 || :
    elif command -v cru >/dev/null 2>&1; then
        cru d apipv6_health >/dev/null 2>&1 || :
    fi
    if [ -x "$KS_DIR/scripts/apipv6_migrate.sh" ]; then
        "$KS_DIR/scripts/apipv6_migrate.sh" restore >/dev/null 2>&1 || {
            printf '%s\n' 'Could not safely restore the migrated V00 script; rollback stopped.' >&2
            return 1
        }
    fi
    restore_files || { printf '%s\n' 'File rollback failed; inspect the backup manifest and file permissions.' >&2; return 1; }
    if command -v dbus >/dev/null 2>&1; then restore_dbus || return 1; fi
    printf 'Rollback restored the prior plugin files and DBUS settings from %s.\n' "$BACKUP_DIR"
    printf '%s\n' 'IPv6 addresses and routes were left unchanged.'
}

main "$@"
