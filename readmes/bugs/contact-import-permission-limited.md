# Contact Import Fails on macOS Due to Permission Issues

## Problem

Importing contacts from macOS Contacts.app fails with the error:
> "Contacts permission denied. Open System Settings > Privacy & Security > Contacts to grant access."

...even though the user has already granted contacts permission in System Settings.

### Phase 1: Limited permission status (macOS 15+)

Starting with macOS 15 (Sequoia), Apple introduced a "limited" contacts access mode (similar to iOS 18's `CNAuthorizationStatusLimited`). When a user grants contact access, the system may return `PermissionStatus.limited` instead of `PermissionStatus.granted`. The `importFromMacOS()` method in `ContactService` only accepted `PermissionStatus.granted`, treating `limited` as denied.

### Phase 2: Ad-hoc signing blocks TCC prompts (macOS 26)

On macOS 26, the TCC (Transparency, Consent, and Control) system no longer shows permission prompts for ad-hoc signed apps. The Flutter template default sets `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` in the Xcode project, which means "sign to run locally" (ad-hoc). Xcode's UI overrides this when running directly from Xcode, but `flutter run` / `xcodebuild` from the command line uses the project settings as-is. This caused:

- `CNContactStore.requestAccess(for:)` to immediately deny with `CNErrorDomain Code=100 "Access Denied"` without showing a prompt
- Direct data access via `CNContactStore.enumerateContacts` to also fail immediately
- The app to never appear in System Settings > Privacy & Security > Contacts

Additionally, the `flutter_contacts` plugin's `requestAccess` call was removed from the import flow since it is unreliable on macOS 26. The import now calls `getAll()` directly and catches the error if permission is denied.

## Solution

### Phase 1
Accept both `PermissionStatus.granted` and `PermissionStatus.limited` as valid permission states.

### Phase 2
- Changed `CODE_SIGN_IDENTITY[sdk=macosx*]` from `"-"` to `"Apple Development"` in all three build configurations (Debug, Profile, Release) so `flutter run` builds get properly signed with the development team certificate
- Removed the explicit `FlutterContacts.permissions.request()` call from `importFromMacOS()` and instead call `getAll()` directly with a try/catch for permission errors
- Added WAL mode and busy_timeout to SQLite to prevent concurrent access lock errors at startup

## Files

- `phonegentic/lib/src/contact_service.dart` — removed explicit permission request, catch getAll errors
- `phonegentic/lib/src/db/call_history_db.dart` — added WAL mode and busy_timeout
- `phonegentic/macos/Runner.xcodeproj/project.pbxproj` — changed code signing from ad-hoc to Apple Development
