# Dialpad dropdown steals focus to agent panel

## Problem

When clicking into the dialpad (e.g. the search icon to open the autocomplete dropdown), the AgentPanel's input TextField retains focus. This means subsequent keystrokes like `/` or letters are captured by the AgentPanel instead of being handled by the dialpad's global key handler (`_handleGlobalKeyEvent`), which checks `inTextField` and skips processing when focus is inside an `EditableText`.

## Solution

Request focus on the dialpad's `_focusNode` whenever the dropdown opens — in `_toggleSearchDropdown`, `_handleSlashSearch`, and `_onDigitsChanged`. This ensures the dialpad's `Focus` widget is the active focus target, so `_handleGlobalKeyEvent` correctly routes keystrokes to the dialpad.

## Files

- `phonegentic/lib/src/dialpad.dart` — added `_focusNode.requestFocus()` calls when dropdown opens
