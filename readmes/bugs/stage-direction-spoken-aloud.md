# Stage Directions Spoken Aloud by TTS

## Problem

The LLM sometimes generates parenthesized stage directions like "(Silent)", "(Pause)" as its response — intending to indicate it has nothing to say. These are streamed to ElevenLabs TTS and spoken aloud as literal words ("Silent"), then displayed as agent chat bubbles.

The existing `_stripBracketsForTts` only removes `[square bracket]` content. Parenthesized stage directions pass through unchanged.

## Solution

Added a `_stageDirectionRe` regex in `_appendStreamingResponse` that detects when the final response text is purely a parenthesized stage direction (e.g. `(Silent)`, `(Pause)`, `(Listening)`, `(Waiting)`). When matched:

1. Set `_ttsInterrupted = true` to prevent any further TTS audio
2. Call `_activeTtsEndGeneration()` to close the ElevenLabs WebSocket
3. Clear the native audio queue via `stopResponseAudio()` / `clearTTSQueue()`
4. Remove the in-progress streaming chat bubble from the message list
5. Reset voice UI sync state and notify listeners

This mirrors the barge-in interrupt flow to ensure clean TTS teardown.

## Files

- `phonegentic/lib/src/agent_service.dart` — added `_stageDirectionRe` regex and discard logic in `_appendStreamingResponse`
- `readmes/bugs/stage-direction-spoken-aloud.md` — this file
