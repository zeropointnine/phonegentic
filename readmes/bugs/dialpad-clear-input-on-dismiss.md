# Dialpad input not cleared on search dismiss / call end

## Problem

Two related issues with the dialpad text input not being reset:

1. **Search dismiss without selection**: When a user opens the autocomplete search dropdown (via typing letters, pressing `/`, or tapping the search icon) and then cancels/closes it without selecting a contact, the typed input remains in the field. It should clear since no selection was made.

2. **Call end**: When a call completes, `_selectedContact` is not cleared alongside `_textController.text`, leaving stale contact state.

## Solution

- `_dismissAutocomplete()`: When closing the dropdown and `_selectedContact` is null, also clear `_textController.text`, `_autocompleteMatches`, and `_selectedContact`.
- `_handleSlashSearch()`: Same treatment when toggling the dropdown closed.
- `_toggleSearchDropdown()`: Same treatment when toggling closed.
- Escape key handler: When closing the dropdown, also clear input if no selection.
- Call-end cleanup (`callStateChanged` ENDED/FAILED): Also clear `_selectedContact`.

## Files

- `phonegentic/lib/src/dialpad.dart` — all changes in the dialpad state widget
