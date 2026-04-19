# WhisperKit STT Truncates First Words

## Problem

When the user starts speaking, the first 1-2 words are consistently missing from the WhisperKit local STT transcription. The rest of the utterance transcribes correctly.

**Root cause**: `WhisperKitChannel.processBufferedAudio()` grabs the entire accumulated audio buffer every 1500ms and sends it to WhisperKit. When speech begins near the end of a buffer cycle, the first buffer contains ~1400ms of silence + ~100ms of speech onset. WhisperKit processes this but the speech portion is too short to be reliably transcribed. Those initial words are consumed (buffer cleared) and lost. The next buffer gets the continuation of speech clearly, but the first words are gone.

## Solution

Added a **carry-over buffer** in `WhisperKitChannel.swift`. After each successful transcription, the last 500ms of audio is retained and prepended to the next buffer. This ensures speech that straddles a buffer boundary is always included in the next transcription window.

- `carryOverBuffer`: stores the tail 500ms (24,000 bytes at 24kHz PCM16) of each transcription's input
- On each `processBufferedAudio()` cycle: `audioData = carryOverBuffer + newAudio`
- After grabbing the combined buffer, save the new tail as carry-over
- Carry-over is cleared on start/stop transcription

The overlap means WhisperKit will occasionally re-transcribe ~500ms of audio. Since the Dart side already handles transcript deduplication via the hallucination filter and context accumulation, duplicate words from the overlap are naturally handled.

## Files

| File | Change |
|------|--------|
| `phonegentic/macos/Runner/WhisperKitChannel.swift` | Added `carryOverBuffer` + `carryOverBytes` fields; prepend carry-over in `processBufferedAudio()`; save tail after each cycle; clear on start/stop |
