ARCH := $(shell uname -m)
EXTENSION_SCHEMES := DevonthinkExtension
DESTINATION := generic/platform=macOS
DEV_DESTINATION := platform=macOS,arch=$(ARCH)
DERIVED_DATA := ./build/dd
INSTALL_DIR := $(HOME)/Library/Application Support/Tuna/ExtensionsDev

.DEFAULT_GOAL := build-all
.PHONY: build-all ext ext-all clean

define require_target
	@test -n "$(TARGET)" || { echo "usage: make $@ TARGET=<Scheme>" >&2; exit 64; }
endef

# Compile every extension in Release.
build-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; ./scripts/tuna-extension build --scheme "$$SCHEME" --release >/dev/null; done; echo "All extensions build."

# Build one extension and install it into Tuna's ExtensionsDev for local development.
ext:
	$(require_target)
	@./scripts/tuna-extension install --scheme "$(TARGET)"

# Dev-install every extension.
ext-all:
	@set -e; for SCHEME in $(EXTENSION_SCHEMES); do echo "=== $$SCHEME ==="; ./scripts/tuna-extension install --scheme "$$SCHEME"; done

clean:
	rm -rf ./build
