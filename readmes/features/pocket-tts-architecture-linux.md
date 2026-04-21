# Pocket TTS — Architecture Reference

Pocket TTS is a 100M-parameter neural TTS model from Kyutai (creators of Moshi). It runs
entirely on CPU, supports zero-shot voice cloning from a short audio sample, and uses an
autoregressive architecture that produces audio token-by-token, enabling streaming output.
The ONNX export of the model weights is directly compatible with the ONNX Runtime already
used by the Kokoro engine.

This document covers the Linux implementation, which is complete. A macOS implementation
is forthcoming. The ONNX-based inference pipeline is platform-agnostic C++, so the engine
layer transfers directly; only the Flutter plugin channel layer (currently GObject/GLib)
requires a macOS-native equivalent. At RTF ~0.17 on M-series CPU (
Kyutai), and with the streaming architecture already in p<!--  -->lace, macOS latency will be
competitive without requiring MLX acceleration, though an MLX backend remains an option
for future optimization on Apple Silicon.

---

## Flutter-Level API

### Channel identifiers

```
MethodChannel  com.agentic_ai/pocket_tts
EventChannel   com.agentic_ai/pocket_tts_audio
```

### `PocketTtsService` (`lib/src/pocket_tts_service.dart`)

Implements `LocalTtsService` — the same abstract interface as `KokoroTtsService`. All
synthesis output is PCM16 LE 24 kHz mono, delivered over the EventChannel in 4800-byte
chunks (~200 ms each), identical to Kokoro. The same `playResponseAudio` path in
`WhisperRealtimeService` handles both engines unchanged.

#### Lifecycle methods

| Method | MethodChannel call | Notes |
|---|---|---|
| `isModelAvailable()` | `isModelAvailable` | Static; checks for sentinel model file |
| `initialize()` | `initialize` | Loads ONNX sessions + tokenizer + voice embeddings |
| `setVoice(voiceStyle)` | `setVoice` | Voice name: `"default"` or a cloned voice ID |
| `setGainOverride(gain)` | `setGainOverride` | See gain semantics below |
| `warmUpSynthesis()` | `warmup` | Runs discard synthesis to warm JIT caches |
| `dispose()` | `dispose` | Releases ONNX sessions and closes streams |

#### Synthesis methods

| Method | Description |
|---|---|
| `startGeneration()` | Marks start of a response; resets segmenter and sentence queue |
| `sendText(text)` | Feeds Claude delta text through `TextSegmenter`; queues complete sentences |
| `endGeneration()` | Flushes segmenter remainder; awaits drain of the synthesis queue |

Internally, `_synthesizeLoop()` sequentially invokes `synthesize` on each queued
sentence. The native side runs the full pipeline and streams PCM back over the EventChannel
while `synthesize` is awaited. `speakingState` emits `true` on `startGeneration` and
`false` when the drain completer resolves.

#### Voice cloning methods

| Method | MethodChannel call | Description |
|---|---|---|
| `cloneVoice(pcm16Bytes, voiceId)` | `encodeVoice` | Runs mimi_encoder on raw PCM16 24 kHz mono; stores embedding under `voiceId` |
| `cloneVoiceFromFile(filePath, voiceId)` | (Dart → `encodeVoice`) | Decodes file to PCM16 then calls `cloneVoice` |
| `exportVoiceEmbedding(voiceId)` | `exportVoiceEmbedding` | Returns embedding bytes for persistence |
| `importVoiceEmbedding(voiceId, data)` | `importVoiceEmbedding` | Restores a previously exported embedding |

#### Gain override

`setGainOverride(gain)` controls post-synthesis amplitude:

- `gain > 0` — fixed multiplier. 75.0 is the default, calibrated for the default voice
  (raw mimi_decoder RMS ≈ 0.002, target RMS ≈ 0.15).
- `gain == -1` — dynamic RMS normalization targeting −16 dBFS over the full utterance.
- `gain == 0` — pass-through (very quiet, ~−60 dBFS).

#### Audio file decoding (voice clone input)

`decodeAudioFileToPcm16(filePath)` decodes any supported audio file to PCM16 24 kHz mono:

- **WAV** — decoded natively in Dart: header parsed, stereo averaged to mono, resampled
  via linear interpolation if sample rate ≠ 24 kHz.
- **All other formats** (MP3, FLAC, OGG, M4A, AAC, …) — decoded via `ffmpeg` subprocess:
  ```
  ffmpeg -i <path> -ar 24000 -ac 1 -f s16le pipe:1
  ```

`getAudioDurationSeconds(filePath)` uses `ffprobe` to query duration before accepting a
file:
```
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 <path>
```

Both `ffmpeg` and `ffprobe` must be available on PATH. On Ubuntu/Debian:
```
sudo apt install ffmpeg
```

### Settings screen (`lib/src/widgets/agent_settings_tab.dart`)

Pocket TTS appears as a provider chip in the Voice Output card, visible only on Linux
(`Platform.isLinux`) when `OnDeviceConfig.isSupported` is true.

When Pocket TTS is selected, a **Voice clone** row is shown:
- Displays the basename of the currently configured clone file, or "Default" when none is set.
- **Browse** opens a file picker restricted to: `wav`, `mp3`, `m4a`, `ogg`, `flac`, `aac`.
- On file selection, `PocketTtsService.getAudioDurationSeconds` is called. If the duration
  exceeds **30 seconds**, the file is rejected with a floating SnackBar:
  > *"File too long — voice clone must be 30 seconds or less"*
- A clear (×) button removes the current clone path.
- The selected path is persisted in `TtsConfig.pocketTtsVoiceClonePath` via
  `AgentConfigService`.

### Config model (`lib/src/agent_config_service.dart`)

```dart
enum TtsProvider { none, elevenlabs, kokoro, pocketTts }

class TtsConfig {
  final TtsProvider provider;
  final String pocketTtsVoiceClonePath;  // path to reference audio file
  // ...
}
```

`isConfigured` returns `true` for `pocketTts` unconditionally (no API key needed).

---

## Linux Native Implementation

### Layer overview

```
Flutter Dart
    ↕ MethodChannel / EventChannel
pocket_tts_channel.cc   (GObject, Flutter Linux plugin layer)
    ↕ C++ function calls
pocket_tts_onnx_engine.cc   (PIMPL, no Flutter/GObject dependencies)
    ↕ ONNX Runtime C++ API
Four ONNX sessions: text_conditioner · flow_lm_main · flow_lm_flow · mimi_decoder
    ↕ SentencePiece C++ API
tokenizer.model (SentencePiece vocabulary)
```

### Channel layer (`pocket_tts_channel.h/.cc`)

GObject type `PocketTtsChannel`. Registered in `my_application.cc` alongside the Kokoro
channel. Handles all MethodChannel calls on GLib's main thread, dispatching synthesis to
a background thread via `g_thread_pool` (protected by `synth_mutex`). PCM chunks are
delivered back to the EventChannel sink via `g_idle_add`, matching the Kokoro pattern
exactly.

Model files are located relative to the binary at runtime:
```
<binary_dir>/data/flutter_assets/models/pocket-tts-onnx/
```
resolved via `/proc/self/exe`.

Method names handled:

| Method name | Action |
|---|---|
| `initialize` | Calls `engine->initialize()`, subscribes EventChannel |
| `isModelAvailable` | Calls `engine->is_model_available()` |
| `setVoice` | Calls `engine->set_voice()` |
| `setGainOverride` | Calls `engine->set_gain_override()` |
| `synthesize` | Dispatches to background thread; streams PCM via `g_idle_add` |
| `warmup` | Dispatches warmup synthesis to background thread |
| `dispose` | Calls `engine->dispose()` |
| `encodeVoice` | Dispatches voice encoding to background thread |
| `exportVoiceEmbedding` | Returns embedding bytes synchronously |
| `importVoiceEmbedding` | Restores embedding from bytes |

### Engine layer (`pocket_tts_onnx_engine.h/.cc`)

PIMPL class `pocket_tts::PocketTtsOnnxEngine`. No Flutter or GObject headers included.
Callable from any thread.

#### Model files

All under `models/pocket-tts-onnx/` (bundled at `data/flutter_assets/models/pocket-tts-onnx/`):

| File | Format | Role |
|---|---|---|
| `onnx/text_conditioner.onnx` | FP32 | Text embedding: token IDs → text context tensor |
| `onnx/flow_lm_main_int8.onnx` | INT8 | Autoregressive LM: emits one latent frame per step |
| `onnx/flow_lm_flow_int8.onnx` | INT8 | Flow matching: maps noise → latent via Euler integration |
| `onnx/mimi_decoder_int8.onnx` | INT8 | Mimi audio codec: latent frames → float PCM |
| `tokenizer.model` | SentencePiece | BPE tokenizer vocabulary |
| `reference_sample.wav` | WAV audio | Reference voice sample; encoded at startup into the `"default"` voice embedding |
| `onnx/mimi_encoder.onnx` | FP32 | Voice encoder (lazy-loaded on first `encodeVoice` call) |

Presence of `onnx/flow_lm_main_int8.onnx` is used as the sentinel for `isModelAvailable`.

#### Synthesis pipeline

1. **Text preparation** — trim whitespace, capitalize first letter, ensure terminal punctuation.
2. **Tokenize** — SentencePiece `EncodeAsIds` → `int64[]` token IDs.
3. **Parallel conditioning** — text_conditioner and voice conditioning run concurrently on
   separate threads:
   - `text_conditioner(token_ids)` → text embedding tensor.
   - Voice conditioning pass on `flow_lm_main`: feeds voice embedding into the LM state
     (one stateful forward pass with empty audio and the voice embedding as context).
4. **Text conditioning pass** — second stateful `flow_lm_main` forward pass feeding the
   text embedding.
5. **Autoregressive loop** — up to `kMaxFrames` steps:
   - `flow_lm_main(curr_latent, empty_voice_ctx)` → `(conditioning_vec, eos_logit)`.
   - Detect EOS when `eos_logit > kEosThreshold`; continue for `kFramesAfterEos` more steps.
   - **Flow matching** (`kLsdSteps` Euler steps):
     - Sample noise from `N(0, sqrt(0.7))` seeded deterministically per step.
     - Integrate: `x += flow_lm_flow(conditioning, s, t, x) * dt` for each sub-step.
   - Append resolved latent to `pending_latents`.
   - When `pending_latents.size() == kMimiChunkSize` (or at EOS), call `flush_pending`.
6. **`flush_pending`** — `mimi_decoder(latent_chunk)` → float PCM. Mimi decoder state
   persists across chunk boundaries for audio continuity. Decoded samples are appended to
   `all_pcm_float`.
7. **Post-processing** applied to the full utterance buffer:
   - High-frequency emphasis (see below).
   - Amplitude gain (fixed or dynamic RMS normalization; see gain semantics above).
   - Delivery in 4800-sample chunks via the `on_chunk` callback.

#### Key configuration constants

```cpp
static const int kLsdSteps      = 8;
static const int kMimiChunkSize = 4;
static constexpr float kHfEmphasisAlpha = 0.25f;
```

**`kLsdSteps`** — number of Euler integration steps in the flow matching network
(`flow_lm_flow`) per autoregressive frame. Controls the quality/speed tradeoff for the
latent-space diffusion (LSD) step:
- 4 — fastest; sane lower bound with acceptable quality.
- 8 — current production setting; reasonable balance.
- 32 — highest quality; sane upper bound.

Each step is one forward pass through `flow_lm_flow`, so halving `kLsdSteps` roughly
halves the time spent in flow matching. The total synthesis time is dominated by the
autoregressive LM loop, so the gain from reducing `kLsdSteps` is real but not dramatic.

**`kMimiChunkSize`** — number of latent frames accumulated before calling `mimi_decoder`.
Controls the interleaving between autoregressive generation and audio decoding:
- Smaller values → more frequent decoder calls → lower latency to first audio in principle,
  but the conditioning step (steps 3–4) dominates time-to-first-audio, so lowering this
  below 4 yields negligible perceptual improvement.
- Current value of 4 is chosen as a practical floor. The streaming architecture
  is already in place — each chunk is decoded and delivered as generation progresses rather
  than after the full loop completes.

**`kHfEmphasisAlpha`** — coefficient for the high-frequency emphasis filter applied to
decoded PCM before gain. The INT8-quantized `mimi_decoder_int8.onnx` exhibits noticeable
high-frequency rolloff above ~6 kHz, perceived as muffle compared to the FP32 reference.
The filter is a 1-pole FIR applied in-place:

```
y[n] = x[n] + α * (x[n] - x[n-1])
```

At α = 0.25 this provides approximately:
- +3 dB at Nyquist (12 kHz)
- +1.5 dB at 6 kHz
- +0.8 dB at 3 kHz
- 0 dB at DC

Set to `0.0f` to bypass. Applied before the gain step over the full utterance buffer.

#### Voice embedding format

Cloned and default voice embeddings are stored as `std::pair<int64_t, std::vector<float>>`
where the `int64_t` is the number of frames and the vector holds `n_frames × 1024` floats.
Cloned voices are kept in `std::map<std::string, ...> cloned_voices` guarded by a mutex.

Export/import binary format: `int32 n_frames | int32 n_dims | float32[n_frames × 1024]`.

---

## Dependencies

### Build-time guards

The engine and channel files compile to safe no-op stubs when dependencies are absent,
using the same conditional-compilation pattern as Kokoro:

```cpp
#ifdef HAS_ONNXRUNTIME      // set by CMake when ONNX Runtime is found
#ifdef HAS_SENTENCEPIECE    // set by CMake when SentencePiece is found
```

Both must be present for the engine to initialize.

### Required libraries (Linux)

| Library | Purpose | Install |
|---|---|---|
| ONNX Runtime | Neural network inference for all four ONNX sessions | Already present (Kokoro dep) |
| SentencePiece C++ | BPE tokenization | `sudo apt install libsentencepiece-dev` |
| ffmpeg / ffprobe | Decoding non-WAV voice clone reference files | `sudo apt install ffmpeg` |

`ffmpeg` and `ffprobe` are Dart-side dependencies invoked as subprocesses; they are not
linked into the binary. They must be installed in the system PATH on the target machine.

### Model files

Downloaded from `KevinAHM/pocket-tts-onnx` on Hugging Face (CC-BY 4.0, no access gate):

```
./scripts/download_models.sh pocket-tts
```

Downloads to `models/pocket-tts-onnx/`. The CMake build system bundles this directory
into the app at `data/flutter_assets/models/pocket-tts-onnx/`.

Total model size: ~180 MB (INT8 quantized). The voice encoder (`mimi_encoder.onnx`) used
for runtime voice cloning is a separate download and lazy-loaded on first use.

### Licensing

- Code (`kyutai-labs/pocket-tts`): MIT — fully permissive.
- Model weights (`kyutai/pocket-tts-without-voice-cloning`): CC-BY 4.0 — commercial use
  permitted; attribution to Kyutai required in app acknowledgements.
- Voice cloning weights (gated variant): CC-BY 4.0 + ethical use pledge (no illegal use,
  no unconsented cloning). Approval is immediate. Required before using `mimi_encoder.onnx`.

---

## CMake Integration

**`linux/runner/CMakeLists.txt`** — source files and SentencePiece detection:

```cmake
add_executable(${BINARY_NAME}
  ...
  "pocket_tts_channel.cc"
  "pocket_tts_onnx_engine.cc"
  ...
)

find_library(SENTENCEPIECE_LIB NAMES sentencepiece)
find_path(SENTENCEPIECE_INCLUDE NAMES sentencepiece_processor.h)
if(SENTENCEPIECE_LIB AND SENTENCEPIECE_INCLUDE)
  target_link_libraries(${BINARY_NAME} PRIVATE ${SENTENCEPIECE_LIB})
  target_include_directories(${BINARY_NAME} PRIVATE ${SENTENCEPIECE_INCLUDE})
  target_compile_definitions(${BINARY_NAME} PRIVATE HAS_SENTENCEPIECE)
endif()
```

**`linux/CMakeLists.txt`** — model bundling:

```cmake
set(POCKET_TTS_MODELS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../models/pocket-tts-onnx")
if(EXISTS "${POCKET_TTS_MODELS_DIR}")
  install(DIRECTORY "${POCKET_TTS_MODELS_DIR}"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/flutter_assets/models"
    COMPONENT Runtime
    PATTERN ".gitignore" EXCLUDE
  )
endif()
```

---

## Audio Output Format

PCM16 LE, 24 kHz, mono — identical to Kokoro. The EventChannel delivers 4800-byte chunks
(~100 ms of audio). The same `WhisperRealtimeService.playResponseAudio` path, `AudioTap`
ring buffer, and PulseAudio playback pipeline handle Pocket TTS audio without modification.
