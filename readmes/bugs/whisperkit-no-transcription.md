# WhisperKit on-device STT produces no transcriptions

## Problem

When using the WhisperKit (on-device) STT provider, the model initializes and starts successfully but never produces any transcription output. The logs show audio flowing from the mic tap but no transcription events are ever emitted.

Root causes:
1. **Sample rate mismatch**: The audio tap sends PCM16 at 24kHz, but WhisperKit's `transcribe(audioArray:)` expects 16kHz Float32. The `pcm16ToFloat` conversion only changed the data type without resampling, feeding 24kHz audio as if it were 16kHz — producing pitched-up garbage that Whisper couldn't transcribe.
2. **Too-short audio windows**: The transcription timer fired every 500ms, producing ~0.5s chunks. Whisper models need at least ~1s of speech context to produce meaningful output.
3. **No concurrency guard**: Multiple overlapping transcription Tasks could pile up if inference took longer than the timer interval.

## Solution

In `WhisperKitChannel.swift`:
- Replaced `pcm16ToFloat` with `pcm16ToFloat16k` that resamples 24kHz → 16kHz via linear interpolation before passing to WhisperKit.
- Increased the transcription interval from 500ms to 1500ms to accumulate more speech context.
- Added a minimum sample count check (16000 samples = 1s at 16kHz) — if the buffer is too small, audio is kept for the next cycle.
- Added an `isProcessing` guard to prevent concurrent transcription Tasks from piling up.

## Files

- `phonegentic/macos/Runner/WhisperKitChannel.swift` — sample rate conversion, timer interval, concurrency guard
