#!/bin/sh
# Transactional KoolShare offline installer. Does not change network settings.

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

TMP_ROOT=${APIPV6_TMP_ROOT:-/tmp}
SOURCE_DIR=${APIPV6_SOURCE_DIR:-$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)}
INSTALL_LOCK=$TMP_ROOT/apipv6-install.lock
BACKUP_DIR=
BACKUP_READY=0
INSTALL_LOCK_HELD=0

say() {
    printf '%s %s\n' "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)]" "$*"
}

release_lock() {
    [ "$INSTALL_LOCK_HELD" -eq 1 ] || return 0
    lock_owner=$(cat "$INSTALL_LOCK/pid" 2>/dev/null)
    if [ "$lock_owner" = "$$" ]; then
        rm -f "$INSTALL_LOCK/pid"
        rmdir "$INSTALL_LOCK" 2>/dev/null || :
    fi
    INSTALL_LOCK_HELD=0
}

restore_dbus_snapshot() {
    snapshot=$1/dbus.values
    [ -r "$snapshot" ] || return 0
    while IFS= read -r row; do
        case "$row" in *=*) ;; *) continue ;; esac
        key=${row%%=*}
        value=${row#*=}
        case "$key" in apipv6_*|softcenter_module_apipv6_*) ;; *) continue ;; esac
        if [ "$value" = __APIPV6_MISSING__ ]; then
            dbus remove "$key" >/dev/null 2>&1 || :
        else
            dbus set "$key=$value" >/dev/null 2>&1 || :
        fi
    done < "$snapshot"
    dbus save >/dev/null 2>&1 || :
}

restore_backup() {
    backup=$1
    [ -r "$backup/manifest" ] || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in /*|*../*|../*|*/..) return 1 ;; esac
        if [ -f "$backup/$rel" ]; then
            mkdir -p "$KS_DIR/$(dirname "$rel")" || return 1
            cp -p "$backup/$rel" "$KS_DIR/$rel.apipv6-restore.$$" || return 1
            mv -f "$KS_DIR/$rel.apipv6-restore.$$" "$KS_DIR/$rel" || return 1
        elif grep -Fx "$rel" "$backup/absent" >/dev/null 2>&1; then
            rm -f "$KS_DIR/$rel" || return 1
        else
            return 1
        fi
    done < "$backup/manifest"
}

abort_install() {
    say "错误：$*"
    if [ "$BACKUP_READY" -eq 1 ]; then
        restore_backup "$BACKUP_DIR" || say '警告：自动恢复未完全成功，请检查备份目录。'
        restore_dbus_snapshot "$BACKUP_DIR"
    fi
    release_lock
    say "安装失败。${BACKUP_DIR:+可用备份：$BACKUP_DIR}"
    exit 1
}

acquire_lock() {
    mkdir -p "$TMP_ROOT" || return 1
    if mkdir "$INSTALL_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$INSTALL_LOCK/pid" || return 1
        INSTALL_LOCK_HELD=1
        return 0
    fi
    lock_owner=$(cat "$INSTALL_LOCK/pid" 2>/dev/null)
    case "$lock_owner" in ''|*[!0-9]*) lock_owner= ;; esac
    if [ -n "$lock_owner" ] && kill -0 "$lock_owner" 2>/dev/null; then
        return 1
    fi
    rm -f "$INSTALL_LOCK/pid" 2>/dev/null || :
    rmdir "$INSTALL_LOCK" 2>/dev/null || return 1
    mkdir "$INSTALL_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$INSTALL_LOCK/pid" || return 1
    INSTALL_LOCK_HELD=1
}

backup_targets() {
    : > "$BACKUP_DIR/manifest" || return 1
    : > "$BACKUP_DIR/absent" || return 1
    for rel in \
        scripts/apipv6_config.sh \
        scripts/apipv6_migrate.sh \
        scripts/apipv6_status.sh \
        scripts/apipv6_repair.sh \
        scripts/apipv6_uninstall.sh \
        scripts/apipv6_rollback.sh \
        webs/Module_apipv6.asp \
        res/icon-apipv6.png \
        config.json.js \
        init.d/V99apipv6.sh \
        var/apipv6/migration-state \
        var/apipv6/last-backup
    do
        printf '%s\n' "$rel" >> "$BACKUP_DIR/manifest" || return 1
        if [ -f "$KS_DIR/$rel" ]; then
            mkdir -p "$BACKUP_DIR/$(dirname "$rel")" || return 1
            cp -p "$KS_DIR/$rel" "$BACKUP_DIR/$rel" || return 1
        else
            printf '%s\n' "$rel" >> "$BACKUP_DIR/absent" || return 1
        fi
    done
    : > "$BACKUP_DIR/dbus.values" || return 1
    for key in \
        apipv6_enabled apipv6_start_delay apipv6_health_enabled \
        apipv6_health_interval apipv6_repair_on_error apipv6_last_check \
        apipv6_last_repair apipv6_last_failure \
        softcenter_module_apipv6_version softcenter_module_apipv6_install \
        softcenter_module_apipv6_name softcenter_module_apipv6_title \
        softcenter_module_apipv6_description
    do
        value=$(dbus get "$key" 2>/dev/null) || value=
        [ -n "$value" ] || value=__APIPV6_MISSING__
        printf '%s=%s\n' "$key" "$value" >> "$BACKUP_DIR/dbus.values" || return 1
    done
}

install_file() {
    source=$1
    target=$2
    mode=$3
    [ -f "$source" ] || return 1
    mkdir -p "$(dirname "$target")" || return 1
    install_tmp=$target.apipv6-new.$$
    cp "$source" "$install_tmp" || { rm -f "$install_tmp"; return 1; }
    chmod "$mode" "$install_tmp" || { rm -f "$install_tmp"; return 1; }
    mv -f "$install_tmp" "$target" || { rm -f "$install_tmp"; return 1; }
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

setup_ip_path() {
    APIPV6_IP_CMD=$(resolve_ip) || return 1
    case "$APIPV6_IP_CMD" in
        */*) PATH=${APIPV6_IP_CMD%/*}${PATH:+:$PATH}; export PATH ;;
    esac
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

setup_dbus_path() {
    APIPV6_DBUS_CMD=$(resolve_dbus) || return 1
    case "$APIPV6_DBUS_CMD" in
        */*) PATH=${APIPV6_DBUS_CMD%/*}${PATH:+:$PATH}; export PATH ;;
    esac
}

initialize_setting() {
    key=$1
    value=$2
    existing=$(dbus get "$key" 2>/dev/null) || existing=
    [ -n "$existing" ] || dbus set "$key=$value" || return 1
}

switch_label() {
    switch_value=$(dbus get "$1" 2>/dev/null) || switch_value=
    case "$switch_value" in 1) printf '已启用' ;; 0) printf '已关闭' ;; *) printf '未知，请检查设置' ;; esac
}

main() {
    missing_tools=
    for tool in awk cat chmod cp date df dirname grep mkdir mv rm rmdir sed sleep tail tr wc; do
        find_executable "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
    done
    setup_ip_path || missing_tools="$missing_tools ip"
    setup_dbus_path || missing_tools="$missing_tools dbus"
    APIPV6_NVRAM_CMD=$(resolve_nvram) || missing_tools="$missing_tools nvram"
    if [ -n "$missing_tools" ]; then
        say "诊断：当前 PATH=$PATH"
        abort_install "固件缺少必要命令或工具：${missing_tools# }"
    fi
    # Broadcom firmware also ships a memory utility named sh in /usr/sbin.
    # Never resolve the shell through PATH (that utility can even exit zero).
    [ -x /bin/sh ] || abort_install '固件缺少 /bin/sh 解释器。'

    [ -d "$SOURCE_DIR" ] || abort_install "找不到安装包目录：$SOURCE_DIR"
    [ -f "$SOURCE_DIR/.valid" ] || abort_install '安装包缺少 .valid 平台标记。'
    package_platform=$(cat "$SOURCE_DIR/.valid" 2>/dev/null | tr -d '\r\n')
    case "$package_platform" in hnd|qca) ;; *) abort_install '安装包的 .valid 只能是 hnd 或 qca。' ;; esac
    for required in \
        config.json.js uninstall.sh rollback.sh \
        scripts/apipv6_config.sh scripts/apipv6_migrate.sh \
        scripts/apipv6_status.sh scripts/apipv6_repair.sh \
        webs/Module_apipv6.asp res/apipv6.png init.d/V99apipv6.sh
    do
        [ -f "$SOURCE_DIR/$required" ] || abort_install "安装包缺少文件：$required"
    done
    sw_mode=$("$APIPV6_NVRAM_CMD" get sw_mode 2>/dev/null | tr -d '\r\n')
    case "$sw_mode" in 1|2|3|4) ;; *) say "警告：无法识别 sw_mode=${sw_mode:-empty}；插件将以只读诊断模式安装。" ;; esac
    wlc_psta=$("$APIPV6_NVRAM_CMD" get wlc_psta 2>/dev/null | tr -d '\r\n')
    [ -n "$wlc_psta" ] || wlc_psta=0
    case "$wlc_psta" in 0|1) ;; *) wlc_psta=unknown ;; esac
    for file in "$SOURCE_DIR/install.sh" "$SOURCE_DIR/uninstall.sh" "$SOURCE_DIR/rollback.sh" \
        "$SOURCE_DIR/scripts/apipv6_config.sh" "$SOURCE_DIR/scripts/apipv6_migrate.sh" \
        "$SOURCE_DIR/scripts/apipv6_status.sh" "$SOURCE_DIR/scripts/apipv6_repair.sh" \
        "$SOURCE_DIR/init.d/V99apipv6.sh"
    do
        /bin/sh -n "$file" || abort_install "Shell 语法检查失败：$file"
    done

    acquire_lock || abort_install '另一个安装任务正在运行。'
    mkdir -p "$KS_DIR/scripts" "$KS_DIR/webs" "$KS_DIR/res" "$KS_DIR/init.d" \
        "$KS_DIR/configs" "$KS_DIR/var/apipv6" "$KS_DIR/backup/apipv6" ||
        abort_install '无法创建 KoolShare 插件目录。'
    available=$(df -Pk "$KS_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$available" in
        ''|*[!0-9]*) ;;
        *) [ "$available" -ge 128 ] || abort_install "JFFS 可用空间不足：至少需要 128 KB，当前 ${available} KB。" ;;
    esac

    stamp=$(date '+%Y%m%d%H%M%S' 2>/dev/null || printf unknown)
    BACKUP_DIR=$KS_DIR/backup/apipv6/upgrade-$stamp-$$
    mkdir -m 700 -p "$BACKUP_DIR" || abort_install '无法创建升级备份目录。'
    backup_targets || abort_install '安装前备份失败。'
    BACKUP_READY=1

    install_file "$SOURCE_DIR/scripts/apipv6_config.sh" "$KS_DIR/scripts/apipv6_config.sh" 755 || abort_install '安装 CLI/API 脚本失败。'
    install_file "$SOURCE_DIR/scripts/apipv6_migrate.sh" "$KS_DIR/scripts/apipv6_migrate.sh" 755 || abort_install '安装旧脚本迁移工具失败。'
    install_file "$SOURCE_DIR/scripts/apipv6_status.sh" "$KS_DIR/scripts/apipv6_status.sh" 755 || abort_install '安装状态脚本失败。'
    install_file "$SOURCE_DIR/scripts/apipv6_repair.sh" "$KS_DIR/scripts/apipv6_repair.sh" 755 || abort_install '安装修复脚本失败。'
    install_file "$SOURCE_DIR/uninstall.sh" "$KS_DIR/scripts/apipv6_uninstall.sh" 755 || abort_install '安装卸载入口失败。'
    install_file "$SOURCE_DIR/rollback.sh" "$KS_DIR/scripts/apipv6_rollback.sh" 755 || abort_install '安装回滚入口失败。'
    install_file "$SOURCE_DIR/webs/Module_apipv6.asp" "$KS_DIR/webs/Module_apipv6.asp" 644 || abort_install '安装 Web 页面失败。'
    install_file "$SOURCE_DIR/res/apipv6.png" "$KS_DIR/res/icon-apipv6.png" 644 || abort_install '安装插件图标失败。'
    install_file "$SOURCE_DIR/config.json.js" "$KS_DIR/config.json.js" 644 || abort_install '安装软件中心元数据失败。'
    install_file "$SOURCE_DIR/init.d/V99apipv6.sh" "$KS_DIR/init.d/V99apipv6.sh" 755 || abort_install '安装 V99 启动入口失败。'

    /bin/sh -n "$KS_DIR/scripts/apipv6_config.sh" || abort_install '安装后的主脚本校验失败。'
    initialize_setting apipv6_enabled 0 || abort_install '无法初始化自动修复开关。'
    initialize_setting apipv6_start_delay 30 || abort_install '无法初始化开机延迟。'
    initialize_setting apipv6_health_enabled 0 || abort_install '无法初始化周期检查开关。'
    initialize_setting apipv6_health_interval 15 || abort_install '无法初始化周期检查间隔。'
    initialize_setting apipv6_repair_on_error 0 || abort_install '无法初始化异常自动修复开关。'
    dbus set "softcenter_module_apipv6_version=$PLUGIN_VERSION" || abort_install '无法注册软件中心版本。'
    dbus set softcenter_module_apipv6_install=1 || abort_install '无法注册软件中心安装状态。'
    dbus set softcenter_module_apipv6_name=apipv6 || abort_install '无法注册软件中心模块名。'
    dbus set 'softcenter_module_apipv6_title=AP IPv6 管理' || abort_install '无法注册软件中心标题。'
    dbus set 'softcenter_module_apipv6_description=Merlin AP 模式 IPv6 SLAAC 管理与诊断' || abort_install '无法注册软件中心说明。'
    dbus save >/dev/null 2>&1 || abort_install '软件中心 DBUS 配置保存失败。'

    "$KS_DIR/scripts/apipv6_migrate.sh" inspect >/dev/null 2>&1 || :
    migration_status=$(awk -F= '$1 == "status" { sub(/^[^=]*=/, ""); print; exit }' "$KS_DIR/var/apipv6/migration-state" 2>/dev/null)
    case "$migration_status" in
        known_pending) say '已备份已知旧 V00 启动脚本；它会保留到新插件启用并通过修复验证。' ;;
        conflict)
            migration_hash=$(awk -F= '$1 == "sha256" { sub(/^[^=]*=/, ""); print; exit }' "$KS_DIR/var/apipv6/migration-state" 2>/dev/null)
            say '提示：旧 V00apipv6.sh 未匹配已知模板，原文件保留；这不是安装失败。'
            say "旧脚本路径：$KS_DIR/init.d/V00apipv6.sh；SHA-256：${migration_hash:-无法读取}"
            say '该文件不会因启用自动修复而自动迁移。请先备份并核对内容，避免新旧入口重复运行。'
            ;;
        backup_failed) say '警告：旧启动脚本的 SHA-256 校验或备份失败，原文件保持不变，迁移未执行。' ;;
        none|migrated|restored) ;;
        *) say '警告：旧启动脚本状态无法确认；原入口保持原样。' ;;
    esac
    printf '%s\n' "$BACKUP_DIR" > "$KS_DIR/var/apipv6/last-backup" || abort_install '无法记录升级备份目录。'
    chmod 600 "$KS_DIR/var/apipv6/last-backup" 2>/dev/null || :
    release_lock
    if [ "$sw_mode" = 3 ] && [ "$wlc_psta" = 0 ]; then
        say 'AP 模式已通过 sw_mode=3、wlc_psta=0 检测。'
    else
        say "当前 sw_mode=${sw_mode:-unknown}、wlc_psta=$wlc_psta；插件只允许只读诊断，直到确认 AP 模式。"
    fi
    say "AP IPv6 Manager v$PLUGIN_VERSION 安装成功；本次安装没有修改网络配置。"
    say "当前设置：开机自动修复$(switch_label apipv6_enabled)；周期检查$(switch_label apipv6_health_enabled)；异常自动修复$(switch_label apipv6_repair_on_error)。"
    say '新安装默认关闭自动任务；升级保留原设置。安装完成不代表 Web 通信或 IPv6 实机验收通过。'
    say "升级备份：$BACKUP_DIR"
    say "手动回滚：/bin/sh $KS_DIR/scripts/apipv6_rollback.sh $BACKUP_DIR"
    [ "$migration_status" != known_pending ] || say '已识别的旧 V00 启动脚本会在启用自动修复并确认一次修复成功后迁移。'
    return 0
}

main "$@"
