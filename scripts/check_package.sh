#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apipv6-package-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM

cd "$ROOT"
[ -s apipv6_hnd.tar.gz ] || { echo 'Missing or empty apipv6_hnd.tar.gz' >&2; exit 1; }
[ -s apipv6_qca.tar.gz ] || { echo 'Missing or empty apipv6_qca.tar.gz' >&2; exit 1; }
[ -s SHA256SUMS ] || { echo 'Missing or empty SHA256SUMS' >&2; exit 1; }
sha256sum --check SHA256SUMS

for platform in hnd qca; do
    archive="apipv6_$platform.tar.gz"
    listing="$CHECK_DIR/$platform.list"
    tar -tzf "$archive" > "$listing"
    while IFS= read -r entry; do
        case "$entry" in /*|../*|*/../*|*/..) echo "Unsafe package path: $entry" >&2; exit 1 ;; esac
        case "$entry" in apipv6/*) ;; *) echo "Unexpected package root: $entry" >&2; exit 1 ;; esac
    done < "$listing"
    mkdir -p "$CHECK_DIR/$platform"
    tar -xzf "$archive" -C "$CHECK_DIR/$platform"
    root="$CHECK_DIR/$platform/apipv6"
    [ "$(cat "$root/.valid" | tr -d '\r\n')" = "$platform" ] || { echo "Wrong .valid marker in $archive" >&2; exit 1; }
    for required in \
        install.sh uninstall.sh rollback.sh config.json.js \
        scripts/apipv6_config.sh scripts/apipv6_migrate.sh \
        scripts/apipv6_status.sh scripts/apipv6_repair.sh \
        webs/Module_apipv6.asp res/apipv6.png init.d/V99apipv6.sh
    do
        [ -f "$root/$required" ] || { echo "Missing $required in $archive" >&2; exit 1; }
    done
    for executable in install.sh uninstall.sh rollback.sh \
        scripts/apipv6_config.sh scripts/apipv6_migrate.sh \
        scripts/apipv6_status.sh scripts/apipv6_repair.sh init.d/V99apipv6.sh
    do
        [ -x "$root/$executable" ] || { echo "Not executable in archive: $executable" >&2; exit 1; }
        sh -n "$root/$executable"
    done
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$root/config.json.js" >/dev/null
    else
        perl -MJSON::PP -e 'local $/; decode_json(<>)' "$root/config.json.js"
    fi
    metadata_version=$(sed -n 's/^[[:space:]]*"plugin_version":[[:space:]]*"\([^"]*\)".*/\1/p' "$root/config.json.js")
    script_version=$(sed -n 's/^PLUGIN_VERSION=//p' "$root/scripts/apipv6_config.sh" | head -n 1)
    [ "$metadata_version" = "$script_version" ] || { echo "Version mismatch in $archive" >&2; exit 1; }
    if find "$root" -type f | grep -Ei 'easytier|module_easytier'; then
        echo "Legacy plugin file found in $archive" >&2
        exit 1
    fi
    if grep -R -E 'easytier-core|easytier_|Module_easytier\.asp' "$root" >/dev/null 2>&1; then
        echo "Legacy plugin reference found in $archive" >&2
        exit 1
    fi
    png_signature=$(od -An -t x1 -N 8 "$root/res/apipv6.png" | tr -d ' \n')
    [ "$png_signature" = 89504e470d0a1a0a ] || { echo 'Invalid PNG signature' >&2; exit 1; }
    echo "$archive: package layout, scripts, metadata, platform marker, and PNG verified"
done
