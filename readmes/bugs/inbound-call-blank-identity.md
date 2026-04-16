# Inbound call screen bugs

## Problem 1 — Blank identity on inbound calls

On inbound calls the call screen displays a blank area where the caller's number and contact name should appear. The root cause is an empty-string-vs-null chain:

1. `Call.remote_identity` in `sip_ua_helper.dart` returns `''` (not `null`) when the SIP URI `user` field is missing — common for some inbound carrier formats.
2. The callscreen's `remoteIdentity` getter forwarded this `''` as-is.
3. `PhoneFormatter.format('')` returns `''` (≤4 digits path).
4. `formattedRemote ?? 'Unknown'` never triggers because `''` is not `null` — `Text('')` renders blank.
5. `Call.remote_display_name` (which often carries the caller ID for inbound) was never consulted by the call screen UI.

### Solution

Fixed the `remoteIdentity` getter in `callscreen.dart` to:
- Normalize empty strings to `null` so the `'Unknown'` fallback triggers correctly.
- Fall back to `remote_display_name` when `remote_identity` is empty, since carriers often place the caller number/name there.

## Problem 2 — InvalidStateError: waitingForAck on double-answer

When agent auto-answer is enabled, the dialpad schedules `acceptCall` after 800ms. If the user also taps the Accept button (or the callscreen mounts and somehow re-triggers answer), `_handleAccept` calls `answer()` on a session already in `waitingForAck` state, throwing `InvalidStateError`.

The static `acceptCall` method had a state guard; `_handleAccept` did not.

### Solution

Added the same `CALL_INITIATION` / `PROGRESS` state guard to `_handleAccept`, returning early with a debug log if the call is already answered.

## Problem 3 — Identity overlay disappears after call confirmed

The `voiceOnly` getter used AND logic: `call!.voiceOnly && noRemoteVideoTracks`. Telnyx always includes a video `m=` line in the INVITE, so `call.voiceOnly` is `false` even for voice calls. Once the call is confirmed, `voiceOnly || !_callConfirmed` evaluates to `false` and the entire identity overlay (avatar, name, number) is replaced by a tiny timer chip — effectively a blank screen.

### Solution

Changed `voiceOnly` getter from AND to OR: `call!.voiceOnly || noRemoteVideoTracks`. Now if there's no actual remote video being received, the UI treats it as voice-only and keeps the identity overlay visible. This is correct for all cases:
- Pure voice calls: `voiceOnly=true` (either flag)
- Video offered but rejected/not flowing: `voiceOnly=true` (no tracks)
- Active video: `voiceOnly=false` (both flags false)

## Files

- `phonegentic/lib/src/callscreen.dart` — `remoteIdentity` getter, `_handleAccept` guard, `voiceOnly` getter
