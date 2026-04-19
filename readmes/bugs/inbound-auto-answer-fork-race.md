# Inbound calls not auto-answered (fork race + ICF gate)

## Problem

Inbound calls are received (SIP INVITE → 180 Ringing) and the ICF correctly matches a job function, but the app never sends `200 OK` to accept the call. Telnyx times out each fork after ~6 seconds with `487 Request Terminated / ALLOTTED_TIMEOUT`.

Two independent bugs conspire to prevent auto-answer:

### Bug 1 — Auto-answer gated on toggle, not ICF match

The auto-answer condition in `_handleInboundRing` is:

```dart
if (ringtone.agentAutoAnswer && _calls.length <= 1)
```

When `agentAutoAnswer` is `false` (default), calls that match an ICF flow are never auto-answered even though the whole point of an ICF match is to route the call to an agent behavior. The toggle was designed for blanket auto-answer of *all* calls, not ICF-matched ones.

### Bug 2 — Auto-answer timer captures dead fork reference

Even when auto-answer is enabled, the 800 ms `Future.delayed` closure captures the `call` parameter from `_handleInboundRing`. Telnyx's SIP forking means the first fork is typically CANCEL'd within ~80 ms when the second fork arrives. By the time the 800 ms timer fires, the captured `call` is in `FAILED` state, so the state check bails:

```dart
if (call.state == CallStateEnum.CALL_INITIATION ||
    call.state == CallStateEnum.PROGRESS)
```

Fork replacements (line 1898) only log "Fork coalesced" — they never re-trigger auto-answer with the new call object. Every subsequent fork gets the same treatment: arrives, nobody answers, Telnyx times it out.

## Solution

1. **ICF-match triggers auto-answer regardless of toggle** — changed the condition to `(matchedId != null || ringtone.agentAutoAnswer) && _calls.length <= 1`. The toggle still controls blanket auto-answer for unmatched calls.

2. **Cancellable auto-answer timer that tracks fork replacements** — replaced the fire-and-forget `Future.delayed` with a `Timer? _autoAnswerTimer` field. A new `_attemptAutoAnswer()` method cancels any pending timer and starts a fresh one. It reads `_focusedCall` at fire time instead of a closure-captured reference, so it always targets the most current fork. The fork replacement branch at line 1898 now calls `_attemptAutoAnswer()` when `_pendingAutoAnswer` is set.

3. **Cleanup** — `_pendingAutoAnswer` and `_autoAnswerTimer` are cleared on CONFIRMED, call end, and ring session end.

## Files

### Modified
- `phonegentic/lib/src/dialpad.dart` — new `_autoAnswerTimer` / `_pendingAutoAnswer` fields, extracted `_attemptAutoAnswer()`, updated `_handleInboundRing` condition, added fork replacement auto-answer trigger, cleanup on CONFIRMED and session end
