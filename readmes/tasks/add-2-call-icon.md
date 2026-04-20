# Replace Add-to-Call icon on dialpad call screen

## Problem

The "Add Call" button on the in-call screen used `Icons.person_add`, which looks too similar to the "Contact" button's `Icons.person_add_outlined`. Both show a person silhouette with a plus sign, making them hard to distinguish at a glance during a call.

## Solution

Created a custom `Add2CallIcon` widget using an SVG phone-plus asset that draws a vintage-style phone handset with a "+" sign. The icon clearly communicates "add another call" with phone imagery rather than person imagery, visually distinguishing it from the contact button.

Also extended `ActionButton` with an optional `iconWidget` parameter so custom-painted icons can be used alongside standard `IconData` icons.

## Phase 2 — Add2Call Modal Refinements

Multiple UI inconsistencies in the Add2Call modal were addressed:

### Changes

1. **Header icon** — replaced `Icons.add_ic_call_rounded` with the new `Add2CallIcon` widget to match the callscreen button
2. **Connected screen actions** — the connected call view now mirrors the main dialpad connected UI: Hold, Transfer, Message, Contact, Hangup, and Keypad buttons (excluding Clone and Add2Call which don't apply to a sub-leg)
3. **Removed spinner** — removed the `CircularProgressIndicator` from the call connecting screen; the "Calling..." text is sufficient feedback
4. **Conference party header** — when a conference is active, the modal header shows identicon avatars for all parties on the call with name tooltips
5. **Identicon selection** — tapping a party's identicon sets it as focused and highlights it with an accent border + glow; this also calls `conf.focusLeg()` to update the agent panel's focused leg indicator on the right
6. **Search/autocomplete overlay** — replaced the old `CallHistoryDb.searchContacts` approach with the same `ContactService.autocompleteSearch` + `DialpadAutocompleteDropdown` widget used on the main dialpad, including keyboard navigation (arrow up/down, tab, enter), search toggle icon, selected contact preview with identicon, and the same visual styling
7. **Keyboard support** — full keyboard handling in the modal: digit/letter input, backspace, escape (dismiss dropdown → clear → close), slash for search toggle, enter to place call

### Agent conferencing verification

The agent already has three conference tools registered:
- `add_conference_participant` — dials a number as a new conference leg
- `merge_conference` — bridges all legs into a conference
- `request_manager_conference` — sends an SMS to the manager requesting approval before conferencing

The system prompt instructs the agent to follow the approval flow (request → wait for YES → hold → dial → merge) and restricts conferencing to the manager only.

## Files

- `phonegentic/lib/src/widgets/add_2_call_icon.dart` — **created** (phase 1) — `Add2CallIcon` SVG widget
- `phonegentic/lib/src/widgets/action_button.dart` — **modified** (phase 1) — added `iconWidget` parameter
- `phonegentic/lib/src/callscreen.dart` — **modified** (phase 1) — swapped `Icons.person_add` for `Add2CallIcon`
- `phonegentic/lib/src/widgets/add_call_modal.dart` — **modified** (phase 2) — full refactor: Add2CallIcon header, connected actions, removed spinner, conference party identicons, search autocomplete overlay, keyboard support
