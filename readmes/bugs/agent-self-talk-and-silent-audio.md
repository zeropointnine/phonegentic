# Agent Self-Talk & Silent Audio on Calls

## Problem

Three interrelated bugs prevented the agent from working on calls:

1. **No audio routing (outbound)** — When a call was already in CONFIRMED/ACCEPTED state at widget mount time (e.g., auto-answered inbound, or rapid pickup), `_syncCallState()` in `callscreen.dart` set `_enteredCallMode = true` without actually invoking the `enterCallMode` platform channel. This bypassed native audio routing to WebRTC, so no audio flowed in either direction. Remote parties heard silence and disconnected with RTP/RTCP timeouts.

2. **No audio routing (inbound auto-answer)** — For inbound calls auto-answered via `CallScreenWidget.acceptCall`, the SIP library fires `ACCEPTED` (not `CONFIRMED`) when the local side sends 200 OK. The `callStateChanged` switch only handled `CONFIRMED` for `_enterCallMode()` — `ACCEPTED` fell through to `default` which never called it. Additionally, `ACCEPTED` mapped to `CallPhase.answered` instead of `CallPhase.settling`, so the agent never started its settle timer, never warmed up TTS, and never transitioned to `connected`. The agent was completely non-functional on auto-answered inbound calls.

3. **Agent fabricating dialogue** — Without real remote-party transcripts arriving (because audio wasn't flowing), the LLM filled the silence by hallucinating speaker-labeled lines like `[Remote Party 1]: Hello? Is someone there?` within its own response, then continuing to "converse" with itself. This is the same role-playing pattern previously observed with SMS hallucination but applied to call transcripts.

## Solution

### Fix 1: Audio routing — `_syncCallState()` (`callscreen.dart`)

Replaced direct flag assignment with the actual platform channel method call in `_syncCallState()`:

```dart
// Before (broken):
_enteredCallMode = true;

// After (fixed):
_enterCallMode();
```

`_enterCallMode()` has its own idempotency guard (`if (_enteredCallMode) return`), so calling it multiple times is safe.

### Fix 2: ACCEPTED handling in `callStateChanged` (`callscreen.dart`)

Added `ACCEPTED` alongside `CONFIRMED` in the switch so that `_enterCallMode()`, `_maybeAutoRecord()`, and `_startAddCallGrace()` fire when the local side answers an inbound call:

```dart
case CallStateEnum.ACCEPTED:
case CallStateEnum.CONFIRMED:
  _state = callState.state;
  setState(() => _callConfirmed = true);
  _enterCallMode();
  _maybeAutoRecord();
  _startAddCallGrace();
  break;
```

Also changed `_sipStateToPhase` to map both `ACCEPTED` and `CONFIRMED` to `CallPhase.settling` (was `CallPhase.answered`), so the agent properly starts the settle timer, TTS warm-up, and eventual transition to `connected`.

Added diagnostic logging at the top of `callStateChanged` to log all state changes and any ID mismatches, to aid future debugging.

### Fix 3: Instruction guardrails (`agent_context.dart`)

Added a "Transcript Integrity" section to the system instructions with explicit anti-fabrication rules:

- NEVER generate `[Remote Party 1]:` or `[Host]:` lines — only the SYSTEM delivers these
- NEVER predict/imagine what the other party will say
- After greeting, STOP and wait for real transcripts
- If no transcripts arrive, remain SILENT

### Fix 4: Code-level safety net (`text_agent_service.dart`)

Added a streaming-time detector that catches fabricated transcript lines in the LLM's output:

- A regex (`_fabricatedTranscriptRe`) matches patterns like `\n[Word(s) N]:` in the accumulated response
- When detected mid-stream, the response is truncated to just the clean text before the fabrication
- Prevents the fabrication from reaching TTS or creating a self-talk loop

## Files

| File | Change |
|------|--------|
| `phonegentic/lib/src/callscreen.dart` | `_syncCallState()`: replaced flag with method call; `callStateChanged`: added `ACCEPTED` case; `_sipStateToPhase`: mapped `ACCEPTED` to `settling`; added diagnostic logging |
| `phonegentic/lib/src/models/agent_context.dart` | Added "Transcript Integrity" guardrails section before the SMS section |
| `phonegentic/lib/src/text_agent_service.dart` | Added `_fabricatedTranscriptRe` regex and mid-stream fabrication detection in `_callLlm()` |
