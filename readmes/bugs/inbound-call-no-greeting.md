# Inbound call answered but agent never spoke

## Problem

### Phase 1 — Missed SIP state callbacks

On an inbound call, the SIP layer auto-answered correctly (200 OK sent, ACK received), but the agent never said hello and sat silent for ~22 seconds until the caller hung up.

**Root cause:** The `CallScreenWidget`'s `callStateChanged` callback never fired for this call. The SIP state transitions (CONNECTING → STREAM → ACCEPTED → CONFIRMED) happened at the protocol level but were never delivered to the CallScreen widget. Without those events:

1. `_pushCallPhase(CallPhase.settling)` never ran
2. The settling timer never started → never promoted to `connected`
3. The connected greeting never triggered
4. `_enterCallMode()` never ran, so audio routing stayed in `direct` mode instead of call mode

Additionally, because the Dialpad never received `CONFIRMED`, `_inboundRingCaller` was never cleared and `forkCoalescing` stayed `true`. When the BYE arrived, the Dialpad's ENDED handler treated it as a fork death rather than a real call end.

**Contributing factor:** The auto-answer path (`CallScreenWidget.acceptCall`) is a static method that answers the SIP call but doesn't directly notify the AgentService or CallScreen state machine. It relies entirely on the SIP library firing `callStateChanged` callbacks to all registered listeners. When those callbacks are lost (which can happen due to listener registration timing, hot restart state issues, or SIP library edge cases), there's no fallback mechanism.

The existing `_syncCallState()` post-frame callback in `initState` runs too early — the call is still in `CALL_INITIATION` state when it fires (the auto-answer happens 800ms later).

### Phase 2 — Long delay before greeting on successful calls

Even when the SIP callbacks fired correctly, the inbound greeting had ~14 seconds of dead air: 3.7s settle window + 8.9s LLM response time.

**Root cause:** Two compounding issues:
- The inbound settle window was 4 seconds (`_settleWindowMs`), designed for IVR/voicemail detection — irrelevant for inbound calls where a real human dialed you.
- The pre-greeting mechanism (which fires the LLM prompt during settle to absorb latency) was only enabled for outbound calls. Inbound calls didn't send the LLM prompt until *after* the settle window expired, stacking LLM latency on top of settle delay.

## Solution

### Phase 1 — Safety nets for lost SIP callbacks

- **CallScreen delayed re-sync:** A `_callConfirmTimer` fires 2 seconds after widget creation. If `_callConfirmed` is still false, it re-runs `_syncCallState()` to force-sync the state machine from the actual SIP call state.
- **Dialpad auto-answer safety check:** `_scheduleAutoAnswerSafetyCheck` fires 3 seconds after auto-answer. If `_inboundRingCaller` is still set but the call is in ACCEPTED/CONFIRMED state, it clears the stuck fork-coalescing state.

### Phase 2 — Faster inbound greeting

- **Inbound settle window: 4s → 1s.** Renamed `_settleWindowMs` to `_settleWindowInboundMs` and reduced from 4000 to 1000. No IVR risk on inbound.
- **Pre-greeting enabled for inbound.** Removed the `_isOutbound` guard on `_firePreGreeting()` so the LLM prompt fires immediately when settling starts for both directions. The prompt is now direction-aware (uses the inbound-specific wording with caller name resolution).

## Files

- `phonegentic/lib/src/callscreen.dart` — added `_callConfirmTimer` with delayed `_syncCallState` re-check
- `phonegentic/lib/src/dialpad.dart` — added `_scheduleAutoAnswerSafetyCheck` to clear stuck fork coalescing state
- `phonegentic/lib/src/agent_service.dart` — shortened inbound settle window, enabled pre-greeting for inbound calls with direction-aware prompt
