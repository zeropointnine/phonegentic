# Agent speaks before call connects

## Problem

When the user tells the agent to make a call (e.g. "Call Lee..."), the sequence is:

1. TextAgent calls `make_call` tool → SIP INVITE fires
2. `make_call` returns `"Call initiated to +15104992119"`
3. TextAgent immediately generates a greeting response ("Hi, this is Alice…")
4. `_appendStreamingResponse` checks `suppressTts` but `_callPhase` is still `idle` — SIP events are async and haven't arrived yet
5. Since `idle` is explicitly excluded from TTS suppression, ElevenLabs TTS starts playing the greeting
6. The phone is still ringing (or hasn't even reached 180 Ringing yet)
7. The remote party hasn't answered, but the agent's voice is playing out through the speaker

The LLM instructions say "just call make_call and say nothing", but the model doesn't always comply. There was no code-level defense against this race.

## Solution

Added a `_callDialPending` flag that bridges the gap between `make_call` returning and the first real `CallPhase` arriving from SIP events:

- **Set** in `_handleMakeCall` immediately after a successful `sipHelper.call()`
- **Cleared** in `notifyCallPhase` when the first real SIP phase arrives (initiating, ringing, etc.) — at that point the existing phase-based suppression takes over
- **Also cleared** in `reconnect()` to avoid getting stuck

The flag is checked in two places:
1. **`_appendStreamingResponse`** — responses are dropped entirely during dial-pending, preventing the LLM from "burning" its greeting in conversation history before the call connects
2. **`suppressTts`** — belt-and-suspenders: even if a response somehow reaches the TTS path, audio is suppressed

Once the call reaches `CallPhase.connected`, the existing `_scheduleConnectedGreeting` fires and the agent greets properly.

## Files

- `phonegentic/lib/src/agent_service.dart` — `_callDialPending` flag, set/clear logic, response suppression
- `phonegentic/lib/src/models/agent_context.dart` — no changes (reference only for `isPreConnect` definition)
