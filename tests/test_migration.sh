#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/helpers.sh"
MIGRATE=$ROOT/scripts/apipv6_migrate.sh
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/apipv6-migrate-test.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
export APIPV6_KS_DIR=$TEMP/koolshare
export APIPV6_RUN_DIR=$APIPV6_KS_DIR/var/apipv6
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$APIPV6_KS_DIR/init.d"

"$MIGRATE" inspect
grep -q '^status=none$' "$APIPV6_RUN_DIR/migration-state" || fail 'missing legacy file should be recorded as none'

cat > "$APIPV6_KS_DIR/init.d/V00apipv6.sh" <<'EOF'
#!/bin/sh
echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/br0/autoconf
echo 2 > /proc/sys/net/ipv6/conf/br0/accept_ra
EOF
chmod 755 "$APIPV6_KS_DIR/init.d/V00apipv6.sh"
known_hash=$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")
"$MIGRATE" inspect
grep -q '^status=known_pending$' "$APIPV6_RUN_DIR/migration-state" || fail 'strictly recognized legacy script should be pending'
grep -q "^sha256=$known_hash$" "$APIPV6_RUN_DIR/migration-state" || fail 'legacy SHA-256 was not recorded'
backup_dir=$(awk -F= '$1 == "backup_dir" {sub(/^[^=]*=/, ""); print}' "$APIPV6_RUN_DIR/migration-state")
[ -f "$backup_dir/V00apipv6.sh" ] || fail 'recognized legacy script was not backed up'
cmp -s "$APIPV6_KS_DIR/init.d/V00apipv6.sh" "$backup_dir/V00apipv6.sh" || fail 'legacy backup content differs'

"$MIGRATE" deactivate >/dev/null
[ ! -e "$APIPV6_KS_DIR/init.d/V00apipv6.sh" ] || fail 'known legacy entry was not deactivated'
[ -f "$backup_dir/V00apipv6.sh.migrated" ] || fail 'migrated original was not retained'
"$MIGRATE" restore
cmp -s "$APIPV6_KS_DIR/init.d/V00apipv6.sh" "$backup_dir/V00apipv6.sh" || fail 'migrated startup script was not restored'
grep -q '^status=restored$' "$APIPV6_RUN_DIR/migration-state" || fail 'restore state was not recorded'

# Never deactivate a user script that has any additional executable content.
cat > "$APIPV6_KS_DIR/init.d/V00apipv6.sh" <<'EOF'
#!/bin/sh
echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/br0/autoconf
echo 2 > /proc/sys/net/ipv6/conf/br0/accept_ra
ip -6 route flush default
EOF
custom_hash=$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")
"$MIGRATE" inspect
grep -q '^status=conflict$' "$APIPV6_RUN_DIR/migration-state" || fail 'custom script should be marked as a conflict'
"$MIGRATE" deactivate >/dev/null 2>&1 && fail 'custom script was accepted for migration'
expect_hash=$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")
[ "$expect_hash" = "$custom_hash" ] || fail 'custom script changed during migration inspection'
"$MIGRATE" restore >/dev/null 2>&1 && fail 'custom script conflict should prevent automatic restore'

# A backup failure leaves the original path and bytes in place.
rm -rf "$APIPV6_KS_DIR/backup"
cat > "$APIPV6_KS_DIR/init.d/V00apipv6.sh" <<'EOF'
#!/bin/sh
echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
echo 1 > /proc/sys/net/ipv6/conf/br0/autoconf
echo 2 > /proc/sys/net/ipv6/conf/br0/accept_ra
EOF
chmod 755 "$APIPV6_KS_DIR/init.d/V00apipv6.sh"
backup_failure_hash=$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")
printf 'cannot-create-backup\n' > "$APIPV6_KS_DIR/backup"
"$MIGRATE" inspect >/dev/null 2>&1 && fail 'migration unexpectedly succeeded when backup root was a file'
grep -q '^status=backup_failed$' "$APIPV6_RUN_DIR/migration-state" || fail 'backup failure state was not recorded'
[ "$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")" = "$backup_failure_hash" ] || fail 'backup failure modified the original script'

# A failed or malformed SHA-256 provider must never authorize migration.
rm -f "$APIPV6_KS_DIR/backup"
mkdir -p "$TEMP/hash-tools"
cat > "$TEMP/hash-tools/sha256sum" <<'EOF'
#!/bin/sh
[ "${MOCK_HASH_FAILURE:-0}" = 1 ] && exit 1
printf '%s\n' 'invalid-digest'
EOF
chmod 755 "$TEMP/hash-tools/sha256sum"
for hash_failure in 0 1; do
    PATH="$TEMP/hash-tools:$PATH" MOCK_HASH_FAILURE=$hash_failure "$MIGRATE" inspect >/dev/null 2>&1 &&
        fail 'a failed/malformed hash was accepted for migration'
    grep -q '^status=backup_failed$' "$APIPV6_RUN_DIR/migration-state" || fail 'hash failure state was not recorded'
    [ "$(test_hash "$APIPV6_KS_DIR/init.d/V00apipv6.sh")" = "$backup_failure_hash" ] || fail 'hash failure modified the original script'
done

printf '%s\n' 'Legacy migration tests passed: absent, strict match, hash backup, deactivation, restore, custom conflict, and backup failure.'
