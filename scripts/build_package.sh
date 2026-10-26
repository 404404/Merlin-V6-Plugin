#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build_tmp}
PLUGIN_VERSION=${PLUGIN_VERSION:-0.1.0}

metadata_version=$(sed -n 's/^[[:space:]]*"plugin_version":[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/config.json.js")
script_version=$(sed -n 's/^PLUGIN_VERSION=//p' "$ROOT/scripts/apipv6_config.sh" | head -n 1)
[ "$PLUGIN_VERSION" = "$metadata_version" ] || { printf 'Metadata version %s does not match requested %s.\n' "$metadata_version" "$PLUGIN_VERSION" >&2; exit 1; }
[ "$PLUGIN_VERSION" = "$script_version" ] || { printf 'Script version %s does not match requested %s.\n' "$script_version" "$PLUGIN_VERSION" >&2; exit 1; }

build_packages() {
    cd "$ROOT"
    rm -rf "$BUILD_DIR" apipv6_hnd.tar.gz apipv6_qca.tar.gz SHA256SUMS
    for platform in hnd qca; do
        stage=$BUILD_DIR/$platform
        root=$stage/apipv6
        mkdir -p "$root/scripts" "$root/webs" "$root/res" "$root/init.d" "$root/docs"
        cp install.sh uninstall.sh rollback.sh config.json.js README.md CHANGELOG.md "$root/"
        cp scripts/apipv6_config.sh scripts/apipv6_migrate.sh scripts/apipv6_status.sh scripts/apipv6_repair.sh "$root/scripts/"
        cp webs/Module_apipv6.asp "$root/webs/"
        cp res/apipv6.png "$root/res/"
        cp init.d/V99apipv6.sh "$root/init.d/"
        cp docs/AX56U-ACCEPTANCE.md "$root/docs/"
        printf '%s\n' "$platform" > "$root/.valid"
        chmod 755 "$root/install.sh" "$root/uninstall.sh" "$root/rollback.sh" \
            "$root/scripts/"*.sh "$root/init.d/"*.sh
        chmod 644 "$root/config.json.js" "$root/README.md" "$root/CHANGELOG.md" \
            "$root/webs/Module_apipv6.asp" "$root/res/apipv6.png" "$root/.valid"
        tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
            -czf "$ROOT/apipv6_$platform.tar.gz" -C "$stage" apipv6
    done
    (cd "$ROOT" && sha256sum apipv6_hnd.tar.gz apipv6_qca.tar.gz > SHA256SUMS)
    printf 'Built AP IPv6 Manager v%s HND and QCA packages.\n' "$PLUGIN_VERSION"
}

case "${1:-all}" in
    package|all) build_packages ;;
    clean) rm -rf "$BUILD_DIR" "$ROOT/apipv6_hnd.tar.gz" "$ROOT/apipv6_qca.tar.gz" "$ROOT/SHA256SUMS" ;;
    *) printf '%s\n' 'Usage: build_package.sh [clean|package|all]' >&2; exit 2 ;;
esac
