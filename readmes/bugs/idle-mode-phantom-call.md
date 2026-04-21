# Idle-Mode Phantom Call

## Problem

The AI agent initiated a `make_call` to an arbitrary number (303-898-2988) without user intent. Root cause:

1. **SpeakerID "ignoring" doesn't gate transcription** — the Swift-layer SpeakerID logs "ignoring unknown mic user" but WhisperKit transcribes all mic audio regardless.
2. **No transcript logging before LLM** — we couldn't see what text triggered the `make_call` because transcripts forwarded to the TextAgent weren't logged at the point of delivery.
3. **No confirmation for dangerous tools when idle** — `make_call` executes immediately even when triggered from ambient/idle mode with no active call.

## Solution

Two targeted fixes:

1. **Log transcript text on delivery to TextAgent** — add a `debugPrint` in `_processTranscript` right before `addTranscript` so we can always see what the LLM received.
2. **Guard `make_call` when idle** — in `_onTextAgentToolCall`, when `_callPhase == CallPhase.idle`, return an error result instead of placing the call. The agent must ask the user to confirm, and only proceed when the user explicitly confirms via a follow-up transcript.

## Files

- `phonegentic/lib/src/agent_service.dart` — transcript logging + idle call guard
