# Remote Audio Gain Boost

## Problem

The remote party (AI agent) is too quiet during SIP calls. The macOS `RenderPreProcessor` hooks into WebRTC's incoming audio pipeline for TTS mixing, whisper tapping, and beep detection, but passes the remote audio through to speakers at its original level with no amplification. WebRTC's built-in AGC only affects the local microphone capture path, not the render (playback) path.

## Solution

Added a configurable `remoteGain` multiplier (default 2.0, i.e. +6 dB) applied in the render audio path. The gain is applied **after** whisper tap and tone detection (which need the original signal levels) but **before** TTS mixing (so the agent's own TTS voice stays at its intended volume).

The gain is exposed as a platform channel method (`setRemoteGain`) so it can be adjusted from Dart at runtime — currently set to 2.0x on call connect via `_enterCallMode()`.

Key design decisions:
- Hard clipping (clamping to ±32768) rather than a soft limiter — keeps latency at zero and avoids complexity; clipping is rare at 2x gain since remote SIP audio is typically well below full scale.
- Gain applied per-sample in the real-time audio callback (~480 samples per 10ms frame at 48 kHz) — negligible CPU cost.
- Whisper feed and tone detection see the original un-boosted signal so AI transcription accuracy and beep detection thresholds are unaffected.

## Files

- `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` — added `remoteGain` property; applied gain in `RenderPreProcessor.audioProcessingProcess`
- `phonegentic/macos/Runner/AudioTapChannel.swift` — added `setRemoteGain` platform channel handler
- `phonegentic/ios/Runner/AudioTapChannel.swift` — added `setRemoteGain` to no-op stub list
- `phonegentic/lib/src/callscreen.dart` — calls `setRemoteGain` with 2.0 on call connect
