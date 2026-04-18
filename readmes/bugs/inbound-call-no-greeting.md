# Inbound call answered but agent never spoke

## Problem

On an inbound call, the SIP layer auto-answered correctly (200 OK sent, ACK received), but the agent never said hello and sat silent for ~22 seconds until the caller hung up.

**Root cause:** The `CallScreenWidget`'s `callStateChanged` callback never fired for this call. The SIP state transitions (CONNECTING → STREAM → ACCEPTED → CONFIRMED) happened at the protocol level but were never delivered to the CallScreen widget. Without those events:

1. `_pushCallPhase(CallPhase.settling)` never ran
2. The settling timer never started → never promoted to `connected`
3. The connected greeting never triggered
4. `_enterCallMode()` never ran, so audio routing stayed in `direct` mode instead of call mode

Additionally, because the Dialpad never received `CONFIRMED`, `_inboundRingCaller` was never cleared and `forkCoalescing` stayed `true`. When the BYE arrived, the Dialpad's ENDED handler treated it as a fork death rather than a real call end.

**Contributing factor:** The auto-answer path (`CallScreenWidget.acceptCall`) is a static method that answers the SIP call but doesn't directly notify the AgentService or CallScreen state machine. It relies entirely on the SIP library firing `callStateChanged` callbacks to all registered listeners. When those callbacks are lost (which can happen due to listener registration timing, hot restart state issues, or SIP library edge cases), there's no fallback mechanism.

The existing `_syncCallState()` post-frame callback in `initState` runs too early — the call is still in `CALL_INITIATION` state when it fires (the auto-answer happens 800ms later).

## Solution

Added a delayed re-sync safety net in CallScreen: a timer fires 2 seconds after widget creation and checks whether the call was confirmed. If the call is in ACCEPTED or CONFIRMED state but `_callConfirmed` is still false, it force-syncs the state machine. This catches cases where `callStateChanged` callbacks were silently lost.

Also added a complementary safety check in the Dialpad's auto-answer path: after `acceptCall` fires, a 3-second delayed check verifies the `forkCoalescing` flag has been cleared (which only happens when CONFIRMED is received). If still set, it manually clears the flag and stops ringing to prevent the stuck state from cascading.

## Files

- `phonegentic/lib/src/callscreen.dart` — added `_callConfirmTimer` with delayed `_syncCallState` re-check
- `phonegentic/lib/src/dialpad.dart` — added post-auto-answer safety check to clear stuck fork coalescing state
