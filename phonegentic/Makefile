CRED_FILE := lib/src/test_credentials_local.dart
OS := $(shell uname -s)

.PHONY: setup run run-lite build build-lite clean download-models model-status preflight

setup: $(CRED_FILE)

$(CRED_FILE):
	@echo "⚙  Generating stub credentials file..."
	@dart tool/ensure_credentials.dart

# ─── macOS ────────────────────────────────────────────────────────────

ifeq ($(OS),Darwin)

run: setup
	flutter run -d macos --dart-define=ENABLE_ON_DEVICE_MODELS=true

run-lite: setup
	flutter run -d macos

build: setup
	flutter build macos --dart-define=ENABLE_ON_DEVICE_MODELS=true

build-lite: setup
	flutter build macos

endif

# ─── Linux ────────────────────────────────────────────────────────────

ifeq ($(OS),Linux)

run: setup
	flutter run -d linux --dart-define=ENABLE_ON_DEVICE_MODELS=true

run-lite: setup
	flutter run -d linux

build: setup
	flutter build linux --dart-define=ENABLE_ON_DEVICE_MODELS=true

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
