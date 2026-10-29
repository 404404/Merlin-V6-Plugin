#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apipv6-package-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM

cd "$ROOT"
[ -s IPv6-Manage_hnd.tar.gz ] || { echo 'Missing or empty IPv6-Manage_hnd.tar.gz' >&2; exit 1; }
[ -s IPv6-Manage_qca.tar.gz ] || { echo 'Missing or empty IPv6-Manage_qca.tar.gz' >&2; exit 1; }
[ -s SHA256SUMS ] || { echo 'Missing or empty SHA256SUMS' >&2; exit 1; }
sha256sum --check SHA256SUMS

for platform in hnd qca; do
    archive="IPv6-Manage_$platform.tar.gz"
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
    perl -MJSON::PP -Mutf8 -e 'local $/; my $j=decode_json(<>); die "Wrong branding or module identity\n" unless $j->{module} eq "apipv6" && $j->{title} eq "IPv6管理" && $j->{description} eq "AP模式IPv6修复" && $j->{home_url} eq "Module_apipv6.asp" && $j->{version} eq $j->{plugin_version}' "$root/config.json.js"
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
    printf '%s  %s\n' 'fc5664e552a10a20454f4f63164c453104668d43fb026fbb4a23636ddbf4566f' "$root/res/apipv6.png" | sha256sum --check -
    echo "$archive: package layout, scripts, metadata, platform marker, and PNG verified"
done
