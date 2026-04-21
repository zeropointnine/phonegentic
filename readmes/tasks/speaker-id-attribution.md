# Speaker ID Attribution Improvements

## Problem

Three issues with the speaker identification system:

1. **Contact voiceprints matching on the mic** — All known contact voiceprints (e.g. "Jon Siragusa") are in a single FluidAudio `SpeakerManager` pool. When the host user speaks into the mic, the diarizer sometimes matches their voice to a contact's voiceprint with high confidence (0.85-0.98), producing confusing logs like `Mic (locked mic user) — ignoring Jon Siragusa (conf=0.97)`. This should never happen when there's no call — contacts should only match on remote/caller audio.

2. **Host user identity unknown** — The mic always shows as "unknown mic user" even though the host's name is configured in `AgentManagerConfig`. The system has no stored voiceprint for the host user.

3. **Agent TTS voice not registered** — The agent's TTS voiceprint is captured for echo suppression but isn't registered as a named speaker, so it shows as "Speaker N" if it ever appears in identification logs.

## Solution

### 1. Contact filtering on mic audio

In `SpeakerIdentifier.processAudioSegment`, when `!isRemote` (mic audio), any match whose `speaker.id` starts with `"contact_"` is now skipped with a clear log message. Contact voiceprints only match on remote/caller audio. Similarly, `agent_tts` matches are skipped from both channels since agent voice is handled by the dedicated `isAgentVoice` check.

### 2. Host user voiceprint

- Added `registerHostSpeaker(name:embedding:)` to `SpeakerIdentifier` (Swift) which registers a known speaker with ID `"host_user"`.
- On startup, `_loadKnownSpeakerEmbeddings` loads the stored host embedding from SQLite (via `CallHistoryDb.getHostEmbedding()`) and registers it.
- After the first successful transcript from the mic in idle mode, `_captureHostVoiceprint()` extracts the current host embedding from the diarizer, stores it in SQLite (contact_id=0), and registers it with the native speaker identifier. This is a one-time capture per session.

### 3. Agent as known speaker

When the agent's TTS voiceprint is captured in `extractAgentEmbedding`, it's now also registered with the `SpeakerManager` as a known speaker with ID `"agent_tts"` and name `"Agent"`. This ensures identification logs show "Agent" rather than "Speaker N".

## Files

- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — Contact filtering, agent_tts filtering, registerHostSpeaker, getHostSpeakerEmbedding, agent known speaker registration
- `phonegentic/macos/Runner/AudioTapChannel.swift` — Native channel handlers for registerHostSpeaker and getHostSpeakerEmbedding
- `phonegentic/lib/src/whisper_realtime_service.dart` — Dart-side methods: registerHostSpeaker, getHostSpeakerEmbedding
- `phonegentic/lib/src/agent_service.dart` — Host voiceprint capture/load logic, _captureHostVoiceprint, updated _loadKnownSpeakerEmbeddings
- `phonegentic/lib/src/db/call_history_db.dart` — upsertHostEmbedding and getHostEmbedding (uses contact_id=0)
- `phonegentic/ios/Runner/AudioTapChannel.swift` — Added stubs for new methods
- `phonegentic/linux/runner/audio_tap_channel.cc` — Added stubs for new methods
