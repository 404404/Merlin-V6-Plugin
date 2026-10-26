#!/bin/sh
# wan-start path. Do not block other KoolShare plugins.
CONFIG_SCRIPT=${EASYTIER_CONFIG_SCRIPT:-/koolshare/scripts/easytier_config.sh}
case "${1:-}" in
    ''|start|wan-start|wan_start|services-start|services_start)
        ;;
    *)
        exit 0
        ;;
esac
[ -x "$CONFIG_SCRIPT" ] || exit 0
(
    nohup "$CONFIG_SCRIPT" autostart
) </dev/null >/dev/null 2>&1 &
exit 0
