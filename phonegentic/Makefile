CRED_FILE := lib/src/test_credentials_local.dart
BUILD_ENV := build.env
OS := $(shell uname -s)

# If build.env exists, pass it as --dart-define-from-file; otherwise all
# flags fall back to their false defaults (same as the old run-lite).
DART_DEFINES := $(wildcard $(BUILD_ENV))
DEFINE_FLAG := $(if $(DART_DEFINES),--dart-define-from-file=$(BUILD_ENV),)

.PHONY: setup run run-lite build build-lite clean download-models model-status preflight

setup: $(CRED_FILE) $(BUILD_ENV)

$(CRED_FILE):
	@echo "⚙  Generating stub credentials file..."
	@dart tool/ensure_credentials.dart

$(BUILD_ENV):
	@echo "⚙  Creating default build.env (on-device models enabled)..."
	@printf 'ENABLE_ON_DEVICE_MODELS=true\nENABLE_GITHUB_ISSUES=false\nMAC_APP_STORE_BUILD=false\n' > $(BUILD_ENV)

# ─── macOS ────────────────────────────────────────────────────────────

ifeq ($(OS),Darwin)

run: setup
	flutter run -d macos $(DEFINE_FLAG)

run-lite: setup
	flutter run -d macos

build: setup
	flutter build macos $(DEFINE_FLAG)

build-lite: setup
	flutter build macos

endif

# ─── Linux ────────────────────────────────────────────────────────────

ifeq ($(OS),Linux)

run: setup
	flutter run -d linux $(DEFINE_FLAG)

run-lite: setup
	flutter run -d linux

build: setup
	flutter build linux $(DEFINE_FLAG)

build-lite: setup
	flutter build linux

endif

# ─── Cross-platform targets ──────────────────────────────────────────

download-models:
	@bash scripts/download_models.sh

model-status:
	@bash scripts/download_models.sh status

preflight:
	@bash scripts/download_models.sh preflight

clean:
	flutter clean
