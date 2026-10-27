#!/bin/sh

make_path_without_firmware_commands() {
    restricted_path=$1
    mkdir -p "$restricted_path"
    for mock in "$ROOT"/tests/mocks/*; do
        case "${mock##*/}" in ip|nvram|dbus) continue ;; esac
        cp "$mock" "$restricted_path/${mock##*/}"
    done

    for utility in awk cat chmod cp date df dirname grep ln mkdir mktemp mv rm rmdir \
        sed sha256sum sh sleep tail tr wc; do
        utility_path=$(command -v "$utility" 2>/dev/null) || continue
        ln -s "$utility_path" "$restricted_path/$utility"
    done
}
