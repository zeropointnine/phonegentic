# Quick Theme Select in Dropdown Menus

## Problem

Changing the theme required navigating to Settings > User tab > Appearance section. This was too many steps for a common personalization action.

## Solution

Added a "Theme" quick-select section to the bottom of both the dialpad and callscreen overflow popup menus. The section sits below the existing Settings item, separated by a divider and a small "Theme" header. Each of the three themes (Amber VT-100, Miami Vice, Pedestrian Neutral) appears as a menu item with matching icons from the full settings appearance card, and a checkmark on the currently active theme.

The existing theme selection in User Settings remains unchanged — this is a shortcut, not a replacement.

## Files

- `phonegentic/lib/src/dialpad.dart` — Added theme cases to `onSelected`, theme items to `itemBuilder`, and `_buildThemeMenuItems` helper
- `phonegentic/lib/src/callscreen.dart` — Same additions mirrored for the in-call menu
