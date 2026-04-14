# Inbound calls unanswerable

## Problem

Three bugs prevented answering incoming SIP calls:

1. **404 rejection**: The SIP UA's `receiveRequest` method only accepted
   requests where the R-URI user matched the SIP credential username
   (`userpatricklemiuex66300`) or the Contact URI user (`10769861`). Telnyx
   routes inbound calls using the DID phone number as the R-URI user
   (`sip:19716128356@...`), which matched neither value → 404.

2. **No Accept button**: After fixing the 404, the call screen appeared but had
   no way to answer. The Accept/Decline buttons were only rendered for
   `NONE`/`CONNECTING` states, but incoming calls transition immediately to
   `CALL_INITIATION` then `PROGRESS` (when the local 180 Ringing is sent).
   The `PROGRESS` case only showed a "Cancel" button regardless of direction.

3. **Deregistration on CANCEL**: Telnyx fork-routes incoming INVITEs across
   multiple registrar edges. When the first fork was CANCEL'd (normal
   behavior), the dialpad's `FAILED` handler saw `_calls.isEmpty` and called
   `reRegisterWithCurrentUser()`, which sent a deregistration (`Contact: *`,
   `Expires: 0`). The second fork arriving milliseconds later was rejected
   with `480 Temporarily Unavailable` because the UA had just deregistered.

## Solution

1. Extended R-URI matching in `receiveRequest` to also accept the phone number
   derived from `display_name` (leading `+` stripped).

2. Added `CALL_INITIATION` and `PROGRESS` to the call screen states that show
   Accept/Decline for incoming calls.

3. Skip re-registration when a call fails with cause `'Canceled'` — this is
   normal forked-INVITE behavior, not an error requiring recovery.

## Files

- `lib/src/ua.dart` — added DID-based R-URI matching in `receiveRequest`
- `phonegentic/lib/src/callscreen.dart` — show Accept/Decline buttons during
  `CALL_INITIATION` and `PROGRESS` states for incoming calls
- `phonegentic/lib/src/dialpad.dart` — skip re-registration on remote CANCEL
