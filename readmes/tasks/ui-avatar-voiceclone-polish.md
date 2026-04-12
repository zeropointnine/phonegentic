# UI Polish: Identicon Avatars, Contact Detail & Voice Clone on Dialpad

## Summary

Replace single-letter initial avatars with the deterministic `ContactIdenticon` widget across all screens, add phone number display in the contact detail view, improve contact name padding, and surface the voice clone UI directly on the dialpad.

## Changes

### ContactIdenticon Everywhere

Replaced plain initial-letter circles/squares with the `ContactIdenticon` widget (deterministic symmetric pattern derived from the contact name) in:

- **Contact list** (`contact_list_panel.dart` — `_ContactTile`): 34px identicon per row
- **Contact detail** (`contact_card.dart`): 72px identicon at top of detail card
- **Call history** (`call_history_panel.dart` — `_CallHistoryTile`): 34px identicon per row
- **Connected/call screen** (`callscreen.dart`): 88px identicon — now shows for *all* calls, not just contacts with a match. Uses the contact name as the seed when available, otherwise falls back to the remote identity string.
- **Dialpad contact preview** (`dialpad_contact_preview.dart`): already used the identicon — no change needed.

### Contact Detail Improvements

- **Phone number displayed** below the contact name when present, using the demo-mode phone mask.
- **Name container padding**: wrapped the name `HoverButton` in horizontal padding (24px) so the text doesn't hug the edges of the panel. Centered text alignment for the display name.

### Voice Clone on Dialpad

Added a `+` icon button to the left of the call button on the dialpad (when no call is active). Tapping it opens a popup menu with two options:

- **Sample Me** — opens the voice clone modal configured for host/mic recording
- **Sample Them** — opens the voice clone modal configured for remote party recording

This supplements the existing "Sample Me" / "Sample Them" action buttons that appear during an active call on the call screen. The dialpad version allows starting a voice clone flow without an active call, using the mic-based recording path.

### Call Screen Button Layout Redesign

Restructured the call screen action buttons from an unbalanced layout into two even rows of five buttons:

```
Row 1:  Mute  -  Hold  -  Record  -  Transfer  -  Add Call
Row 2:  Add Contact  -  Keypad  -  [Hangup]  -  Clone  -  Message
```

- **Hangup** remains centered as the large colored circle button in row 2
- **Add Contact** (new) — saves the current remote party as a contact via `ContactService.quickAdd`, with duplicate detection
- **Message** (new) — opens the messaging panel via `MessagingService.toggleOpen`
- **Clone** — voice clone mouth icon with dropdown, now in row 2 beside hangup
- **Hold** — moved from row 2 to row 1 for better grouping with other call-control actions

### Timer Relocated to Top Bar

Moved the call status label ("Connected") and timer ("00:19") from the center overlay column up to a compact top bar. The center area now only shows the identicon avatar, contact name, and phone number.

## Files Modified

| File | Change |
|------|--------|
| `widgets/contact_list_panel.dart` | Replaced initial square with `ContactIdenticon` in `_ContactTile` |
| `widgets/contact_card.dart` | Replaced initial square with `ContactIdenticon`, added phone number display, added name padding |
| `widgets/call_history_panel.dart` | Replaced initial square with `ContactIdenticon` in `_CallHistoryTile` |
| `callscreen.dart` | Unified avatar to always use `ContactIdenticon`; restructured action buttons into 5+5 grid; moved timer/status to top bar; added `_handleAddContact` and `_handleSendMessage` methods |
| `dialpad.dart` | Added `_VoiceCloneDropdown` widget with `+` button and popup menu |
