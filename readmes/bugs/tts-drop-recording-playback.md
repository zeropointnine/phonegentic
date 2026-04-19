# TTS DROP Spam During Recording Playback Over Call

## Problem

When the agent streams a call recording over an active phone call via `play_call_recording` with `play_over_stream=true`, hundreds of `[WebRTCAudioProcessor] TTS DROP` log messages per second flood the console, making debugging impossible.

**Root cause:** `_playRecordingOverStream` loads the entire WAV file (e.g. 19 MB / 403 seconds), converts it to PCM16 24 kHz, then pumps 1-second chunks into the native ring buffers as fast as `await` returns. The ring buffers are only 30 seconds deep (720,000 samples at 24 kHz). Once they fill, every subsequent `feedTTS` call logs a DROP line — which fires for every chunk (~400 times) and for every undersized write within each chunk.

Secondary issue: the TTS DROP log has no rate-limiting, so even a brief overflow produces a wall of log output.

## Solution

1. **Pace the Dart streaming loop** — after each chunk write, delay by roughly the chunk's playback duration so writes never outrun the ring buffer's drain rate. The ring buffers hold 30 seconds, and each chunk is ~1 second, so a ~900 ms delay between chunks keeps the buffer at a healthy fill level.

2. **Rate-limit the native TTS DROP log** — cap it to at most one message per second so any remaining edge-case drops don't flood the console.

## Files

- `phonegentic/lib/src/agent_service.dart` — `_playRecordingOverStream` pacing
- `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` — TTS DROP log throttle
