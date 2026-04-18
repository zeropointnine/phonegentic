# Autocomplete dropdown: scroll highlighted item into view

## Problem

When using Tab / Arrow keys to navigate the dialpad autocomplete dropdown, items near the bottom of the list get cut off because the `ListView` doesn't scroll to keep the highlighted item visible.

## Solution

Added a `ScrollController` to the `ListView.builder` in `DialpadAutocompleteDropdown`. On each `highlightedIndex` change, the widget estimates the item's position (using a constant `_estimatedItemHeight`) and calls `animateTo` if the item is above or below the current viewport.

## Files

- `phonegentic/lib/src/widgets/dialpad_autocomplete_overlay.dart` — added `ScrollController`, `_scrollToHighlighted()`, and wired it into `didUpdateWidget`
