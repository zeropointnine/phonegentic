# Thinking Dots During Call Lifecycle

## Problem

The three-dot thinking indicator in the agent panel has two issues:

1. **Dots don't appear between host/remote party speaking and agent speaking** — `_thinking = true` is set at the END of `_processTranscript`, after an async `await _whisper.getSpeakerInfo()` call. By the time the flag is set, the agent response may already be arriving (especially in OpenAI realtime mode), so the dots are either never visible or flash too briefly.

2. **Dots persist after call ends** — `_thinking` is never cleared in the `notifyCallPhase` ended/failed cleanup, so dots can remain visible after a call terminates.

## Solution

1. Set `_thinking = true` earlier: in `_onTranscript` right before calling `_processTranscript`, and in `_flushPendingTranscripts` right before each `_processTranscript` call. This ensures dots appear as soon as a valid transcript passes the guard checks, before any async work begins.

2. Add `_thinking = false` to the call-ended/failed cleanup in `notifyCallPhase`.

## Files

- `phonegentic/lib/src/agent_service.dart` — `_onTranscript`, `_flushPendingTranscripts`, `notifyCallPhase`
