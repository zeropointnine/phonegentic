# Recording Playback Access Control & Stream Playback

## Problem

The `play_call_recording` tool has no access control — any caller interacting with the agent could potentially trigger playback of another person's call recording. Only the manager/host (or someone explicitly instructed) should be able to listen to recordings. Additionally, when the manager calls in over the phone, there's no way to play the recording *over the call stream* so they can actually hear it — the current implementation only inserts an inline player widget in the chat UI.

## Solution

1. **Access control**: Gate `_handlePlayCallRecording` behind a host/manager check. If there's an active inbound call and the caller is NOT the configured agent manager, refuse the request. When idle (host using the device directly), allow unconditionally.

2. **Stream playback**: Add a `play_over_stream` boolean parameter to the tool. When true (and a call is active), load the WAV recording, convert to PCM16 24 kHz mono, and play it through the native audio tap (`playResponseAudio`) so it's audible over the phone line.

3. **Agent instructions**: Update the manager context and recording tool prompts so the LLM:
   - Only offers recordings to the host/manager
   - Asks whether to play over the stream when the manager is on a call
   - Never plays recordings for non-manager/non-host callers

4. **Richer call summaries**: The `get_call_summary` tool now accepts a `phone_number` filter (partial match via `searchCalls`'s `contactName` param). Summary output lines include relative timestamps (e.g. "5m ago", "2h 15m ago") so the agent can match requests like "play the call from 10 minutes ago". Display names and phone numbers are both shown when available.

## Files

- `phonegentic/lib/src/agent_service.dart` — handler, tool schema, manager context, instructions, summary output
- `phonegentic/lib/src/whisper_realtime_service.dart` — realtime tool schemas
- `readmes/features/recording-playback-access-control.md` — this file
