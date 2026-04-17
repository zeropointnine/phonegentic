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

## Phase 2 — Reduce over-modulation

### Problem

The gain was set far too high (Dart called `setRemoteGain` with 5.0, Swift default was 2.0), causing the remote party's audio to clip and distort.

### Solution

Lowered the gain to 1.5x (~+3.5 dB) in both places:
- Dart `_enterCallMode()` now sends `1.5` instead of `5.0`
- Swift default `remoteGain` changed from `2.0` to `1.5`

This keeps the remote party audible above the baseline without hard-clipping on normal-level SIP audio.

## Files

- `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` — `remoteGain` default: 2.0 → 1.5
- `phonegentic/lib/src/callscreen.dart` — `setRemoteGain` argument: 5.0 → 1.5
