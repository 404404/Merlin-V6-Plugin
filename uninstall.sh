#!/bin/sh
KS_DIR=${KS_DIR:-/koolshare}
PATH=${PATH:+$PATH:}$KS_DIR/bin:$KS_DIR/scripts:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
CONFIG_SCRIPT=${EASYTIER_CONFIG_SCRIPT:-$KS_DIR/scripts/easytier_config.sh}
if [ -r "$KS_DIR/scripts/base.sh" ]; then . "$KS_DIR/scripts/base.sh"; fi
say() { printf '%s %s\n' "[EasyTier]" "$*"; }

if [ -x "$CONFIG_SCRIPT" ]; then
    sh "$CONFIG_SCRIPT" stop || {
        say "停止失败；保留其余文件以便排查。"
        exit 1
    }
fi

# These paths are owned by this plugin. The core, config and runtime DBUS
# values are deliberately retained because they may contain user-managed data.
rm -f "$KS_DIR/scripts/easytier_config.sh"
rm -f "$KS_DIR/scripts/easytier_nodes.sh"
rm -f "$KS_DIR/bin/easytier-cli-plugin"
rm -f "$KS_DIR/res/easytier_nodes.js"
rm -f "$KS_DIR/scripts/uninstall_easytier.sh"
rm -f "$KS_DIR/webs/Module_easytier.asp"
rm -f "$KS_DIR/res/icon-easytier.png"
rm -f "$KS_DIR/config.json.js"
rm -f "$KS_DIR/init.d/V99easytier.sh"
rm -f "$KS_DIR/init.d/S99easytier.sh"
rm -f "$KS_DIR/init.d/N99easytier.sh"

if type dbus >/dev/null 2>&1; then
    dbus remove softcenter_module_easytier_version
    dbus remove softcenter_module_easytier_install
    dbus remove softcenter_module_easytier_name
    dbus remove softcenter_module_easytier_title
    dbus remove softcenter_module_easytier_description
fi

say "插件脚本已卸载。easytier-core、easytier.conf、EasyTier DBUS 配置、备份和回滚工具均已保留。"
say "若要恢复上一个版本：sh $KS_DIR/scripts/easytier_rollback.sh <备份目录>"
