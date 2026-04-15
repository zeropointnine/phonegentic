# Local STT Architecture — Linux (whisper.cpp)

This document describes the on-device Speech-to-Text implementation for Linux, using whisper.cpp as the inference backend. It is the Linux counterpart of [local-stt-architecture-macos.md](local-stt-architecture-macos.md).

---

## Overview

| Mode | Provider | Platform | Network |
|---|---|---|---|
| OpenAI Realtime | `SttProvider.openaiRealtime` | All | Cloud (WebSocket) |
| whisper.cpp | `SttProvider.whisperKit` | Linux (+ macOS via WhisperKit) | On-device |

The Linux implementation reuses the same Dart service (`WhisperKitSttService`) and the same Flutter platform channel names as the macOS WhisperKit implementation. No Dart code changes are needed to switch between platforms — only the native channel implementation differs.

---

## Audio Specifications

| Property | Value |
|---|---|
| Capture sample rate | 24,000 Hz (PulseAudio output) |
| Whisper inference rate | 16,000 Hz (whisper.cpp requirement) |
| Format | PCM16, signed 16-bit little-endian, mono |
| Chunk size from audio tap | ~2,400 bytes ≈ 100 ms |

**Resampling:** The inference thread downsamples 24 kHz → 16 kHz using linear interpolation (ratio 3:2) before each `whisper_full()` call. Feeding 24 kHz audio directly causes severe quality degradation (model hears speech at 1.5× speed with wrong pitch).

---

## File Map

### Dart (shared)
| File | Role |
|---|---|
| [lib/src/whisperkit_stt_service.dart](../../phonegentic/lib/src/whisperkit_stt_service.dart) | On-device STT channel client — unchanged, shared with macOS |
| [lib/src/whisper_realtime_service.dart](../../phonegentic/lib/src/whisper_realtime_service.dart) | Audio I/O; exposes `rawAudio` stream for local STT feed |
| [lib/src/agent_config_service.dart](../../phonegentic/lib/src/agent_config_service.dart) | `SttConfig` with `whisperKitModelSize` and `whisperKitUseGpu` |
| [lib/src/agent_service.dart](../../phonegentic/lib/src/agent_service.dart) | Agent orchestration; `_initLocalSttPath()` for local STT mode |
| [lib/src/text_agent_service.dart](../../phonegentic/lib/src/text_agent_service.dart) | Text LLM; `OpenAiCaller` now also used for `TextAgentProvider.openai` |

### Linux (C++)
| File | Role |
|---|---|
| [linux/runner/whisper_cpp_stt_channel.h](../../phonegentic/linux/runner/whisper_cpp_stt_channel.h) | GObject header — public API |
| [linux/runner/whisper_cpp_stt_channel.cc](../../phonegentic/linux/runner/whisper_cpp_stt_channel.cc) | Full channel implementation (~500 lines) |
| [linux/runner/my_application.cc](../../phonegentic/linux/runner/my_application.cc) | Channel registration |
| [linux/runner/CMakeLists.txt](../../phonegentic/linux/runner/CMakeLists.txt) | Build config: FetchContent whisper.cpp, opportunistic GPU |

### Model assets
| Path | Notes |
|---|---|
| `phonegentic/models/whisper-ggml/` | Tracked by git (`.gitkeep` only; binaries in `.gitignore`) |
| `ggml-tiny.en.bin` | ~75 MB |
| `ggml-base.en.bin` | ~148 MB |
| `ggml-small.en.bin` | ~488 MB |

Models are declared as Flutter assets in `pubspec.yaml` and land at:
```
{build}/data/flutter_assets/models/whisper-ggml/ggml-{size}.en.bin
```

Download via: `scripts/download_models.sh whisper`

---

## Build System (CMakeLists.txt)

whisper.cpp is pulled at configure time via CMake `FetchContent` — no system package required.

```cmake
FetchContent_Declare(
  whisper
  GIT_REPOSITORY https://github.com/ggerganov/whisper.cpp.git
  GIT_TAG        v1.7.5
)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(whisper)
```

**Opportunistic GPU detection** — both backends can coexist in the same binary; the runtime `use_gpu` flag selects which is used:

```cmake
find_package(Vulkan QUIET)
if(Vulkan_FOUND)
  set(GGML_VULKAN ON CACHE BOOL "" FORCE)   # vendor-agnostic
endif()

find_package(CUDAToolkit QUIET)
if(CUDAToolkit_FOUND)
  set(GGML_CUDA ON CACHE BOOL "" FORCE)     # NVIDIA
endif()
```

---

## Platform Channel Contracts

Channel names are **identical** to macOS so `WhisperKitSttService.dart` requires no changes.

| Channel | Type | Direction |
|---|---|---|
| `com.agentic_ai/whisperkit_stt` | MethodChannel | Dart → Native |
| `com.agentic_ai/whisperkit_transcripts` | EventChannel | Native → Dart |

### MethodChannel calls

| Method | Arguments | Returns | Notes |
|---|---|---|---|
| `initialize` | `{modelSize: String, useGpu: bool}` | `bool` | Loads GGML model; `use_gpu` passed to `whisper_context_params` |
| `isModelAvailable` | `{modelSize: String}` | `bool` | `stat()` check on model file path |
| `startTranscription` | — | — | Clears buffer, resets VAD state, starts 500 ms GLib timer |
| `stopTranscription` | — | — | Stops timer, sets `is_transcribing = false` |
| `feedAudio` | `{audio: Uint8List}` | — | Appends PCM16 bytes to buffer under `GMutex` |
| `dispose` | — | — | Frees whisper context, stops timer |

### EventChannel emission

```c
// Map sent per utterance on the GLib main thread via g_idle_add:
{
  "text":     fl_value_new_string(text),   // transcribed text
  "isFinal":  fl_value_new_bool(TRUE),     // always true (batch inference)
  "language": fl_value_new_string("en"),
}
```

---

## Native Channel Implementation

**File:** [linux/runner/whisper_cpp_stt_channel.cc](../../phonegentic/linux/runner/whisper_cpp_stt_channel.cc)

Follows the GObject pattern used by all other Linux runner channels (`KokoroTtsChannel`, `AudioTapChannel`). Registered in `my_application.cc` alongside those channels.

### Struct fields

```c
struct _WhisperCppSttChannel {
  GObject parent_instance;

  FlMethodChannel* method_channel;
  FlEventChannel*  event_channel;
  gboolean         event_listening;
  gboolean         shutting_down;

  whisper_context* ctx;            // null until initialize() succeeds
  gboolean         is_initialized;
  gboolean         is_transcribing;
  gboolean         is_inferring;   // set/cleared on main thread around each job

  GMutex           buffer_mutex;
  GByteArray*      audio_buffer;   // accumulates PCM16 bytes between timer ticks
  guint            timer_id;

  // VAD state
  gsize            last_tick_end;        // buffer byte offset at last timer tick
  guint            silence_ticks;        // consecutive low-energy 500 ms ticks
  gboolean         has_speech_in_buffer; // voiced speech seen since last submit
};
```

### Threading model

```
GLib main thread (Flutter platform thread)
  ├─ method_call_cb()       — handles all MethodChannel calls
  ├─ on_transcription_timer() — VAD tick, spawns inference job
  └─ send_transcript_idle() — emits EventChannel event (via g_idle_add)

GThread "whisper-infer"     — one at a time (guarded by is_inferring)
  └─ infer_thread_func()    — resampling + whisper_full() + g_idle_add result
```

`is_inferring` is set on the main thread before spawning and cleared in `send_transcript_idle` (also main thread via `g_idle_add`). A new inference job is only spawned if `is_inferring == FALSE`.

`shutting_down` is set in `_dispose_impl` and checked by the idle callback before making any Flutter calls.

---

## VAD (Voice Activity Detection)

The macOS WhisperKit implementation has no VAD — it relies on WhisperKit's internal handling. whisper.cpp is a batch inference library with no built-in VAD; submitting silent audio causes `[BLANK_AUDIO]` hallucinations and wasted GPU cycles.

### Timer-level VAD (end-of-utterance detection)

Fires every 500 ms on the GLib main thread.

1. Compute RMS energy of audio received **since the last tick** (incremental, not the whole buffer).
2. **Speech detected** (`rms >= kMinEnergyRms`): set `has_speech_in_buffer = true`, reset `silence_ticks = 0`.
3. **Silence tick** (`rms < kMinEnergyRms` after speech): increment `silence_ticks`.
4. **Submit** when `has_speech_in_buffer && silence_ticks >= kSilenceTriggerTicks` (default: 2 ticks = 1 second of silence following speech).
5. **Emergency overflow** at 8 seconds: if `has_speech_in_buffer`, submit anyway; otherwise drain silently without inference.

### Constants

| Constant | Default | Meaning |
|---|---|---|
| `kTimerIntervalMs` | 500 | Timer granularity (ms) |
| `kMinEnergyRms` | 0.010 | Silence gate threshold (normalised float, ~−40 dBFS) |
| `kSilenceTriggerTicks` | 2 | Post-speech silence ticks before submit (×500ms = 1 s) |
| `kMinSpeechBytes` | 24000 × 2 / 2 | Minimum buffer size before any submit (~0.5 s) |
| `kMaxBufferBytes` | 24000 × 2 × 8 | Emergency cap (~8 s) |

### Why not match the macOS 500 ms fixed timer?

macOS submits every 500 ms regardless of silence because WhisperKit is a streaming framework. Doing the same with whisper.cpp would generate a transcript (or `[BLANK_AUDIO]`) every 500 ms of audio, flooding the LLM with empty or partial utterances.

---

## Inference Pipeline

```
infer_thread_func():

1. PCM16 bytes → float32 [-1.0, 1.0]

2. Resample 24000 Hz → 16000 Hz (linear interpolation, ratio 3:2)
     n_out = n_in × 16000 / 24000
     for i in [0, n_out):
       pos = i × (n_in / n_out)
       out[i] = lerp(pcm[floor(pos)], pcm[ceil(pos)], frac(pos))

3. whisper_full_params:
     language         = "en"
     no_speech_thold  = 0.60    ← whisper-level silence gate
     print_progress   = false
     print_timestamps = false

4. whisper_full(ctx, params, pcm, n_samples)

5. Per segment:
     - skip if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.60
     - concatenate whisper_full_get_segment_text(ctx, i)

6. Strip leading/trailing whitespace.
   Filter exact hallucination tokens: [BLANK_AUDIO] (music) (applause) (silence)

7. g_idle_add(send_transcript_idle) → emit EventChannel map on main thread
```

---

## Dart Integration

### SttConfig changes

```dart
class SttConfig {
  final SttProvider provider;
  final String whisperKitModelSize;  // 'tiny' | 'base' | 'small'
  final bool whisperKitUseGpu;       // NEW — passed to whisper_context_params.use_gpu
}
// Persisted as: agent_stt_whisperkit_use_gpu (bool)
```

### AgentService — local STT path

When `SttConfig.provider == SttProvider.whisperKit && OnDeviceConfig.isSupported`, `_init()` branches to `_initLocalSttPath()` instead of connecting to OpenAI Realtime.

```
_initLocalSttPath():
  _isLocalSttMode = true
  _whisperKitStt = WhisperKitSttService(config: _sttConfig)
  _whisperKitStt.initialize()

  _whisper.startAudioTap(captureInput: true, captureOutput: false)
  //  ↑ captureOutput MUST be false — capturing speaker output would feed
  //    TTS playback back into whisper.cpp, looping the agent's own voice.

  _whisperKitStt.startTranscription()
  _localAudioSub = _whisper.rawAudio.listen(
    (chunk) => _whisperKitStt.feedAudio(chunk)
  )

  _initTextAgent()          // initializes text LLM (Claude)
  if (_textAgent == null):  // OpenAI provider bails in _initTextAgent normally
    _textAgent = TextAgentService(config: tc, ...)  // force-init
    _initTts()
```

**`_isLocalSttMode` flag effects:**

| Location | Effect |
|---|---|
| `_onTranscript` | Allows transcripts through when `_callPhase == CallPhase.idle` (same as `_splitPipeline`) |
| `_appendStreamingResponse` | Sets `deferAgentTextForTts = false` — text appears immediately without waiting for TTS PCM |
| `reconnect()` | Resets flag and disposes `_whisperKitStt` |

### TextAgentService fix

`TextAgentService._createCaller()` previously threw `UnimplementedError` for `TextAgentProvider.openai` (assumption: OpenAI Realtime handles text in-band). In local STT mode, the OpenAI Chat Completions API is used instead:

```dart
TextAgentProvider.openai => OpenAiCaller(
  http,
  baseUrl: Uri.parse('https://api.openai.com/v1/chat/completions'),
),
```

### Voice-hold bypass

The split pipeline normally holds agent response text until the first TTS PCM chunk arrives (to sync text display with audio onset). In local STT mode this causes responses to appear invisible until TTS starts — or never if TTS is interrupted. Since local STT is a chat interface (not a phone call), text is shown immediately:

```dart
final deferAgentTextForTts =
    _splitPipeline && !_isLocalSttMode && _hasTts && ttsActive && !suppressTts;
//                    ↑ bypass for local STT
```

---

## Known Limitations / Future Work

- **No GPU toggle in settings UI** — `whisperKitUseGpu` is persisted but has no UI control on Linux yet. It defaults to `true` (GPU enabled at runtime if the binary was compiled with Vulkan/CUDA support).
- **English-only models** — model filenames use the `.en.bin` suffix (English-only quantized models). Multi-language models would require removing `.en` from `get_model_path()`.
- **No streaming/incremental output** — `whisper_full()` is batch inference over the full utterance. There is no partial transcript during the user's speech, only a final result after the post-speech silence window.
- **Echo cancellation** — PulseAudio does not perform hardware AEC. TTS playback echo is avoided by setting `captureOutput: false`, which means the mic may still pick up speaker bleed in a loud environment. WebRTC AEC (available on macOS) is not implemented on Linux.
- **Single whisper context** — `whisper_full()` is not thread-safe on the same context. The `is_inferring` flag ensures only one inference runs at a time; rapid speech may queue up.
