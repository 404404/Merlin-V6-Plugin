#!/bin/sh
# Removes only AP IPv6 Manager files and its own timer. Leaves addresses/routes alone.

KS_DIR=${APIPV6_KS_DIR:-/koolshare}
CONFIG=$KS_DIR/scripts/apipv6_config.sh
MIGRATE=$KS_DIR/scripts/apipv6_migrate.sh

say() { printf '%s\n' "$*"; }

resolve_dbus() {
    dbus_path=$(command -v dbus 2>/dev/null) || dbus_path=
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

setup_dbus_path() {
    APIPV6_DBUS_CMD=$(resolve_dbus) || return 1
    case "$APIPV6_DBUS_CMD" in
        */*) PATH=${APIPV6_DBUS_CMD%/*}${PATH:+:$PATH}; export PATH ;;
    esac
}

main() {
    setup_dbus_path || :
    if [ -x "$CONFIG" ]; then
        "$CONFIG" stop >/dev/null 2>&1 || say '警告：无法停止自动管理任务；继续清理插件文件。'
    elif command -v cru >/dev/null 2>&1; then
        cru d apipv6_health >/dev/null 2>&1 || :
    fi

    if [ -x "$MIGRATE" ]; then
        "$MIGRATE" restore >/dev/null 2>&1 ||
            say '警告：旧 V00apipv6.sh 未恢复，因为目标路径已被其他内容占用或备份校验失败。'
    fi

    for file in \
        "$KS_DIR/scripts/apipv6_config.sh" \
        "$KS_DIR/scripts/apipv6_migrate.sh" \
        "$KS_DIR/scripts/apipv6_status.sh" \
        "$KS_DIR/scripts/apipv6_repair.sh" \
        "$KS_DIR/scripts/apipv6_uninstall.sh" \
        "$KS_DIR/scripts/apipv6_rollback.sh" \
        "$KS_DIR/webs/Module_apipv6.asp" \
        "$KS_DIR/res/icon-apipv6.png" \
        "$KS_DIR/config.json.js" \
        "$KS_DIR/init.d/V99apipv6.sh"
    do
        rm -f "$file" || say "警告：无法删除 $file"
    done

    if command -v dbus >/dev/null 2>&1; then
        for key in \
            softcenter_module_apipv6_version \
            softcenter_module_apipv6_install \
            softcenter_module_apipv6_name \
            softcenter_module_apipv6_title \
            softcenter_module_apipv6_description
        do
            dbus remove "$key" >/dev/null 2>&1 || :
        done
        dbus save >/dev/null 2>&1 || :
    fi

    say 'AP IPv6 Manager 已卸载。日志、配置和迁移备份已保留；未清除 IPv6 地址或路由。'
}

main "$@"
