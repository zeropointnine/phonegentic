# Inbound Call Management While On Another Call

## Problem

When an inbound call arrives while the user is already on a call we currently have no prominent UI to surface it — the second call only shows up as a row in the right agent panel, and the user has no quick way to choose between *answer and hold current*, *hangup current and answer*, or *auto-reply by SMS*. There is also no automation governed by the job function or manager presence, and if a caller hangs up while on hold we lose them silently.

Specific gaps:

1. No prominent UI for a second inbound call (just a panel row).
2. No job-function knobs to let the agent automate behavior on concurrent inbound.
3. No auto-SMS response when the manager is away.
4. No auto-callback for callers who hang up while on hold.
5. Several code paths act on `sipHelper.activeCall` instead of a specific `call.id`, which is unsafe with multiple calls (risk of hanging up the wrong call).

## Solution

### Job function multi-select (new section "When a call arrives while on another call")

Four new fields on `JobFunction`:

- `autoAnswerAndHold` (bool) — primary toast button defaults to Hold+Answer.
- `respondBySmsWhenAway` (bool) — when manager is away at ring time, auto-send SMS reply and decline the new leg.
- `speakPoliteHoldNotice` (bool) — when the user picks Hold+Answer, agent speaks a brief TTS line ("one moment please...") to the current caller before hold.
- `awaySmsTemplate` (nullable string) — message template for the auto-SMS reply.

### Toast

Top-of-screen animated card, shown only when a second inbound arrives while `_calls` already has a live leg. Three buttons:

- Phone — Answer using job-function default (Hold+Answer if `autoAnswerAndHold` is on, else Hangup+Answer).
- Pause — Hold Current & Answer. If `speakPoliteHoldNotice` is on, agent TTS plays on primary first (3s cap) before hold.
- Call-end — Hangup Current (by id) & Answer.
- X — Decline the new leg.

### Auto-callback

When a HELD leg ends by remote, record the caller. When the primary call ends:

- If manager is away: auto-dial the most recent held-hangup caller via existing outbound path.
- If manager is present: show a callback-prompt toast (Call back / SMS / Dismiss); queue multiple.

### Safety rules

- All new SIP actions resolve `Call` from the dialpad's `_calls` by id and operate on that object; no `sipHelper.activeCall` in new code.
- `InboundCallRouter` guards each action with an `_inFlight` flag so double-taps can't mis-target.
- Fork-replacement inbound reuses dialpad's existing `_inboundRingCaller` detection and does not spawn a toast.

## Architecture

```
CALL_INITIATION (incoming)
      │
      ├── _calls empty → existing inline Accept/Decline
      └── _calls non-empty
             │
             ├── manager away + respondBySmsWhenAway → SMS + decline
             └── else → InboundCallRouter.pendingInbound → toast
                           ├── Answer   → answerDefault()
                           ├── Pause    → holdCurrentAndAnswer()   → polite TTS (opt) → hold → answer
                           ├── CallEnd  → hangupCurrentAndAnswer() → hangup by id   → answer
                           └── X        → decline()
```

## Files

- `phonegentic/lib/src/models/job_function.dart` — add 4 fields + serialization.
- `phonegentic/lib/src/db/call_history_db.dart` — schema v23, 4 ALTER TABLEs.
- `phonegentic/lib/src/widgets/job_function_editor.dart` — new "When a call arrives while on another call" section.
- `phonegentic/lib/src/inbound_call_router.dart` — **new**, the controller.
- `phonegentic/lib/src/widgets/inbound_call_toast.dart` — **new**, ringing + callback-prompt widgets.
- `phonegentic/lib/src/dialpad.dart` — wire router; host toasts in existing Stack.
- `phonegentic/lib/src/widgets/agent_panel.dart` — highlight pending inbound leg with mini actions.
- `phonegentic/lib/src/agent_service.dart` — add `speakToCurrentCaller(text)` helper; narrow call-id safety pass on hold/end/dtmf tools.
- `phonegentic/lib/main.dart` — provide `InboundCallRouter` via `ChangeNotifierProvider`.

## Phases

| Phase | Work |
|-------|------|
| 1 | Model + DB migration |
| 2 | Editor UI |
| 3 | Router + AgentService helper |
| 4 | Toast widget + Dialpad wiring |
| 5 | Agent panel polish |
| 6 | Safety refactor on agent tools |
| 7 | Auto-SMS when away |
| 8 | Auto-callback (prompt + auto-dial) |
| 9 | Field-test follow-ups (UX + audio-path fixes) |
| 10 | Fork-race toast persistence + conference-avatar filter |

## Phase 9 — Field-test follow-ups

After live testing, five follow-up issues were raised:

### 9.1 Toast position

The toast originally hugged `top: 0` of its `SafeArea`, which on macOS/iOS sat directly below the window chrome / status bar and felt cramped. The toast now drops `~8%` of screen height from the top via `MediaQuery.of(context).size.height * 0.08`.

### 9.2 Default answer action = Hold + Answer

The green "Answer" button on the toast previously fell back to Hangup+Answer when the job function did not explicitly set `autoAnswerAndHold`. This is unsafe (a mis-tap dropped the primary caller) and contradicts the design intent. `InboundCallRouter.answerDefault()` now unconditionally calls `holdCurrentAndAnswer()`. Hanging up the current call still has its own dedicated red call-end button on the toast and in the agent panel, so the operator explicitly opts in.

### 9.3 No silent "conference" during ring

The dialpad was flipping the native audio tap into conference mode (`setConferenceMode(active:true)`) inside `CALL_INITIATION` whenever `_calls` was non-empty. That audibly cross-routed the primary call's audio into the new-ringing slot *before* the operator had chosen how to handle the new leg — effectively starting a conference call without notifying anyone.

Fix:

- In `CALL_INITIATION`, `isConferenceLeg` now explicitly excludes `(isIncoming && hasExistingLive)` — a ringing second inbound no longer activates conference mode.
- In `CONFIRMED`, after a leg is accepted, the dialpad re-checks `_calls.length > 1` and then turns conference mode on. This keeps the old multi-leg audio path working once the second call is *actually* answered via Hold+Answer or Hangup+Answer.

### 9.4 Auto-unmute on router-answer

The native mic tap mute (`MethodChannel setMicMute`) is process-wide. If the operator had soft-muted during the first call (or `muteForAway` ran while the manager was away), the second accepted call would answer with a silent mic and no visible indicator on the fresh `CallScreen`. A new `onAnswered` callback on `InboundCallRouter.attach(...)` fires after `_accept(pending)` succeeds in both `holdCurrentAndAnswer` and `hangupCurrentAndAnswer`. The dialpad's `_onRouterAnswered` implementation:

1. Invokes `_tapChannel.invokeMethod('setMicMute', {'muted': false})` so the native tap is unmuted for the new call.
2. Calls `AgentService.restoreFromAway()` so a for-away agent mute doesn't carry into the new leg.

### 9.5 Silent ringtone when already on a call

Playing the ringtone audibly while the primary call is in progress bled a "ring-ring" into the first caller's audio path and was disorienting for the operator. In `CALL_INITIATION` the `hasExistingLive` branch no longer calls `RingtoneService.startRinging()` — the visual toast plus the agent panel highlight are the sole notification surfaces for a second inbound while on a call. Standalone first-call inbound still rings normally via `_handleInboundRing`.

## Phase 10 — Fork-race toast persistence + conference-avatar filter

Two new issues surfaced in the next round of field testing:

### 10.1 Inbound badge disappeared almost immediately

Telnyx routinely SIP-forks an inbound INVITE to multiple gateway endpoints (we saw 4 forks for a single call in the logs). Each fork has a *different* `Call-ID` but the same `From:` number. The forks that lose the race die with `487 Request Terminated` / `ALLOTTED_TIMEOUT` after a few seconds; the dialpad's existing coalescing logic (`_inboundRingCaller` + fork-grace timer) was written to handle this for the *primary* ring UX.

The new `InboundCallRouter` was bypassing that coalescing: on *every* fork death, the dialpad called `router.onCallEnded(call, ...)`, which cleared `_pendingInbound` and hid the toast. Subsequent fork replacements were correctly coalesced by the dialpad, but the `onInboundInitiation` hand-off was only invoked for the *first* INVITE, so the toast never returned.

Fix:

- Dialpad — in `FAILED`/`ENDED`, compute `isForkDeath = _inboundRingCaller != null && _normalizeCaller(call.remote_identity) == _inboundRingCaller`. Skip `router.onCallEnded(...)` when true; the router is holding the toast for this caller on purpose.
- Dialpad — in `CALL_INITIATION` `isForkReplacement` branch, call `router.replacePendingFork(call)` so the router's `_pendingInbound` is always pointing at a *live* `Call` (otherwise a subsequent Hold+Answer tap would accept a dead leg).
- Dialpad — in `_endInboundRingSession` (called when the grace timer expires with no surviving fork), call `router.onRingSessionEnded()`. This is the authoritative teardown point for the toast.
- Router — add `replacePendingFork(Call call)` (swaps the reference, emits `notifyListeners`) and `onRingSessionEnded()` (clears `_pendingInbound` only if the lookup map says the referenced call is no longer live).

### 10.2 Main call screen showed the ringing 2nd call as a participant

`CallScreen._buildConferenceAvatars` renders one circle per `ConferenceService.legs` entry. When the second inbound arrived and the dialpad called `conf.addLeg(call, isOutbound: false)`, the leg was added with `LegState.ringing` — correct for the agent panel's *"ongoing calls"* list, wrong for the main center-of-screen avatar row (which implies "people you are currently talking to").

Fix — in `callscreen.dart`:

- `isConference` now counts only legs whose `state != LegState.ringing` (`activeLegCount`).
- `_buildConferenceAvatars` filters out `LegState.ringing` legs too.

The agent panel continues to read the full `conf.legs` list, so the ringing second call still shows up there with the `isPendingInbound` highlight and the Hold+Answer / Hangup+Answer mini buttons.
