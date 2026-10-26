#!/bin/sh
# KoolShare V99 hook: launch a bounded background check, never hold boot open.
CONFIG=${APIPV6_CONFIG_SCRIPT:-/koolshare/scripts/apipv6_config.sh}
[ -x "$CONFIG" ] || exit 0
"$CONFIG" boot >/dev/null 2>&1 </dev/null &
exit 0
