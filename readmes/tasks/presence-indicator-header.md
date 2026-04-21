# Presence Indicator & Ready Pill Phone Icon

## Problem

The Ready status pill in the header used a plain dot indicator, and there was no way to see or control the user's availability (Active vs Away) directly from the main UI. The 5-minute auto-away existed in `ManagerPresenceService` but was invisible to the user and couldn't be manually toggled.

## Solution

### Ready pill — phone icon
Replaced the 6px colored dot inside the SIP status pill with a small `Icons.phone_rounded` icon (12px), keeping the same color coding (green = ready, red = unregistered, amber = other).

### Presence indicator — Active/Away dropdown
Added a new `_buildPresenceIndicator` widget 20px to the left of the Ready pill. It shows:
- **Active** (green dot + label) when available
- **Away** (amber dot + label) when away (auto or manual)
- A small dropdown chevron; tapping opens a `PopupMenuButton` with Available and Away options, each with a checkmark on the current state.

### ManagerPresenceService — manual toggle
Added `_manuallyAway` flag and two public methods:
- `setManuallyAway()` — marks the user as away regardless of window focus, cancels the auto timer
- `clearManuallyAway()` — clears both manual and auto away, triggers the return-from-away briefing flow

The existing `isAway` getter now returns `true` if either auto-away OR manually away. `_onFocusGained` only auto-clears the away state if it wasn't manually set — the user's explicit choice is respected.

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — `_manuallyAway`, `setManuallyAway()`, `clearManuallyAway()`, updated `isAway` getter and `_onFocusGained`
- `phonegentic/lib/src/dialpad.dart` — Swapped dot for phone icon in Ready pill, added `_buildPresenceIndicator` with dropdown, imported `ManagerPresenceService`
