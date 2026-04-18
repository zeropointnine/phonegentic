# Autocomplete dropdown: scroll into view + Enter selection

## Problem

1. When using Tab / Arrow keys to navigate the dialpad autocomplete dropdown, items near the bottom of the list get cut off because the `ListView` doesn't scroll to keep the highlighted item visible.
2. Pressing Enter on a highlighted item doesn't reliably select it because the Enter handler only lived inside the `Focus` widget's `onKeyEvent`, which doesn't fire when the focus node loses focus.

## Solution

1. Added a `ScrollController` to the `ListView.builder` in `DialpadAutocompleteDropdown`. On each `highlightedIndex` change, the widget estimates the item's position (using a constant `_estimatedItemHeight`) and calls `animateTo` if the item is above or below the current viewport.
2. Added Enter key handling in `_handleGlobalKeyEvent` (the `HardwareKeyboard` handler that always runs regardless of focus state). When the dropdown is open and an item is highlighted, Enter now triggers `_onAutocompleteSelect`.

## Files

- `phonegentic/lib/src/widgets/dialpad_autocomplete_overlay.dart` — added `ScrollController`, `_scrollToHighlighted()`, and wired it into `didUpdateWidget`
- `phonegentic/lib/src/dialpad.dart` — added Enter key handling in `_handleGlobalKeyEvent`
