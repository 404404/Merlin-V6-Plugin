#!/bin/sh
# Safe KoolShare installer for EasyTier plugin 1.0.1.
PLUGIN_VERSION=1.0.1
CORE_VERSION=2.6.4
KS_DIR=${KS_DIR:-/koolshare}
PATH=${PATH:+$PATH:}$KS_DIR/bin:$KS_DIR/scripts:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TMP_ROOT=${EASYTIER_TMP_ROOT:-/tmp}
SOURCE_DIR=${SOURCE_DIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}
BASE_SH=$KS_DIR/scripts/base.sh
if [ -r "$BASE_SH" ]; then . "$BASE_SH"; fi

say() {
    printf '%s %s\n' "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)]" "$*"
}

abort_install() {
    say "错误：$*"
    if [ "${BACKUP_READY:-0}" = 1 ]; then
        sh "$KS_DIR/scripts/easytier_rollback.sh" "$BACKUP_DIR" >/dev/null 2>&1 ||
            restore_backup "$BACKUP_DIR"
    fi
    if [ "${NEW_CORE:-0}" = 1 ]; then
        rm -f "$KS_DIR/bin/easytier-core"
    fi
    release_install_lock
    if [ "${BACKUP_READY:-0}" = 1 ]; then
        say "安装已回滚。备份目录：$BACKUP_DIR"
        say "如需手动恢复，执行：sh $KS_DIR/scripts/easytier_rollback.sh $BACKUP_DIR"
    else
        say "安装检查失败，尚未替换插件文件；无需回滚。"
    fi
    exit 1
}

restore_backup() {
    backup=$1
    [ -r "$backup/manifest" ] || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            /*|*../*) return 1 ;;
        esac
        if [ -f "$backup/$rel" ]; then
            mkdir -p "$KS_DIR/$(dirname "$rel")" || return 1
            cp -p "$backup/$rel" "$KS_DIR/$rel.restore.$$" || return 1
            mv -f "$KS_DIR/$rel.restore.$$" "$KS_DIR/$rel" || return 1
        elif grep -Fx "$rel" "$backup/absent" >/dev/null 2>&1; then
            rm -f "$KS_DIR/$rel" || return 1
        fi
    done < "$backup/manifest"
}

acquire_install_lock() {
    mkdir -p "$TMP_ROOT" || return 1
    tries=0
    while [ "$tries" -lt 10 ]; do
        if mkdir "$TMP_ROOT/easytier-install.lock" 2>/dev/null; then
            INSTALL_LOCK_HELD=1
            printf '%s\n' "$$" > "$TMP_ROOT/easytier-install.lock/pid" || {
                rm -f "$TMP_ROOT/easytier-install.lock/pid"
                rmdir "$TMP_ROOT/easytier-install.lock" 2>/dev/null || :
                INSTALL_LOCK_HELD=0
                return 1
            }
            return 0
        fi
        owner=
        [ -r "$TMP_ROOT/easytier-install.lock/pid" ] &&
            IFS= read -r owner < "$TMP_ROOT/easytier-install.lock/pid"
        case "$owner" in
            ''|*[!0-9]*) ;;
            *) if kill -0 "$owner" 2>/dev/null; then return 1; fi ;;
        esac
        if [ "$tries" -ge 1 ]; then
            rm -f "$TMP_ROOT/easytier-install.lock/pid" 2>/dev/null || :
            rmdir "$TMP_ROOT/easytier-install.lock" 2>/dev/null || :
        fi
        tries=$((tries + 1))
    done
    return 1
}

release_install_lock() {
    [ "${INSTALL_LOCK_HELD:-0}" = 1 ] || return 0
    owner=
    if [ -r "$TMP_ROOT/easytier-install.lock/pid" ]; then
        IFS= read -r owner < "$TMP_ROOT/easytier-install.lock/pid" || :
    fi
    if [ "$owner" = "$$" ]; then
        rm -f "$TMP_ROOT/easytier-install.lock/pid"
        rmdir "$TMP_ROOT/easytier-install.lock" 2>/dev/null || :
    fi
    INSTALL_LOCK_HELD=0
}

backup_targets() {
    : > "$BACKUP_DIR/manifest" || return 1
    : > "$BACKUP_DIR/absent" || return 1
    for rel in \
        scripts/easytier_config.sh \
        scripts/uninstall_easytier.sh \
        scripts/easytier_rollback.sh \
        webs/Module_easytier.asp \
        res/icon-easytier.png \
        config.json.js \
        init.d/V99easytier.sh \
        init.d/S99easytier.sh \
        init.d/N99easytier.sh
    do
        printf '%s\n' "$rel" >> "$BACKUP_DIR/manifest" || return 1
        if [ -f "$KS_DIR/$rel" ]; then
            mkdir -p "$BACKUP_DIR/$(dirname "$rel")" || return 1
            cp -p "$KS_DIR/$rel" "$BACKUP_DIR/$rel" || return 1
        else
            printf '%s\n' "$rel" >> "$BACKUP_DIR/absent" || return 1
        fi
    done
}

install_file() {
    source=$1
    target=$2
    mode=$3
    mkdir -p "$(dirname "$target")" || return 1
    cp "$source" "$target.easytier-new.$$" || {
        rm -f "$target.easytier-new.$$"
        return 1
    }
    chmod "$mode" "$target.easytier-new.$$" || {
        rm -f "$target.easytier-new.$$"
        return 1
    }
    mv -f "$target.easytier-new.$$" "$target" || {
        rm -f "$target.easytier-new.$$"
        return 1
    }
}

check_arch() {
    ARCH=${EASYTIER_TEST_ARCH:-$(uname -m)}
    case "$ARCH" in
        aarch64|arm64) CORE_SOURCE=$SOURCE_DIR/bin/easytier-core_arm64 ;;
        armv7l) CORE_SOURCE=$SOURCE_DIR/bin/easytier-core_arm32 ;;
        *)
            say "不支持的处理器架构：$ARCH（支持 aarch64 和 armv7l）"
            return 1
            ;;
    esac
    [ -f "$CORE_SOURCE" ] || {
        say "安装包缺少 $ARCH 对应核心：$CORE_SOURCE"
        return 1
    }
}

main() {
    # Some Merlin ash builds omit the command builtin but provide type.
    type dbus >/dev/null 2>&1 || abort_install "固件缺少必要命令：dbus，无法登记插件版本"
    [ -f "$SOURCE_DIR/install.sh" ] || abort_install "找不到安装包目录：$SOURCE_DIR"
    [ -f "$SOURCE_DIR/core-version.txt" ] || abort_install "安装包缺少 core-version.txt"
    package_platform=$(cat "$SOURCE_DIR/.valid" 2>/dev/null)
    case "$package_platform" in
        hnd|qca) ;;
        *) abort_install "安装包缺少有效的 HND/QCA .valid 平台标记" ;;
    esac
    packaged_core_version=$(cat "$SOURCE_DIR/core-version.txt" 2>/dev/null)
    [ "$packaged_core_version" = "$CORE_VERSION" ] ||
        abort_install "核心构建版本不匹配：安装器=$CORE_VERSION，包=$packaged_core_version"
    check_arch || abort_install "无法选择此设备的 EasyTier 核心"

    for required in \
        config.json.js scripts/easytier_config.sh webs/Module_easytier.asp \
        uninstall.sh rollback.sh init.d/V99easytier.sh \
        init.d/S99easytier.sh init.d/N99easytier.sh res/easytier.png
    do
        [ -f "$SOURCE_DIR/$required" ] || abort_install "安装包缺少文件：$required"
    done

    acquire_install_lock || abort_install "另一个安装任务正在运行"
    mkdir -p "$KS_DIR/bin" "$KS_DIR/scripts" "$KS_DIR/webs" "$KS_DIR/res" "$KS_DIR/init.d" "$KS_DIR/configs" ||
        abort_install "无法创建 KoolShare 目录"
    available=$(df -Pk "$KS_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    required_kb=1024
    if [ ! -e "$KS_DIR/bin/easytier-core" ] && [ ! -L "$KS_DIR/bin/easytier-core" ]; then
        core_bytes=$(wc -c < "$CORE_SOURCE" 2>/dev/null | tr -d ' ')
        case "$core_bytes" in
            ''|*[!0-9]*) abort_install "无法读取核心文件大小" ;;
        esac
        required_kb=$(( (core_bytes + 1023) / 1024 + 1024 ))
    fi
    case "$available" in
        ''|*[!0-9]*) ;;
        *) [ "$available" -ge "$required_kb" ] ||
            abort_install "JFFS 可用空间不足：需要约 $required_kb KB，当前 $available KB" ;;
    esac

    stamp=$(date '+%Y%m%d%H%M%S' 2>/dev/null)
    BACKUP_DIR=$KS_DIR/backup/easytier/$stamp-$$
    mkdir -p "$BACKUP_DIR" || abort_install "无法建立升级备份目录"
    backup_targets || abort_install "升级前备份失败"
    BACKUP_READY=1

    CORE_TARGET=$KS_DIR/bin/easytier-core
    if [ ! -e "$CORE_TARGET" ] && [ ! -L "$CORE_TARGET" ]; then
        say "新安装：复制官方 EasyTier 核心 v$CORE_VERSION（来源：github.com/EasyTier/EasyTier）"
        install_file "$CORE_SOURCE" "$CORE_TARGET" 755 || abort_install "复制官方核心失败"
        NEW_CORE=1
    else
        say "升级：保留现有 easytier-core，不替换也不查询版本"
    fi

    install_file "$SOURCE_DIR/scripts/easytier_config.sh" "$KS_DIR/scripts/easytier_config.sh" 755 ||
        abort_install "安装服务脚本失败"
    install_file "$SOURCE_DIR/uninstall.sh" "$KS_DIR/scripts/uninstall_easytier.sh" 755 ||
        abort_install "安装卸载脚本失败"
    install_file "$SOURCE_DIR/rollback.sh" "$KS_DIR/scripts/easytier_rollback.sh" 755 ||
        abort_install "安装回滚脚本失败"
    install_file "$SOURCE_DIR/webs/Module_easytier.asp" "$KS_DIR/webs/Module_easytier.asp" 644 ||
        abort_install "安装 Web 页面失败"
    install_file "$SOURCE_DIR/res/easytier.png" "$KS_DIR/res/icon-easytier.png" 644 ||
        abort_install "安装图标失败"
    install_file "$SOURCE_DIR/config.json.js" "$KS_DIR/config.json.js" 644 ||
        abort_install "安装软件中心元数据失败"
    install_file "$SOURCE_DIR/init.d/V99easytier.sh" "$KS_DIR/init.d/V99easytier.sh" 755 ||
        abort_install "安装 services-start 启动入口失败"
    install_file "$SOURCE_DIR/init.d/S99easytier.sh" "$KS_DIR/init.d/S99easytier.sh" 755 ||
        abort_install "安装 wan-start 入口失败"
    install_file "$SOURCE_DIR/init.d/N99easytier.sh" "$KS_DIR/init.d/N99easytier.sh" 755 ||
        abort_install "安装 nat-start 入口失败"

    # Never write easytier.conf, identity fields, peer fields, easytier_autostart,
    # or any other EasyTier runtime DBUS configuration during installation.
    old_plugin_version=$(dbus get softcenter_module_easytier_version 2>/dev/null)
    if ! dbus set softcenter_module_easytier_version="$PLUGIN_VERSION" ||
        [ "$(dbus get softcenter_module_easytier_version 2>/dev/null)" != "$PLUGIN_VERSION" ]; then
        if [ -n "$old_plugin_version" ]; then
            dbus set softcenter_module_easytier_version="$old_plugin_version" >/dev/null 2>&1 || :
        else
            dbus remove softcenter_module_easytier_version >/dev/null 2>&1 || :
        fi
        abort_install "软件中心插件版本号登记失败（目标版本：$PLUGIN_VERSION）"
    fi
    dbus set softcenter_module_easytier_install=1 ||
        say "警告：软件中心安装状态写入失败"
    dbus set softcenter_module_easytier_name=easytier ||
        say "警告：软件中心模块名称写入失败"
    dbus set softcenter_module_easytier_title=EasyTier ||
        say "警告：软件中心显示名称写入失败"
    dbus set softcenter_module_easytier_description="简单、安全、去中心化的内网穿透 VPN" ||
        say "警告：软件中心描述写入失败"

    release_install_lock
    say "EasyTier 插件 v$PLUGIN_VERSION 安装完成。核心版本：保留设备现状（未知）"
    say "没有重启或启动正在运行的服务。配置和自启动 DBUS 值均已保留。"
    say "备份目录：$BACKUP_DIR"
    say "手动回滚：sh $KS_DIR/scripts/easytier_rollback.sh $BACKUP_DIR"
    return 0
}

BACKUP_READY=0
NEW_CORE=0
BACKUP_DIR=
INSTALL_LOCK_HELD=0
main "$@"
exit $?
