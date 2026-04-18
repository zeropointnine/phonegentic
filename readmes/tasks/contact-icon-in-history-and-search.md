# Contact Icon in History Panel & Search Dropdown

## Problem

The call history panel and dialpad search dropdown show phone and message action icons, but there's no way to quickly navigate to the contact's detail card from these surfaces. Users have to manually open the contacts panel and search for the person.

## Solution

Add a contact icon (person outline) to both:
1. **Call history panel** — collapsed row and expanded header, using `ContactService.openContactForPhone()`
2. **Dialpad autocomplete dropdown** — each result row, via an `onContact` callback

The icon sits alongside the existing phone and message icons, maintaining the same visual style (circular icon buttons in history, `_ActionIcon` in dropdown).

## Files

- `phonegentic/lib/src/widgets/call_history_panel.dart` — added contact icon + `_openContact` method
- `phonegentic/lib/src/widgets/dialpad_autocomplete_overlay.dart` — added `onContact` callback + contact `_ActionIcon`
- `phonegentic/lib/src/dialpad.dart` — wired `_onAutocompleteContact` handler
