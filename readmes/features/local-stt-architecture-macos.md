# Local STT Architecture

This document describes the existing on-device (local) Speech-to-Text architecture, currently implemented for macOS via WhisperKit. It serves as a blueprint for porting equivalent functionality to Linux.

---

## Overview

The app supports two STT modes:

| Mode | Provider | Platform | Network |
|---|---|---|---|
| OpenAI Realtime | `SttProvider.openaiRealtime` | All | Cloud (WebSocket) |
| WhisperKit | `SttProvider.whisperKit` | macOS only | On-device |

Local STT is gated behind a compile-time feature flag (`ENABLE_ON_DEVICE_MODELS`) and a platform support check (`OnDeviceConfig.isSupported` — allows macOS, iOS, Linux). The Dart-side service and config exist already; only the native channel implementation is macOS-specific.

---

## Audio Specifications

All audio in the pipeline is standardized to:

- **Sample rate:** 24,000 Hz
- **Format:** PCM16 (signed 16-bit, little-endian)
- **Channels:** Mono
- **Chunk size:** 2,400 bytes ≈ 100 ms of audio

---

## Platform Channel Contracts

These are the Flutter Platform Channel names that form the API boundary between Dart and native code.

| Channel Name | Type | Direction | Purpose |
|---|---|---|---|
| `com.agentic_ai/audio_tap_control` | MethodChannel | Dart → Native | Start/stop audio capture and playback |
| `com.agentic_ai/audio_tap` | EventChannel | Native → Dart | Stream of raw PCM16 audio chunks |
| `com.agentic_ai/whisperkit_stt` | MethodChannel | Dart → Native | Initialize model, start/stop, feed audio |
| `com.agentic_ai/whisperkit_transcripts` | EventChannel | Native → Dart | Stream of transcription results |
| `com.agentic_ai/audio_devices` | MethodChannel | Dart → Native | Enumerate audio input/output devices |

---

## Dart Layer

### Configuration

**[lib/src/agent_config_service.dart](../phonegentic/lib/src/agent_config_service.dart)**

```dart
enum SttProvider { openaiRealtime, whisperKit }

class SttConfig {
  SttProvider provider;                // persisted as int index
  String whisperKitModelSize;          // 'tiny' | 'base' | 'small'
}
```

Stored in SharedPreferences under keys `agent_stt_provider` and `agent_stt_whisperkit_model`.

**[lib/src/on_device_config.dart](../phonegentic/lib/src/on_device_config.dart)**

```dart
class OnDeviceConfig {
  static const bool enabled = bool.fromEnvironment('ENABLE_ON_DEVICE_MODELS');
  static bool get isSupported => Platform.isMacOS || Platform.isIOS || Platform.isLinux;
}
```

### WhisperKit STT Service

**[lib/src/whisperkit_stt_service.dart](../phonegentic/lib/src/whisperkit_stt_service.dart)**

This Dart class owns both platform channels for the on-device STT path.

**MethodChannel** (`com.agentic_ai/whisperkit_stt`) — outbound calls:

| Method | Arguments | Returns | Description |
|---|---|---|---|
| `initialize` | `{'modelSize': String}` | `bool` | Load model from bundle |
| `isModelAvailable` | `{'modelSize': String}` | `bool` | Check model files exist |
| `startTranscription` | — | — | Begin streaming |
| `stopTranscription` | — | — | Stop streaming |
| `feedAudio` | `{'audio': Uint8List}` | — | Push PCM16 chunk to native |

**EventChannel** (`com.agentic_ai/whisperkit_transcripts`) — inbound stream:

```dart
// Each event is a Map:
{
  'text': String,       // transcribed text
  'isFinal': bool,      // segment complete?
  'language': String?,  // detected language (optional)
}

// Parsed into:
class WhisperKitTranscription {
  final String text;
  final bool isFinal;
  final String? language;
}
```

**Public API:**

```dart
Stream<WhisperKitTranscription> get transcriptions  // broadcast stream
bool get isInitialized
bool get isTranscribing
Future<bool> initialize(String modelSize)
Future<void> startTranscription()
Future<void> stopTranscription()
Future<void> feedAudio(Uint8List pcm16Data)
void dispose()
```

**Note:** `WhisperKitSttService` is not currently wired into `AgentService`. The active call path uses `WhisperRealtimeService` (OpenAI cloud). The on-device service exists as a standalone component ready for integration.

---

## Audio Input (Shared Infrastructure)

Audio capture is handled by a separate service pair — `audio_tap_control` / `audio_tap` — that is already implemented on both macOS and Linux. The WhisperKit channel receives audio via `feedAudio()` calls from Dart after the audio tap stream delivers chunks.

**Data flow for audio input:**

```
Microphone
  ↓
Native audio capture (24kHz PCM16 mono)
  [macOS: CoreAudio direct tap + WebRTC AEC]
  [Linux: PulseAudio stream_read_cb, 100ms chunks]
  ↓
EventChannel: com.agentic_ai/audio_tap  (Uint8List chunks)
  ↓
Dart: WhisperRealtimeService (or future integration point)
  ↓
feedAudio(pcm16Data) → MethodChannel: com.agentic_ai/whisperkit_stt
```

---

## macOS Native Implementation (WhisperKit)

**[macos/Runner/WhisperKitChannel.swift](../phonegentic/macos/Runner/WhisperKitChannel.swift)**

Registered in [macos/Runner/MainFlutterWindow.swift](../phonegentic/macos/Runner/MainFlutterWindow.swift).

### Key internals

- **WhisperKit instance:** `private var whisperKit: WhisperKit?` — Apple's framework
- **Processing queue:** `DispatchQueue` with `.userInitiated` QoS, label `com.agentic_ai.whisperkit_stt`
- **Buffer protection:** `NSLock` guards the raw PCM16 accumulation buffer
- **Transcription timer:** fires every 500 ms, flushes buffer and calls `kit.transcribe()`

### Model loading

```swift
// initialize(modelSize:)
WhisperKit(
  modelFolder: Bundle.main.bundlePath
    + "/Contents/Resources/models/whisperkit/openai_whisper-{size}",
  computeOptions: ModelComputeOptions(
    audioEncoderCompute: .cpuAndNeuralEngine,
    textDecoderCompute: .cpuAndNeuralEngine
  )
)
```

Model sizes: `tiny`, `base`, `small`. Models are bundled in the app at build time.

### Audio processing pipeline

```
feedAudio(pcm16Bytes)
  → append to NSLock-protected buffer
  
[Timer fires every 500ms]
  → processBufferedAudio()
     → drain buffer
     → convert PCM16 (Int16) → Float samples normalized to [-1.0, 1.0]
     → WhisperKit.transcribe(audioArray: [Float])
     → emit via EventChannel sink on DispatchQueue.main
```

### EventChannel emission (macOS)

```swift
// Sent on main queue via transcriptEventSink
[
  "text": transcription.text,
  "isFinal": true,
  "language": transcription.language ?? ""
]
```

---

## Linux Native Implementation (Current State)

**[linux/runner/audio_tap_channel.cc](../phonegentic/linux/runner/audio_tap_channel.cc)** — complete, uses PulseAudio

**No WhisperKit channel exists on Linux.** The `my_application.cc` initializer registers:

```c
self->audio_device_channel = audio_device_channel_new(messenger);
self->audio_tap_channel    = audio_tap_channel_new(messenger);
self->kokoro_tts_channel   = kokoro_tts_channel_new(messenger);
// ← no whisperkit_stt_channel
```

The audio pipeline (capture at 24kHz PCM16 mono via PulseAudio) is fully functional. What is missing is the STT channel that accepts audio and returns transcription events.

---

## What a Linux STT Implementation Must Provide

To be compatible with the existing Dart service (`WhisperKitSttService`) without any Dart changes, a Linux native implementation must:

### MethodChannel: `com.agentic_ai/whisperkit_stt`

Respond to these method calls:

| Call | Expected behavior |
|---|---|
| `initialize` | Load a Whisper model of the given size; return `true` on success |
| `isModelAvailable` | Return `true` if model files for given size exist on disk |
| `startTranscription` | Begin processing audio (e.g. start timer loop) |
| `stopTranscription` | Halt processing |
| `feedAudio` | Accept a `Uint8List` of raw PCM16 samples and accumulate in buffer |

### EventChannel: `com.agentic_ai/whisperkit_transcripts`

Emit `FL_VALUE_TYPE_MAP` events with keys:

| Key | Type | Notes |
|---|---|---|
| `text` | string | Transcribed text |
| `isFinal` | bool | `true` when segment is complete |
| `language` | string | May be empty string |

### Threading model (must match Linux conventions)

- Heavy work (inference) on a background thread (e.g. `GThread` or C++ `std::thread`)
- EventChannel sink calls must happen on the GLib main thread (`g_idle_add`)
- Shared buffer must be protected (e.g. `GMutex` or `std::mutex`)

---

## Candidate Libraries for Linux STT

The following are the most plausible drop-in Whisper backends for Linux:

| Library | Language | Notes |
|---|---|---|
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | C/C++ | GGML-based; CPU and CUDA; easy to embed; same model sizes |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | Python (CTranslate2) | Not suitable for direct C++ embedding |
| [whispercpp (Go)](https://github.com/coder/whispercpp) | Go | Not applicable |

**whisper.cpp** is the clear match: it is written in C/C++, has no heavy dependencies beyond optional CUDA, supports the same `tiny`/`base`/`small` model sizes (converted to GGUF), and can be linked directly into the Flutter Linux runner.

---

## File Map

### Dart (shared, all platforms)
| File | Role |
|---|---|
| [lib/src/whisperkit_stt_service.dart](../phonegentic/lib/src/whisperkit_stt_service.dart) | On-device STT bridge (channel client) |
| [lib/src/whisper_realtime_service.dart](../phonegentic/lib/src/whisper_realtime_service.dart) | OpenAI Realtime + audio I/O (active in calls) |
| [lib/src/agent_config_service.dart](../phonegentic/lib/src/agent_config_service.dart) | STT provider config persistence |
| [lib/src/on_device_config.dart](../phonegentic/lib/src/on_device_config.dart) | Feature flag + platform support check |
| [lib/src/agent_service.dart](../phonegentic/lib/src/agent_service.dart) | Agent orchestration; currently uses Realtime only |

### macOS (Swift)
| File | Role |
|---|---|
| [macos/Runner/WhisperKitChannel.swift](../phonegentic/macos/Runner/WhisperKitChannel.swift) | On-device STT channel implementation |
| [macos/Runner/AudioTapChannel.swift](../phonegentic/macos/Runner/AudioTapChannel.swift) | CoreAudio capture/playback + WebRTC AEC |
| [macos/Runner/MainFlutterWindow.swift](../phonegentic/macos/Runner/MainFlutterWindow.swift) | Channel registration |

### Linux (C++)
| File | Role |
|---|---|
| [linux/runner/audio_tap_channel.cc](../phonegentic/linux/runner/audio_tap_channel.cc) | PulseAudio capture/playback (complete) |
| [linux/runner/audio_tap_channel.h](../phonegentic/linux/runner/audio_tap_channel.h) | Header |
| [linux/runner/audio_device_channel.cc](../phonegentic/linux/runner/audio_device_channel.cc) | Device enumeration |
| [linux/runner/my_application.cc](../phonegentic/linux/runner/my_application.cc) | Channel registration (add new channel here) |
| [linux/runner/CMakeLists.txt](../phonegentic/linux/runner/CMakeLists.txt) | Build configuration (add new sources + link flags here) |
