# Inbound Fork UI Reset

## Problem

Telnyx delivers inbound calls as multiple SIP INVITE forks (different Call-IDs, same logical call). Each fork is CANCEL'd after ~6 seconds with `ALLOTTED_TIMEOUT`, then a new INVITE arrives from a different proxy. The app treats each fork as an independent call, causing:

- The UI call counter to reset to 0:00 on each fork
- The ringtone to stop and restart
- The agent to cycle through idle → initiating on each fork
- Fork #2+ to be misidentified as a conference leg (triggering conference mode and a 30s hangup timer)
- Potential re-registration cascading that kills surviving forks

This is Telnyx-specific behavior — standard SIP does not fork to the same endpoint like this. The fix must be SIP-generic so it doesn't break standard SIP providers.

## Solution

Added fork coalescing logic in `callStateChanged` within `dialpad.dart`. Uses SIP-generic heuristics (caller identity + timing) rather than Telnyx-specific headers.

**Core mechanism:** Track the active inbound ring session by normalized caller identity. When a new inbound INVITE arrives from the same caller while ringing (or within a 4-second grace window after the last fork failed), it's adopted as the same logical call — no UI reset, no conference leg misidentification, ringtone continues uninterrupted.

Key design decisions:
- **SIP-generic:** Only uses `remote_identity` (standard SIP) and timing. No dependency on `X-Telnyx-Session-ID` or any proprietary header.
- **4-second grace window:** After all forks die, a timer keeps the ring session alive so the next fork can coalesce. Conservative enough that real distinct calls from the same number won't be accidentally merged.
- **Conference leg guard:** `isForkReplacement` prevents fork INVITEs from being treated as conference legs, which previously triggered conference mode and a 30s hangup timer.
- **Re-registration guard:** Suppressed during active fork grace window so the SIP stack isn't torn down between forks.
- **Harmless for standard SIP:** If a provider doesn't fork, the grace window never activates.

### Phase 2 — Agent state suppression

The Phase 1 dialpad fix prevented UI resets but `CallScreenWidget` still independently pushed `failed`/`ended` phases to `AgentService` for each dying fork. This caused the agent to fully tear down state (clear remote identity, prior transcript, reset text agent, stop whisper) between forks — and when the next fork connected, the agent was in a broken state, causing the call to drop.

Fix: Added `forkCoalescing` flag to `AgentService`. The dialpad sets it `true` when an inbound ring session starts, and clears it on `CONFIRMED` or when `_endInboundRingSession()` fires. While the flag is set, `notifyCallPhase()` silently drops `failed`/`ended` transitions. When the fork session truly ends (grace timer expires, caller hung up), the dialpad clears the flag and pushes the real `failed` so the agent can clean up.

### Phase 3 — Stable CallScreenWidget key + TextAgent guard

Even with Phase 2 suppressing agent state resets, the `CallScreenWidget` was still being torn down and recreated on each fork because it used `key: ValueKey(call.id)`. Each fork gets a different Call-ID, so Flutter destroyed the old widget and created a fresh one — resetting the call timer to 0:00 and briefly flashing the "Decline" button (which likely caused the accidental BYE/603 hangup the user saw).

Fixes:
- **Stable `_logicalCallKey`**: Set once when the first inbound ring starts, reused across all fork replacements. The `CallScreenWidget` key becomes `ValueKey(_logicalCallKey ?? call.id)`. Flutter reuses the existing State, preserving the timer and UI continuity.
- **`didUpdateWidget` in CallScreenWidget**: When Flutter swaps the underlying Call object (same key, different widget), `didUpdateWidget` detects the change and re-syncs via `_syncCallState()`. The SIP listener filter (`call.id != widget._call?.id`) automatically adapts since `widget._call` is dynamic.
- **TextAgentService `_disposed` guard**: Late-arriving LLM responses after `dispose()` no longer throw "Cannot add events after calling close". A `_disposed` flag gates all `StreamController.add()` calls and breaks the streaming loop early.

### Phase 4 — CallScreen teardown suppression + inbound IVR/beep bypass

Two remaining issues:

1. **Timer still resetting**: Even with the stable key, the old fork's CallScreen still received its own FAILED event (before the widget was updated with the new fork). This triggered `_backToDialPad()` → `onDismiss` → `_focusedCall = null`, momentarily removing the CallScreenWidget from the tree and resetting the timer.

   Fix: In CallScreen's ENDED/FAILED handler, check `_agent.forkCoalescing`. If true, skip the entire teardown (`_stopRecording`, `_backToDialPad`).

2. **Agent hung up an inbound call (beep false positive)**: The native Goertzel beep detector fired during an inbound call, classified it as voicemail/IVR, and the agent called `end_call`. IVR/voicemail/beep detection is meaningless for inbound calls — the caller is always a real person.

   Fix: Gated all IVR/voicemail/beep detection paths with `_isOutbound`:
   - `onBeepDetected` handler: early-return for inbound
   - Settle transcript IVR classification: skip `_ivrHeard = true` and `_enterBeepWatchMode()` for inbound
   - Settle timer IVR beep-watch entry: skip for inbound
   - Cadence-based accumulated IVR analysis: skip for inbound

### Phase 5 — Eliminate setState during fork deaths

The suppression guards prevented agent teardown and call-screen navigation, but the FAILED/ENDED handler was still calling `setState()` to remove the dead fork from `_calls`. That rebuild was enough to remount/flicker the UI even though the `_logicalCallKey` kept the widget in-tree.

Fix: When `_inboundRingCaller != null` (active ring session), the FAILED/ENDED handler now **skips setState entirely**. It silently removes the call from `_calls` and starts the grace timer if `_calls` is empty, but does not trigger any UI rebuild. The next fork's CALL_INITIATION is the only thing that calls `setState`, cleanly swapping the Call object. If no replacement fork arrives, `_endInboundRingSession()` fires after the grace window and does the full cleanup setState (nulling `_focusedCall`, resetting flags).

### Phase 6 — Stuck call screen after BYE + state label fix

Two issues after a real BYE (call ended by remote party):

1. **Call screen stuck forever**: The dialpad's ENDED handler removed the call from `_calls` but left `_focusedCall` pointing at the dead Call. Then `_logicalCallKey = null` changed the widget key, unmounting the old CallScreenWidget before its 2-second `onDismiss` timer could fire. A new CallScreenWidget was created with the dead Call and sat there permanently.

   Fix: In the normal (non-fork-coalescing) ENDED path, null `_focusedCall` and `_logicalCallKey` inside the same `setState` that empties `_calls`. The CallScreenWidget is removed from the tree immediately — no orphaned widget with a dead call.

2. **State label showed "Failed" during fork coalescing**: The `_state = callState.state` assignment ran *before* the `forkCoalescing` suppression guard, so the label switched to "Failed" even though teardown was blocked.

   Fix: Moved `_state` assignment into each individual case branch, after the suppression guard. Fork-suppressed events never update `_state`.

3. **Ring icon green dot removed accidentally**: The green dot indicating an active inbound call flow was removed, making the button hard to find and removing the visual cue that a flow was configured.

   Fix: Restored the green dot indicator and `InboundCallFlowService` watch. Added a `Tooltip` with context-aware message.

## Files

- `phonegentic/lib/src/dialpad.dart` — fork-tracking state fields, coalescing logic, `forkCoalescing` flag management, `_logicalCallKey` for stable widget key, silent fork removal (no setState) during ring sessions, proper `_focusedCall` nulling on call end
- `phonegentic/lib/src/agent_service.dart` — `forkCoalescing` field, guard in `notifyCallPhase()`, inbound call guards on all IVR/beep/voicemail detection
- `phonegentic/lib/src/callscreen.dart` — `didUpdateWidget` for fork replacement, `forkCoalescing` guard on ENDED/FAILED teardown, per-branch `_state` assignment
- `phonegentic/lib/src/text_agent_service.dart` — `_disposed` guard on stream controllers
