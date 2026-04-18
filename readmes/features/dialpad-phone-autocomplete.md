# Dialpad Phone Autocomplete

## Problem

When dialing a number on the main dialpad, the user has no way to quickly find and select a known contact by typing partial digits or a name. The existing `DialpadContactPreview` only shows a single exact match after the full normalized phone is typed — there's no prefix-based search, no text-based name search, no multi-result dropdown, and no way to tap a result to fill the dialpad. This forces users to either memorize full numbers or switch to the contacts panel to initiate a call.

## Solution

Added a unified autocomplete overlay to the dialpad that supports both digit-prefix and alphabetic name/company search.

**ContactService.autocompleteSearch** — a fast synchronous method that inspects the input: if purely digits, it searches the in-memory `_phoneCache` for substring matches; if the input contains letters, it does a case-insensitive substring match across `display_name`, `company`, and `email` on the full contact list. Results capped at 8.

**DialpadAutocompleteOverlay** — a new widget that wraps the number display. When matches are present, a frosted rounded-rect container fades in (220ms, easeOutCubic) around the display with a scrollable list of matching contacts below a divider. Each row is a two-line layout: name on top, phone number + company on the second line. Each row has dedicated call (green phone) and message (accent chat bubble) icon buttons. Rows stagger in with a 30ms cascade fade+slide animation. The results area uses `AnimatedSize` for smooth height transitions and `ClampingScrollPhysics` to avoid bounce.

**Keyboard handler** — the dialpad now accepts alphabetic characters and spaces directly into the text controller (previously letters were routed to the agent panel). This enables name-based search without requiring the user to switch context.

**Row actions**:
- Tapping the row itself fills the dialpad with the contact's phone number
- Tapping the call icon directly dials the contact
- Tapping the message icon opens the messaging panel with the conversation pre-selected for that number

**Number display** — adapts its typography depending on input type: phone numbers get the existing large monospace-style formatting with phosphor glow; text queries use a smaller, denser font weight. Placeholder text updated to "Enter number or name".

## Files

| Action | File |
|--------|------|
| Create | `phonegentic/lib/src/widgets/dialpad_autocomplete_overlay.dart` |
| Modify | `phonegentic/lib/src/contact_service.dart` — added `autocompleteSearch()` |
| Modify | `phonegentic/lib/src/dialpad.dart` — replaced `DialpadContactPreview` area with overlay, updated keyboard handler for letters, added `_onAutocompleteCall` / `_onAutocompleteMessage` |
