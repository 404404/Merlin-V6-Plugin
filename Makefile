PLUGIN_NAME := apipv6
PLUGIN_VERSION ?= 0.1.0
BUILD_DIR ?= build_tmp
PLATFORMS := hnd qca
OUTPUT_PKGS := $(foreach p,$(PLATFORMS),$(PLUGIN_NAME)_$(p).tar.gz)

.PHONY: all clean package checksums test-package print-version

all: clean package checksums

print-version:
	@printf 'PLUGIN_NAME=%s\nPLUGIN_VERSION=%s\n' '$(PLUGIN_NAME)' '$(PLUGIN_VERSION)'

clean:
	BUILD_DIR="$(BUILD_DIR)" sh scripts/build_package.sh clean

package:
	BUILD_DIR="$(BUILD_DIR)" PLUGIN_VERSION="$(PLUGIN_VERSION)" sh scripts/build_package.sh package

checksums: $(OUTPUT_PKGS)
	sha256sum $(OUTPUT_PKGS) > SHA256SUMS

test-package: package checksums
	sh scripts/check_package.sh
