#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for platform in hnd qca; do
    archive="easytier_$platform.tar.gz"
    test -s "$archive"
    work=$(mktemp -d)
    tar -tzf "$archive" > "$work/list"
    grep -Fx "easytier/.valid" "$work/list" >/dev/null
    grep -Fx "easytier/bin/easytier-core_arm32" "$work/list" >/dev/null
    grep -Fx "easytier/bin/easytier-core_arm64" "$work/list" >/dev/null
    grep -Fx "easytier/scripts/easytier_config.sh" "$work/list" >/dev/null
    grep -Fx "easytier/webs/Module_easytier.asp" "$work/list" >/dev/null
    grep -Fx "easytier/init.d/V99easytier.sh" "$work/list" >/dev/null
    grep -Fx "easytier/init.d/S99easytier.sh" "$work/list" >/dev/null
    grep -Fx "easytier/init.d/N99easytier.sh" "$work/list" >/dev/null
    if grep -E '(^|/)easytier\.conf$|network_secret|network_name' "$work/list" >/dev/null; then
        echo "Unexpected user config or secret in $archive" >&2
        exit 1
    fi
    tar -xzf "$archive" -C "$work"
    test "$(cat "$work/easytier/.valid")" = "$platform"
    test "$(cat "$work/easytier/core-version.txt")" = "2.6.4"
    grep -F '"version": "1.0.1"' "$work/easytier/config.json.js" >/dev/null
    grep -F '"plugin_version": "1.0.1"' "$work/easytier/config.json.js" >/dev/null
    grep -F '"core_version": "2.6.4"' "$work/easytier/config.json.js" >/dev/null
    test -x "$work/easytier/install.sh"
    test -x "$work/easytier/bin/easytier-core_arm32"
    test -x "$work/easytier/bin/easytier-core_arm64"
    test -x "$work/easytier/scripts/easytier_config.sh"
    test -x "$work/easytier/init.d/V99easytier.sh"
    test -x "$work/easytier/init.d/S99easytier.sh"
    test -x "$work/easytier/init.d/N99easytier.sh"
    grep -F 'armv7l)' "$work/easytier/install.sh" >/dev/null
    rm -rf "$work"
    echo "Package structure and permissions OK: $archive"
done

sha256sum --check SHA256SUMS
