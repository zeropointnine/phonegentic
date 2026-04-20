# Call Stats Spoken Aloud During Active Calls

## Problem

During active calls the agent sometimes echoes call state details vocally — things like "Call resumed. Remote: +15039971854. Host number: userpatricklemiuex66300. 2 parties on the call." This leaks PII (full phone numbers) and sounds robotic/confusing to the remote party.

The existing `_hallucinatedCallStateRe` filter catches `[CALL_STATE: ...]` tags, but the LLM sometimes echoes the *content* of call state messages without the tag prefix. The instructions already say "NEVER read these aloud" but the model doesn't always comply.

## Solution

Two-layer fix:

1. **TTS suppression in `_appendStreamingResponse`**: Add a regex that detects call-stats echoes (patterns like "Remote: +1...", "Host number: ...", "N parties on the call"). When matched during a live call, suppress TTS but still display the text in the chat panel — effectively making it a whisper-only message.

2. **Stronger system instructions**: Reinforce in `agent_context.dart` that call state details must never be spoken aloud, especially phone numbers, party counts, and connection status. These details are for internal awareness only.

## Files

- `phonegentic/lib/src/agent_service.dart` — added `_callStatsEchoRe` and TTS suppression logic
- `phonegentic/lib/src/models/agent_context.dart` — strengthened call state awareness instructions
