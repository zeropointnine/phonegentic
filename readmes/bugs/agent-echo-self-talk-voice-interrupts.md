# Agent Echo / Self-Talk / Voice Persistence / Excessive Interrupts

## Problem

Three related issues during calls:

1. **Self-talk**: The agent responds to its own TTS echo being transcribed back, creating a feedback loop where it talks to itself in alternating voices.
2. **Voice persistence**: After cloning the remote party's voice (`set_agent_voice`), the `_voiceIdOverride` in `ElevenLabsTtsService` is never reset when the call ends. Subsequent interactions use the cloned voice instead of the default.
3. **Excessive interrupts**: The barge-in system (both VAD-based and transcript-based) triggers on very short noise/echo fragments, causing the agent to interrupt the remote party constantly.

Root causes:
- `_isEchoOfAgentResponse` skipped texts shorter than 8 characters, allowing short echo fragments like "Come up with.", "[laughs]", "It didn't." to pass through.
- Any non-echo transcript during `_speaking || isTtsPlaying` immediately triggered `_interruptAgent`, even for 1–2 word fragments that are almost always echo residue.
- The VAD barge-in debounce was only 600ms, too short to filter out echo/noise that the server VAD classifies as speech.
- `_disconnect()` cleared many call-scoped fields but never reset `_tts?.updateVoiceId()`, so the cloned voice persisted.

## Solution

### Phase 1

Four changes in `agent_service.dart`:

1. **Lowered echo detection minimum** from 8 to 4 characters in `_isEchoOfAgentResponse` so shorter echo fragments are caught.
2. **Added 3-word minimum for barge-in**: During `_speaking || isTtsPlaying`, transcripts with fewer than 3 words are buffered in `_pendingTranscripts` instead of triggering `_interruptAgent`. They'll be processed after the echo guard window.
3. **Increased VAD barge-in debounce** from 600ms to 900ms in `_onVadEvent` to reduce false triggers from echo/noise.
4. **Reset voice override on disconnect**: Added `_tts?.updateVoiceId(_bootContext.elevenLabsVoiceId)` in `_disconnect()` after the sampling cleanup, restoring the default voice between calls.

### Phase 2 — Repeated greeting after connect

The short-fragment filter from phase 1 correctly buffered "Hello?" from the remote party during the greeting, but when the buffer was flushed after the echo guard window, `_processTranscript` → `_textAgent.addTranscript()` triggered a new LLM call. The LLM saw the greeting it just sent + "Hello?" and produced a near-duplicate response.

5. **Post-connected-greeting grace period**: Added `_postGreetGraceUntil` (8 seconds). Set when `_tryFireConnectedGreeting()` fires. During this window, short remote-party transcripts (< 4 words, e.g. "Hello?", "Hi", "Hey there") are added as system context via `addSystemContext()` instead of `addTranscript()`, so they're visible to the LLM but don't trigger a new response. Substantial speech (>= 4 words) clears the grace window immediately. Reset on disconnect.

## Files

- `phonegentic/lib/src/agent_service.dart` — all five fixes
