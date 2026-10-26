#!/bin/sh
CONFIG=${APIPV6_CONFIG_SCRIPT:-/koolshare/scripts/apipv6_config.sh}
exec "$CONFIG" status "$@"
