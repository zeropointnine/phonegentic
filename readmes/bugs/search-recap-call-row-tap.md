# `/search` recap: call-row click doesn't open the call

## Problem

From the `/search` recap card, tapping a call row was supposed to
open the call-history panel and expand that specific call tile.
Instead nothing visibly happened — the panel would sometimes open
empty, or it would open but the expected tile was missing and the
expansion silently no-op'd.

Root cause was the `focusCall` fallback path. When the tapped
`callId` wasn't already in `CallHistoryService._searchResults`
(the common case — the panel hadn't been opened yet, so the cache
was empty or full of unrelated records), `focusCall` fell back to:

```dart
if (phoneNumber != null && phoneNumber.isNotEmpty) {
  _searchQuery = phoneNumber;
  await naturalSearch(phoneNumber);
}
```

`remote_identity` on the call row frequently isn't a clean E.164
phone number — it's whatever SIP put on the wire, e.g.
`sip:+15551234@host.tld` or `+15551234@host` or even an internal
extension. `naturalSearch` runs that string through
`CallSearchParams.fromQuery` which doesn't normalise SIP URIs, so
the DB query returns zero rows. `_searchResults` stays empty, the
panel renders an empty list, and `_expandedCallId = callId` has no
tile to latch onto.

## Solution

The recap row already has the full call record in hand — it rendered
from exactly that row. So instead of making `focusCall` reconstruct
the row from a fragile phone-number search, let the caller pass it in
directly.

### `CallHistoryService.focusCall` — new `preloadedRecord` param

```dart
Future<void> focusCall(
  int callId, {
  String? phoneNumber,
  int? transcriptId,
  Map<String, dynamic>? preloadedRecord,
})
```

When `preloadedRecord` is supplied and its `id` matches `callId`:

1. It's inserted at the top of `_searchResults` (if not already
   present — otherwise the existing copy wins so we don't clobber
   fresher data).
2. `_isOpen = true` + `_expandedCallId = callId` + `notifyListeners`
   all fire immediately, so the panel opens with the tile expanded
   on the first frame — no network / DB round-trip required.
3. The rest of the function still runs (the "not in results" branch
   is now taken only if the caller didn't provide a record AND the
   call wasn't already cached). The existing `naturalSearch` fallback
   stays in place for callers without a preloaded record (e.g. the
   note-footer deep-link path, which only has `call_record_id`).

### `_SearchResultCallRow.onTap` — pass the row through

```dart
Provider.of<CallHistoryService>(context, listen: false).focusCall(
  id,
  phoneNumber: row['remote_identity'] as String?,
  preloadedRecord: row,
);
```

The same map used to render the recap row is now handed straight to
the call-history panel. Also added:

- A `num → int` coercion for `row['id']` in case the map ever comes
  back through a JSON roundtrip where integers might widen.
- `debugPrint` traces on tap + failure so any future regression is
  visible in the console (`[SearchRecap] call-row tap id=…`).

## Files

- `phonegentic/lib/src/call_history_service.dart` — added
  `preloadedRecord` to `focusCall`; inserts into `_searchResults`
  when provided.
- `phonegentic/lib/src/widgets/agent_panel.dart` — `_SearchResultCallRow`
  passes `preloadedRecord: row`; int coercion + debug trace on tap.
