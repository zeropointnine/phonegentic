# Unified Log Filtering (Flutter + Native Swift)

## Problem

Console output is noisy and comes from two separate streams:
- **Dart** `debugPrint(...)` → Flutter stdout
- **Swift** `NSLog(...)` → macOS Unified Logging System (separate from Flutter terminal)

Because they're in different streams, you can't grep/filter them together.

## Solution

Replace all `NSLog` calls in Swift with a thin wrapper `appLog` that writes to stdout via `print()`. Since the Swift code runs in the same process as Flutter on macOS desktop, both streams will land on stdout and can be filtered with a single pipeline.

## Implementation

### 1. Create `phonegentic/macos/Runner/AppLog.swift`

```swift
import Foundation

func appLog(_ format: String, _ args: CVarArg...) {
    print(String(format: format, arguments: args))
}
```

### 2. Find-replace in all Swift files under `phonegentic/macos/Runner/`

```
NSLog(  →  appLog(
```

Files to update (all contain NSLog calls):
- `AudioTapChannel.swift` (~30 calls)
- `WhisperKitChannel.swift` (~30 calls)
- `WebRTCAudioProcessor.swift` (~20 calls)
- `SpeakerIdentifier.swift` (~18 calls)
- `KokoroTtsChannel.swift` (~14 calls)
- `PocketTtsChannel.swift` (~8 calls)

No format string changes needed — `appLog` has the same signature as `NSLog`.

### 3. Run with filtering

Exclude noisy tags:
```bash
fvm flutter run -d macos 2>&1 | grep --line-buffered -vE '\[AudioTap\]|\[WebRTCAudio\]'
```

Include only specific tags:
```bash
fvm flutter run -d macos 2>&1 | grep --line-buffered -E '\[WhisperKit\]|\[PocketTTS\]'
```

## Notes

- All existing `[Tag]` prefixes (e.g. `[WhisperKit]`, `[AudioTap]`) are already consistent across Dart and Swift — filtering by tag works across both.
- If system log access is ever needed for crash diagnostics, uncomment the `NSLog` line in `appLog`.
- `--line-buffered` is required on the grep call — without it, output is held until the buffer fills.
