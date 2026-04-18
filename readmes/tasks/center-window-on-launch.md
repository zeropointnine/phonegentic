# Center App Window on Launch

## Problem

The app window opens at whatever position macOS last remembered (or a default offset), rather than appearing centered on the display.

## Solution

Added `self.center()` in `MainFlutterWindow.awakeFromNib()` immediately after setting the window frame size. This uses the native `NSWindow.center()` API to position the window in the center of the screen.

## Files

- `phonegentic/macos/Runner/MainFlutterWindow.swift` — added `center()` call after `setFrame`
