# macOS Native Actions: Reminders, FaceTime, Notes

## Problem

The app needs to integrate with native macOS applications — Reminders, FaceTime, and Notes — so that AI agents or users can programmatically create reminders, initiate phone calls, and save notes during or after calls. Each of these has different sandbox/distribution constraints:

- **Reminders**: No native integration exists; users must manually create follow-up reminders outside the app.
- **FaceTime**: No way to hand off a call or initiate a FaceTime call from within the app.
- **Notes**: No way to save call summaries, transcripts, or other content directly into Apple Notes.

The solution must work for both direct distribution and Mac App Store distribution where possible, gracefully degrading features that cannot operate within the App Store sandbox.

## Solution

A single Swift method channel (`NativeActionsChannel`) exposes three capabilities to Dart:

1. **Reminders** — Uses the native EventKit framework (`EKEventStore` / `EKReminder`). Fully sandbox-compatible and App Store approved. Requires the `com.apple.security.personal-information.calendars` entitlement.

2. **FaceTime** — Uses the `facetime://` and `facetime-audio://` URL schemes via `NSWorkspace.shared.open()`. Sandbox-compatible, no special entitlements needed. macOS always prompts the user before dialing.

3. **Notes** — Uses `NSAppleScript` to tell the Notes app to create a note. Requires `com.apple.security.automation.apple-events` and `com.apple.security.temporary-exception.apple-events` targeting `com.apple.Notes`. Works for direct distribution only; gracefully disabled for App Store builds via a runtime availability check.

A `getAvailableActions` method lets the Dart side query which actions are available at runtime, so the UI can conditionally show/hide features.

## Files

### Created
- `phonegentic/macos/Runner/NativeActionsChannel.swift` — Swift method channel with EventKit, NSWorkspace, and NSAppleScript logic
- `phonegentic/lib/src/native_actions_service.dart` — Dart service wrapping the method channel

### Modified
- `phonegentic/macos/Runner/MainFlutterWindow.swift` — Register the new channel
- `phonegentic/macos/Runner/DebugProfile.entitlements` — Add calendars + apple-events entitlements
- `phonegentic/macos/Runner/Release.entitlements` — Same entitlement additions
- `phonegentic/macos/Runner/Info.plist` — Add `NSRemindersUsageDescription` and `NSAppleEventsUsageDescription`
