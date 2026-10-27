#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

for file in "$ROOT/install.sh" "$ROOT/scripts/apipv6_config.sh"; do
    grep -Fq '${APIPV6_NVRAM_SEARCH_DIRS:-/usr/sbin:/sbin:/usr/bin:/bin}' "$file" || {
        printf 'Default nvram firmware search paths are missing from %s\n' "${file#"$ROOT"/}" >&2
        exit 1
    }
done

printf '%s\n' 'nvram resolution regression test passed for standard firmware paths.'
