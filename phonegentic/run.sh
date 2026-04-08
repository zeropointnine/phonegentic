#!/usr/bin/env bash
set -e

CRED_FILE="lib/src/test_credentials_local.dart"

if [ ! -f "$CRED_FILE" ]; then
  echo "⚙  First run detected — generating stub credentials file..."
  dart tool/ensure_credentials.dart
  echo ""
fi

exec flutter run "$@"
