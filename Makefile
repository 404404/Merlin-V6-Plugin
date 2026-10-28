# Deterministic KoolShare packages. Core archives are pinned to official EasyTier v2.6.4.
PLUGIN_NAME := easytier
PLUGIN_VERSION ?= 1.1.0
CORE_VERSION ?= 2.6.4
BUILD_DIR ?= build_tmp
CORE_DIR ?= $(BUILD_DIR)/core
PLATFORMS := hnd qca
OUTPUT_PKGS := $(foreach p,$(PLATFORMS),$(PLUGIN_NAME)_$(p).tar.gz)

CORE_RELEASE := https://github.com/EasyTier/EasyTier/releases/download/v$(CORE_VERSION)
ARM64_ARCHIVE := easytier-linux-aarch64-v$(CORE_VERSION).zip
ARM32_ARCHIVE := easytier-linux-armv7-v$(CORE_VERSION).zip
ARM64_SHA256 := f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f
ARM32_SHA256 := 93b1d2831e45db1fd3ca1d8d68c191b300bd69d331ca1858394a0cf884363cc3

.PHONY: all clean download package checksums test-package print-versions

# Keep the order explicit so a parallel make cannot package before downloads finish.
all:
	$(MAKE) clean
	$(MAKE) download
	$(MAKE) package
	$(MAKE) checksums

print-versions:
	@printf 'PLUGIN_VERSION=%s\nCORE_VERSION=%s\n' '$(PLUGIN_VERSION)' '$(CORE_VERSION)'

clean:
	rm -rf "$(BUILD_DIR)" $(OUTPUT_PKGS) SHA256SUMS

download:
	mkdir -p "$(CORE_DIR)" "$(BUILD_DIR)/downloads/arm64" "$(BUILD_DIR)/downloads/arm32"
	curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
		"$(CORE_RELEASE)/$(ARM64_ARCHIVE)" -o "$(BUILD_DIR)/downloads/$(ARM64_ARCHIVE)"
	printf '%s  %s\n' "$(ARM64_SHA256)" "$(BUILD_DIR)/downloads/$(ARM64_ARCHIVE)" | sha256sum --check -
	unzip -q "$(BUILD_DIR)/downloads/$(ARM64_ARCHIVE)" -d "$(BUILD_DIR)/downloads/arm64"
	arm64_core=$$(find "$(BUILD_DIR)/downloads/arm64" -type f -name easytier-core -print -quit); \
		test -n "$$arm64_core"; cp "$$arm64_core" "$(CORE_DIR)/easytier-core_arm64"
	arm64_cli=$$(find "$(BUILD_DIR)/downloads/arm64" -type f -name easytier-cli -print -quit); \
		test -n "$$arm64_cli"; cp "$$arm64_cli" "$(CORE_DIR)/easytier-cli_arm64"
	curl --fail --location --retry 3 --retry-all-errors --silent --show-error \
		"$(CORE_RELEASE)/$(ARM32_ARCHIVE)" -o "$(BUILD_DIR)/downloads/$(ARM32_ARCHIVE)"
	printf '%s  %s\n' "$(ARM32_SHA256)" "$(BUILD_DIR)/downloads/$(ARM32_ARCHIVE)" | sha256sum --check -
	unzip -q "$(BUILD_DIR)/downloads/$(ARM32_ARCHIVE)" -d "$(BUILD_DIR)/downloads/arm32"
	arm32_core=$$(find "$(BUILD_DIR)/downloads/arm32" -type f -name easytier-core -print -quit); \
		test -n "$$arm32_core"; cp "$$arm32_core" "$(CORE_DIR)/easytier-core_arm32"
	arm32_cli=$$(find "$(BUILD_DIR)/downloads/arm32" -type f -name easytier-cli -print -quit); \
		test -n "$$arm32_cli"; cp "$$arm32_cli" "$(CORE_DIR)/easytier-cli_arm32"
	chmod 755 "$(CORE_DIR)/easytier-core_arm64" "$(CORE_DIR)/easytier-core_arm32" "$(CORE_DIR)/easytier-cli_arm64" "$(CORE_DIR)/easytier-cli_arm32"

package:
	@test -s "$(CORE_DIR)/easytier-core_arm64" || { echo "Missing ARM64 core in $(CORE_DIR)" >&2; exit 1; }
	@test -s "$(CORE_DIR)/easytier-core_arm32" || { echo "Missing ARMv7 core in $(CORE_DIR)" >&2; exit 1; }
	@test -s "$(CORE_DIR)/easytier-cli_arm64" && test -s "$(CORE_DIR)/easytier-cli_arm32"
	@test -f res/easytier.png || { echo "Missing plugin icon: res/easytier.png" >&2; exit 1; }
	@set -eu; \
	for platform in $(PLATFORMS); do \
		pkg="$(BUILD_DIR)/$$platform/$(PLUGIN_NAME)"; \
		rm -rf "$$pkg"; \
		mkdir -p "$$pkg/bin" "$$pkg/scripts" "$$pkg/webs" "$$pkg/res" "$$pkg/init.d"; \
		cp "$(CORE_DIR)/easytier-core_arm64" "$$pkg/bin/easytier-core_arm64"; \
		cp "$(CORE_DIR)/easytier-core_arm32" "$$pkg/bin/easytier-core_arm32"; \
		cp "$(CORE_DIR)/easytier-cli_arm64" "$$pkg/bin/easytier-cli_arm64"; \
		cp "$(CORE_DIR)/easytier-cli_arm32" "$$pkg/bin/easytier-cli_arm32"; \
		cp install.sh config.json.js uninstall.sh rollback.sh "$$pkg/"; \
		cp scripts/easytier_config.sh scripts/easytier_nodes.sh "$$pkg/scripts/"; \
		cp webs/Module_easytier.asp "$$pkg/webs/"; \
		cp res/easytier.png res/easytier_nodes.js "$$pkg/res/"; \
		cp init.d/V99easytier.sh init.d/S99easytier.sh init.d/N99easytier.sh "$$pkg/init.d/"; \
		printf '%s\n' "$(CORE_VERSION)" > "$$pkg/core-version.txt"; \
		printf '%s\n' "$$platform" > "$$pkg/.valid"; \
		chmod 755 "$$pkg/bin/"* "$$pkg/scripts/"*.sh "$$pkg/"*.sh "$$pkg/init.d/"*.sh; \
		tar -czf "$(PLUGIN_NAME)_$$platform.tar.gz" -C "$(BUILD_DIR)/$$platform" "$(PLUGIN_NAME)"; \
	done

checksums:
	sha256sum $(OUTPUT_PKGS) > SHA256SUMS

test-package:
	$(MAKE) clean
	$(MAKE) package CORE_DIR=tests/fixtures/core
	$(MAKE) checksums
