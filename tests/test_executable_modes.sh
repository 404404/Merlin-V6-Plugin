#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

check_executable_mode() {
    file=$1
    relative=${file#"$ROOT"/}
    [ -x "$file" ] || {
        printf 'Not executable in checkout: %s\n' "$relative" >&2
        exit 1
    }

    mode=$(git -C "$ROOT" ls-files -s -- "$relative" | awk 'NR == 1 { print $1 }')
    [ "$mode" = 100755 ] || {
        printf 'Git index mode for %s is %s, expected 100755\n' "$relative" "${mode:-missing}" >&2
        exit 1
    }
}

for file in "$ROOT"/*.sh "$ROOT"/scripts/*.sh "$ROOT"/init.d/*.sh \
    "$ROOT"/tests/*.sh "$ROOT"/tests/mocks/*
do
    [ -f "$file" ] || continue
    check_executable_mode "$file"
done

printf '%s\n' 'Executable mode regression test passed for shell scripts, startup hook, and Mock commands.'
