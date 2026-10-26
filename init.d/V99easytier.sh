#!/bin/sh
# services-start path: queue an IPv4-aware autostart check and return immediately.
CONFIG_SCRIPT=${EASYTIER_CONFIG_SCRIPT:-/koolshare/scripts/easytier_config.sh}
case "${1:-}" in
    ''|start|services-start|services_start|services_start.sh)
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
