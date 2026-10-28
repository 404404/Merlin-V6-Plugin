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
    grep -F '"version": "1.1.0"' "$work/easytier/config.json.js" >/dev/null
    grep -F '"plugin_version": "1.1.0"' "$work/easytier/config.json.js" >/dev/null
    grep -F '"core_version": "2.6.4"' "$work/easytier/config.json.js" >/dev/null
    test -x "$work/easytier/install.sh"
    test -x "$work/easytier/bin/easytier-core_arm32"
    test -x "$work/easytier/bin/easytier-core_arm64"
    test -x "$work/easytier/bin/easytier-cli_arm32"
    test -x "$work/easytier/bin/easytier-cli_arm64"
    test -x "$work/easytier/scripts/easytier_nodes.sh"
    test -s "$work/easytier/res/easytier_nodes.js"
    test -x "$work/easytier/scripts/easytier_config.sh"
    test -x "$work/easytier/init.d/V99easytier.sh"
    test -x "$work/easytier/init.d/S99easytier.sh"
    test -x "$work/easytier/init.d/N99easytier.sh"
    grep -F 'armv7l)' "$work/easytier/install.sh" >/dev/null
    if [ "${EASYTIER_VERIFY_OFFICIAL:-0}" = 1 ]; then
        python3 - "$work/easytier/bin" <<'PY'
import hashlib, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
core_hashes = {
    'arm32': '7f1040fec526ded3990663aa19dabb028fea52a6c6b06ddc1de32668829934b9',
    'arm64': '7bd504e87cad52edacb9ea84ece7397d0afb911101de623a3dfc4a4dbd9e6bb6',
}
for arch, elf_class, machine in [('arm32', 1, 40), ('arm64', 2, 183)]:
    for kind in ['core', 'cli']:
        data = (root / ('easytier-' + kind + '_' + arch)).read_bytes()
        assert data[:4] == b'\x7fELF' and data[4] == elf_class and data[5] == 1
        assert struct.unpack('<H', data[18:20])[0] == machine
        if kind == 'core':
            assert hashlib.sha256(data).hexdigest() == core_hashes[arch]
print('Official ARM core fingerprints and core/CLI ELF architectures verified')
PY
    fi
    rm -rf "$work"
    echo "Package structure and permissions OK: $archive"
done

sha256sum --check SHA256SUMS
