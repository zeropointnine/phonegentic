#!/bin/bash
# Build and launch as standalone app (not under Cursor's process tree)
# so macOS TCC attributes contacts/permissions to the app directly.
cd "$(dirname "$0")"
fvm flutter build macos --debug 2>&1 && \
  open "build/macos/Build/Products/Debug/Phonegentic AI.app"
