#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
sh "$ROOT/tests/test_executable_modes.sh"
sh "$ROOT/tests/test_nvram_resolution.sh"
sh "$ROOT/tests/test_cli.sh"
sh "$ROOT/tests/test_migration.sh"
sh "$ROOT/tests/test_lifecycle.sh"
printf '%s\n' 'All shell integration tests passed.'
