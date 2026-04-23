# Voiceprint Contamination Loop — Wrong Speaker Attribution

## Problem

After a call, the system attributes the caller as "Stan Cel" even when the person on the line is not Stan. This happens on every call from +14155331352 (contact #1441), with confidence scores 0.81–1.00, and it locks within two 3-second cycles.

The root cause is a **compounding contamination loop** in the voiceprint save path:

1. `_saveRemoteVoiceprint()` resolves the caller by phone number → contact #1441.
2. It calls `getRemoteSpeakerEmbedding()`, which looks up the FluidAudio `Speaker` whose **name** equals `identifiedRemoteSpeaker` (e.g. "Stan Cel") and returns that speaker's `currentEmbedding` — **Stan's pre-loaded voiceprint**, not the actual caller's voice.
3. This wrong embedding is merged into contact #1441's DB record via `upsertSpeakerEmbedding` (running mean).
4. On the next call, contact #1441's stored voiceprint is more Stan-like → even higher confidence match → locks faster → saves Stan's embedding again. Death spiral.

### Why the initial misidentification happens

If the real caller's voice is even moderately similar to Stan's stored voiceprint (cosine similarity ≥ 0.6), and no closer voiceprint exists, `assignSpeaker` picks Stan. Two consecutive hits at ≥ 0.75 locks it. Once contamination starts, confidence rises each call because the stored embedding converges toward Stan's.

## Solution

Two-pronged fix: (a) save the **raw** remote embedding instead of the identified speaker's, and (b) add a name-match guard to prevent cross-contact contamination.

### Fix 1: Track and return raw remote embedding (Swift)

In `SpeakerIdentifier.processAudioSegment`, store the extracted embedding for remote audio **before** `assignSpeaker` runs. Add `getRawRemoteEmbedding()` to return it. This always reflects the actual caller's voice.

### Fix 2: Name guard in `_saveRemoteVoiceprint()` (Dart)

Before saving, compare the SpeakerID-identified name against the contact's display name. If the identified name matches a **different** known contact, skip the save and log a warning.

## Files

- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — added `lastRawRemoteEmbedding` property, stored in `processAudioSegment` before `assignSpeaker`, added `getRawRemoteEmbedding()`, cleared in `reset()`
- `phonegentic/macos/Runner/AudioTapChannel.swift` — added `getRawRemoteEmbedding` method channel handler
- `phonegentic/lib/src/whisper_realtime_service.dart` — added `getRawRemoteEmbedding()` Dart wrapper
- `phonegentic/lib/src/agent_service.dart` — rewrote `_saveRemoteVoiceprint()` to use raw embedding and block save when identified name ≠ contact name
- `phonegentic/ios/Runner/AudioTapChannel.swift` — added `getRawRemoteEmbedding` to iOS stub list
- `phonegentic/linux/runner/audio_tap_channel.cc` — added `getRawRemoteEmbedding` stub

## Recovery

Existing contaminated voiceprints (e.g. contact #1441) should be deleted from the `speaker_embeddings` table to reset to a clean state. The contaminated record will be replaced organically on the next correctly identified call.
