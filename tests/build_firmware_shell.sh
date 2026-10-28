#!/bin/sh
# Build the Merlin-era ash configuration in an isolated test environment.
set -eu

OUTPUT_DIR=${1:?Usage: build_firmware_shell.sh OUTPUT_DIR}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd "$OUTPUT_DIR" && pwd)
ARCHIVE=$OUTPUT_DIR/busybox-1.25.1.tar.bz2
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --silent --show-error --location --retry 3 https://busybox.net/downloads/busybox-1.25.1.tar.bz2 -o "$ARCHIVE"
fi
printf '%s  %s\n' '27667e0f2328fdbd79cfd622e4453e5c57e58f781c5da97c9be337d93aa2a02e' "$ARCHIVE" |
    sha256sum --check -
tar -xjf "$ARCHIVE" -C "$OUTPUT_DIR"
cd "$OUTPUT_DIR/busybox-1.25.1"

# Build-only libc adaptation: modern glibc removed stime(). Keep equivalent
# date-setting semantics; this does not change ash or the applet configuration.
sed -i 's/stime(&ts\.tv_sec)/(ts.tv_nsec = 0, clock_settime(CLOCK_REALTIME, \&ts))/' coreutils/date.c

# Match the relevant shell switches in Merlin's busybox/config_base:
# command, printf, echo and test builtins are disabled; use external utilities.
cat > firmware.config <<'EOF'
CONFIG_STATIC=y
CONFIG_ASH=y
CONFIG_ASH_BASH_COMPAT=y
CONFIG_ASH_ALIAS=y
CONFIG_ASH_OPTIMIZE_FOR_SIZE=y
CONFIG_FEATURE_SH_IS_ASH=y
CONFIG_FEATURE_BASH_IS_NONE=y
CONFIG_SH_MATH_SUPPORT=y
CONFIG_FEATURE_SH_EXTRA_QUIET=y
CONFIG_AWK=y
CONFIG_FEATURE_AWK_LIBM=y
CONFIG_FEATURE_AWK_GNU_EXTENSIONS=y
CONFIG_CAT=y
CONFIG_CHMOD=y
CONFIG_CP=y
CONFIG_FEATURE_PRESERVE_HARDLINKS=y
CONFIG_DATE=y
CONFIG_DF=y
CONFIG_DIRNAME=y
CONFIG_ECHO=y
CONFIG_GREP=y
CONFIG_FEATURE_GREP_EGREP_ALIAS=y
CONFIG_FEATURE_GREP_FGREP_ALIAS=y
CONFIG_FEATURE_GREP_CONTEXT=y
CONFIG_MKDIR=y
CONFIG_MV=y
CONFIG_PRINTF=y
CONFIG_RM=y
CONFIG_RMDIR=y
CONFIG_SED=y
CONFIG_SLEEP=y
CONFIG_TAIL=y
CONFIG_FEATURE_FANCY_TAIL=y
CONFIG_TEST=y
CONFIG_FEATURE_TEST_64=y
CONFIG_TR=y
CONFIG_WC=y
EOF
if ! make KCONFIG_ALLCONFIG=firmware.config allnoconfig > "$OUTPUT_DIR/build.log" 2>&1 ||
   ! make -j2 >> "$OUTPUT_DIR/build.log" 2>&1; then
    tail -80 "$OUTPUT_DIR/build.log"
    exit 1
fi
grep -q '^# CONFIG_ASH_CMDCMD is not set$' .config
cp busybox "$OUTPUT_DIR/busybox"
cp .config "$OUTPUT_DIR/firmware.config"

# Negative control: utilities execute, but the optional lookup builtin is absent.
set +e
"$OUTPUT_DIR/busybox" ash -c 'command -v date' >/dev/null 2>&1
probe_rc=$?
set -e
[ "$probe_rc" -eq 127 ] || { printf 'Expected command lookup exit 127, got %s\n' "$probe_rc" >&2; exit 1; }
"$OUTPUT_DIR/busybox" ash -c 'date +%Y >/dev/null; type date >/dev/null'
printf '%s\n' 'Built BusyBox 1.25.1 ash and core applets: command builtin disabled.'
