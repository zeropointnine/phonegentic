# TTS Broken — Agent Doesn't Speak

## Problem

After the PocketTTS preview feature changes, TTS stopped producing audio during agent conversations:

1. **Loop-breaker persists across reconnect**: `_consecutiveAgentResponses` was never reset in `reconnect()`, so once the loop-breaker triggered (consecutive >= 2), all subsequent responses were suppressed — even after reconnecting.

2. **First response produces no TTS**: Even on `consecutive=1` (passes the loop-breaker), no `[PocketTTS] Generation started` log appears, meaning `_activeTtsStartGeneration()` either isn't reached or `_localTts` is null when called. Diagnostic prints added to identify the exact failing condition.

## Solution

1. Reset `_consecutiveAgentResponses = 0` in `reconnect()` alongside other state resets.
2. Added diagnostic `debugPrint` in the `isFinal` TTS path showing whether conditions are met or which one is blocking.

## Files

- `phonegentic/lib/src/agent_service.dart` — reconnect counter reset + diagnostic prints
