# AEC / Echo Suppression — Cross-Platform Comparison

This document describes how acoustic echo (TTS playback bleeding into the mic) is suppressed across the three active audio paths. Layers are listed innermost (closest to hardware) to outermost (Dart).

---

## Path 1 — OpenAI Realtime, macOS (active call)

The most protected path. When a call connects, `callscreen.dart` calls `_tapChannel.invokeMethod('enterCallMode')`, activating the WebRTC pipeline inside `AudioTapChannel.swift`.

| Layer | Mechanism | Location |
|---|---|---|
| L0 — WebRTC APM | Full acoustic echo cancellation on the mic signal against the rendered remote audio. Removes speaker bleed at the signal level before anything else sees it. Disabled in conference mode (≥2 legs) to avoid wind-tunnel artifact. | `AudioTapChannel.swift` → `setAPMConferenceMode()` |
| L1 — TTS timestamp gate | During `flushBuffers()` (call-mode branch), the mic channel is excluded from the mix for 2 s after any TTS chunk was fed. Remote audio still flows; mic is silenced. Guards against TTS bleed that survives AEC. | `AudioTapChannel.swift:681` |
| L2 — Dart `_ttsSuppressed` | `sendAudio()` drops audio before sending to OpenAI — **bypassed** in call mode (`!inCallMode`); native is trusted. | `whisper_realtime_service.dart:752` |
| L3 — Text match | `_isEchoOfAgentResponse()` word-overlap check. Last resort, always active. | `agent_service.dart` |

---

## Path 2 — OpenAI Realtime, macOS (no active call / direct mode)

`enterCallMode` is never called; WebRTC APM is not running. TTS plays through AVAudioEngine.

| Layer | Mechanism | Location |
|---|---|---|
| L0 — Native sink gate | `isPlayingResponse = true` while AVAudioEngine is playing. `flushBuffers()` returns without emitting to the event sink — mic audio is captured but discarded natively. A 200 ms reverb-tail suppression follows. | `AudioTapChannel.swift:850` |
| L1 — Dart `_ttsSuppressed` | `sendAudio()` drops audio before sending to OpenAI, covering the brief reverb tail. | `whisper_realtime_service.dart:752` |
| L2 — Text match | `_isEchoOfAgentResponse()`. Last resort. | `agent_service.dart` |

---

## Path 3 — Local STT, macOS (WhisperKit)

### 3a — No active call (direct mode)

Native behavior is identical to Path 2. When TTS plays via AVAudioEngine, `isPlayingResponse = true` blocks the event sink in `flushBuffers()`. Mic chunks during TTS never reach Dart, so `feedAudio()` is never called with TTS-contaminated audio.

| Layer | Mechanism | Location |
|---|---|---|
| L0 — Native sink gate | Same `isPlayingResponse` gate as Path 2 — mic audio during TTS is discarded before the event sink fires. | `AudioTapChannel.swift:850` |
| L1 — Dart `feedAudio` gate | `!_speaking && !_whisper.ttsSuppressed` check before calling `feedAudio()`. `ttsSuppressed` includes a 300 ms cooldown after `isTtsPlaying` goes false to catch the reverb tail. Redundant on macOS direct (native already blocks), but provides defence-in-depth. | `agent_service.dart` |
| L2 — Echo guard buffer | Transcripts arriving within `_echoGuardMs` (2 s) of `_speakingEndTime` are buffered, then text-match filtered before reaching the LLM. `_speakingEndTime` is reset at playback-complete so the window covers actual audio end, not just generation end. | `agent_service.dart` |
| L3 — Text match | `_isEchoOfAgentResponse()`. Last resort. | `agent_service.dart` |

### 3b — Active call (hybrid: WebRTC + WhisperKit)

When a call connects, `enterCallMode` activates WebRTC APM. Mic audio flows through CapturePostProc (AEC, NS, AGC) before reaching Dart via the EventChannel. TTS audio is injected into the WebRTC render path for AEC reference, but AEC is imperfect — residual TTS can leak through, especially right after playback ends.

| Layer | Mechanism | Location |
|---|---|---|
| L0 — WebRTC APM | Same as Path 1 — AEC on the mic signal. Removes most speaker bleed but not perfect at transitions. | `AudioTapChannel.swift` |
| L1 — Dart `feedAudio` gate | `!_speaking && !_whisper.ttsSuppressed` — same as 3a. The 300 ms cooldown covers the transition gap where AEC residue is highest. | `agent_service.dart` |
| L2 — Echo guard buffer | Same as 3a. `_speakingEndTime` reset at playback-complete ensures the 2 s buffer covers the real playback tail, not just gen-done. | `agent_service.dart` |
| L3 — Text match | `_isEchoOfAgentResponse()`. Last resort. | `agent_service.dart` |

---

## Path 4 — Local STT, Linux (whisper.cpp)

**No native gate exists.** PulseAudio's `stream_read_cb` fires unconditionally regardless of TTS state and always schedules `send_audio_idle`. The Linux audio tap has no concept of TTS. The `captureOutput: false` flag passed from Dart is accepted by the method channel but then **ignored** — `start_capture()` takes no arguments and always opens the mic source.

| Layer | Mechanism | Location |
|---|---|---|
| L0 — VAD RMS gate | whisper.cpp VAD rejects ticks below `kMinEnergyRms = 0.010`. TTS bleed from speakers can exceed this, so not reliable alone. | `whisper_cpp_stt_channel.cc` |
| L1 — whisper model gate | `no_speech_thold = 0.60` — segments with high no-speech probability are dropped. Does not stop clean TTS speech. | `whisper_cpp_stt_channel.cc` |
| L2 — Dart `feedAudio` gate | `!_speaking && !_whisper.isTtsPlaying` check before calling `feedAudio()`. The C++ buffer receives no bytes during TTS; the VAD timer sees silence and drains without running inference. This is the primary echo defence on Linux. | `agent_service.dart:903` |
| L3 — Text match | `_isEchoOfAgentResponse()`. Last resort, catches garbled or partial transcriptions that slip through. | `agent_service.dart` |

---

## Summary

| Path | Native gate | Dart gate | Text match |
|---|---|---|---|
| Realtime / macOS in-call | WebRTC AEC + 2 s TTS mic strip | bypassed (`inCallMode`) | yes |
| Realtime / macOS direct | `isPlayingResponse` blocks event sink | `_ttsSuppressed` → skip sendAudio | yes |
| Local STT / macOS direct | `isPlayingResponse` blocks event sink | `ttsSuppressed` + echo guard buffer | yes |
| Local STT / macOS in-call | WebRTC AEC | `ttsSuppressed` + echo guard buffer | yes |
| Local STT / Linux | **none** | `ttsSuppressed` + echo guard buffer | yes |

Linux local STT is now equivalent to macOS local STT at the Dart layer. The remaining gap is that macOS's native gate fires inside the flush timer before `rawAudio` is even emitted to Dart, while on Linux the chunk still travels to Dart before being dropped. For the local-STT chat use case this difference is inconsequential.

---

## Relevant files

| File | Role |
|---|---|
| [macos/Runner/AudioTapChannel.swift](../../phonegentic/macos/Runner/AudioTapChannel.swift) | Native echo suppression for macOS (all paths) |
| [linux/runner/audio_tap_channel.cc](../../phonegentic/linux/runner/audio_tap_channel.cc) | Linux audio tap — no echo suppression |
| [linux/runner/whisper_cpp_stt_channel.cc](../../phonegentic/linux/runner/whisper_cpp_stt_channel.cc) | VAD and model-level gates |
| [lib/src/agent_service.dart](../../phonegentic/lib/src/agent_service.dart) | Dart `feedAudio` gate (L2 on Linux/macOS local STT) and text match |
| [lib/src/whisper_realtime_service.dart](../../phonegentic/lib/src/whisper_realtime_service.dart) | `_ttsSuppressed` gate, `inCallMode` flag |
| [lib/src/callscreen.dart](../../phonegentic/lib/src/callscreen.dart) | `enterCallMode` / `exitCallMode` invocations |
