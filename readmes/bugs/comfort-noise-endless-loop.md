# Comfort Noise Endless Loop + Post-Call SpeakerID Leak

## Problem

Two distinct but related issues appear in the logs after a call:

### 1. SpeakerID never stops after call ends

After every call ends, `[SpeakerID] Suppressed agent echo on mic (voiceprint match)` logs continue every ~3 seconds **indefinitely** (observed for 2+ hours non-stop). This happens because:

- The native `AudioTapChannel` mic IOProc remains active after `exitCallMode` ("direct mic capture continues")
- `SpeakerIdentifier` keeps running its 3-second embedding cycle on the mic audio
- The agent's TTS voiceprint (registered during the call) is never cleared, so it perpetually matches against ambient mic audio
- Neither `SpeakerIdentifier.resetSpeakerIdentifier()` nor any "pause" mechanism is called on call end

### 2. Comfort noise `stopPlayback` spam during TTS

During active calls, every TTS audio chunk triggers a `stopPlayback` call, producing dozens of `[ComfortNoise] stopPlayback (not playing)` log lines per response. This is cosmetic but indicates a wasteful call pattern — the comfort noise is stopped once on the first TTS chunk, then redundantly called for every subsequent chunk.

### 3. WhisperKit transcription loop feeds hallucinations

WhisperKit's 1.5-second transcription timer is never stopped when a call ends (only on `AgentService.reconnect()`/`dispose()`). This means it keeps processing mic audio post-call, producing `[BLANK_AUDIO]` tags every ~25 seconds. Combined with issue #1, the mic always has audio to process.

## Root Cause Analysis

**SpeakerID leak**: `AudioTapChannel.exitCallMode()` stops the WebRTC pipeline but explicitly keeps the mic IOProc alive. The `SpeakerIdentifier.shared.feedMicAudio()` path continues through the 100ms `flushBuffers` timer. The agent voiceprint matches ambient sound, producing the persistent log spam.

**Comfort noise spam**: In `agent_service.dart`, individual TTS chunk handlers call `comfortNoiseService?.stopPlayback()` for every chunk. Since `_playing` is already `false` after the first chunk stops it, subsequent calls hit the early-return path and log "not playing".

**WhisperKit continuation**: `WhisperKitSttService.stopTranscription()` is only called from `AgentService.reconnect()` and `dispose()`, not from call-end logic. The transcription timer keeps firing.

## Solution

### Fix 1: Pause SpeakerID processing when not in a call

In `AudioTapChannel.swift`, when `exitCallMode` is called, either:
- Stop feeding audio to `SpeakerIdentifier` when `callMode == false` in the `flushBuffers` timer
- Or call `SpeakerIdentifier.shared.pause()` / add a pause flag

### Fix 2: Deduplicate comfort noise stop calls

In `agent_service.dart`, only call `comfortNoiseService?.stopPlayback()` once when the first TTS chunk arrives — not for every chunk. The existing `_isTtsPlaying` flag in `WhisperRealtimeService` can gate this.

### Fix 3: Stop WhisperKit transcription on call end

In `AgentService._onCallPhaseChanged()`, when phase becomes `ended` or `failed`, call `_whisper.stopTranscription()` (or equivalent) to invalidate the native timer and clear buffers.

## Files

- `phonegentic/macos/Runner/AudioTapChannel.swift` — `flushBuffers` feeds SpeakerID unconditionally
- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — no pause/idle mechanism
- `phonegentic/lib/src/agent_service.dart` — TTS chunk handlers redundantly stop comfort noise; call-end doesn't stop WhisperKit
- `phonegentic/lib/src/comfort_noise_service.dart` — `stopPlayback` logs are noisy but the service itself is correct
- `phonegentic/lib/src/whisperkit_stt_service.dart` — `stopTranscription` not called on call end
