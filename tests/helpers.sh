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
        utility_description=$(type "$utility" 2>/dev/null) || continue
        utility_path=${utility_description#* is }
        [ -x "$utility_path" ] || continue
        ln -s "$utility_path" "$restricted_path/$utility"
    done
}

# Independent reference implementation for migration/rollback assertions.
test_hash() {
    perl -MDigest::SHA -e '
        open my $file, "<", $ARGV[0] or die $!;
        binmode $file;
        print Digest::SHA->new(256)->addfile($file)->hexdigest, "\n";
    ' "$1"
}
