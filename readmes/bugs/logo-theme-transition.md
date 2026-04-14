# Logo Not Repainting on Theme Change

## Problem

The `PhonegenticLogo` sparkle icon in the title bar kept its original amber gradient after switching to the Miami Vice or Light themes. All other UI elements transitioned correctly.

## Solution

`PhonegenticLogo` was a plain `StatelessWidget` with a static `_defaultColors` getter that read from `AppColors` at build time. Because the widget never subscribed to `ThemeProvider`, Flutter had no reason to call `build` again after a theme switch — the `CustomPaint` just kept the stale colors.

Fix: add `context.watch<ThemeProvider>()` at the top of `build`. This registers a dependency on the provider so Flutter schedules a rebuild whenever `ThemeProvider.notifyListeners()` fires (i.e. on every `setTheme` call). The colors are then re-read from `AppColors` with the updated `_theme` static field.

The static `_defaultColors` getter was also inlined into `build` so the color list is always computed fresh from the current `AppColors` state.

## Files

- `phonegentic/lib/src/widgets/phonegentic_logo.dart` — added `context.watch<ThemeProvider>()` and inlined default colors into `build`
