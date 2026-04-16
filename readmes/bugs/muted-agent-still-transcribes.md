# Muted agent still produces transcripts

## Problem

When the agent is muted ("Not Listening…"), transcription continues and transcripts still appear. Two gaps:

1. **WhisperKit local STT path** — `feedAudio` only checked `_speaking` and `isTtsPlaying`, not `_muted`. Mic audio kept flowing into whisper.cpp inference.
2. **`_onTranscript` handler** — no mute guard, so any in-flight or buffered transcription events (from either the OpenAI Realtime server or WhisperKit) were still processed and displayed.

The OpenAI Realtime path was partially protected because `sendAudio` already returns early when `muted`, preventing new audio from reaching the server — but any already-queued server-side events could still arrive.

## Solution

- Added `!_muted` guard to the `_localAudioSub` listener so WhisperKit stops receiving mic chunks while muted.
- Added early `if (_muted) return` at the top of `_onTranscript` to drop any transcript events that arrive while muted, covering both STT paths.

## Files

- `phonegentic/lib/src/agent_service.dart` — both fixes
