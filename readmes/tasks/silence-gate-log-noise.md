# Silence gate & log noise reduction

## Problem

During idle silence on a call (or in direct mode), the audio pipeline keeps sending near-silent 100ms PCM chunks to the OpenAI Realtime API. Whisper transcribes each one as `[BLANK_AUDIO]`, which is correctly dropped by the hallucination filter — but the entire cycle is wasteful:

- Unnecessary API traffic and token spend on silence
- Console flooded with repetitive `[AgentService] Whisper hallucination dropped: "[BLANK_AUDIO]"` lines
- `[AudioTap] flush: mode=direct bytes=…` logged every ~5 seconds
- `[TelnyxMessaging] Poll found 50 inbound MDR records` on every poll even when nothing is new

## Solution

**Client-side silence gate** (`whisper_realtime_service.dart`):
- Compute RMS of each PCM chunk before sending
- If RMS < 0.008 and VAD is not active, increment a silence counter
- After 20 consecutive silent frames (~2 s), stop sending audio to the API
- Send a keepalive frame every ~10 s to prevent WebSocket timeout
- Reset immediately when energy rises or VAD reports speech

**Hallucination log rate-limiting** (`agent_service.dart`):
- Log the first 3 drops, then every 25th — includes running total
- Counter resets when real speech arrives

**TelnyxMessaging poll log** (`telnyx_messaging_provider.dart`):
- Removed the per-poll "found N records" line; the existing `$newCount new inbound message(s)` log covers actual arrivals

**AudioTap flush log** (`AudioTapChannel.swift`):
- Direct mode: log first 5 flushes, then every 500th (~50 s) instead of every 50th (~5 s)

## Files

- `phonegentic/lib/src/whisper_realtime_service.dart` — silence gate fields + `sendAudio` gating + `_computeRms`
- `phonegentic/lib/src/agent_service.dart` — `_hallucinationDropCount` + rate-limited log
- `phonegentic/lib/src/messaging/telnyx_messaging_provider.dart` — removed noisy poll log
- `phonegentic/macos/Runner/AudioTapChannel.swift` — reduced direct-mode flush log frequency
