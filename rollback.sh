#!/bin/sh
KS_DIR=${KS_DIR:-/koolshare}
BACKUP_ROOT=${EASYTIER_BACKUP_ROOT:-$KS_DIR/backup/easytier}

say() { printf '%s %s\n' "[EasyTier rollback]" "$*"; }

backup=${1:-}
if [ -z "$backup" ]; then
    for candidate in "$BACKUP_ROOT"/*; do
        [ -d "$candidate" ] || continue
        [ -r "$candidate/manifest" ] || continue
        if [ -z "$backup" ] || [ "$candidate" \> "$backup" ]; then
            backup=$candidate
        fi
    done
fi
case "$backup" in
    "$BACKUP_ROOT"/*) ;;
    *) say "错误：备份目录必须位于 $BACKUP_ROOT"; exit 2 ;;
esac
[ -r "$backup/manifest" ] || { say "错误：未找到有效备份：$backup"; exit 1; }

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
        /*|*../*) say "错误：备份清单包含非法路径"; exit 1 ;;
    esac
    target=$KS_DIR/$rel
    if [ -f "$backup/$rel" ]; then
        mkdir -p "$(dirname "$target")" || exit 1
        cp -p "$backup/$rel" "$target.restore.$$" || exit 1
        mv -f "$target.restore.$$" "$target" || exit 1
    elif grep -Fx "$rel" "$backup/absent" >/dev/null 2>&1; then
        rm -f "$target" || exit 1
    fi
done < "$backup/manifest"

say "脚本、Web 页面和启动入口已恢复自 $backup"
say "核心、配置文件、网络身份和 DBUS 配置未修改；服务未自动重启。"
