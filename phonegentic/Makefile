CRED_FILE := lib/src/test_credentials_local.dart

.PHONY: setup run build clean

setup: $(CRED_FILE)

$(CRED_FILE):
	@echo "⚙  Generating stub credentials file..."
	@dart tool/ensure_credentials.dart

run: setup
	flutter run

build: setup
	flutter build macos

clean:
	flutter clean
