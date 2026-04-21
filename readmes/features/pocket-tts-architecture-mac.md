# Pocket TTS — Architecture

Pocket TTS is an on-device streaming TTS engine backed by five ONNX models. The same
C++ inference engine runs on both Linux and macOS. Only the channel layer differs between
platforms: GObject/GLib on Linux, Swift + Objective-C++ on macOS.

---

## Flutter layer

### Service: `lib/src/pocket_tts_service.dart`

`PocketTtsService` owns two Flutter platform channels:

| Channel | Type | Purpose |
|---|---|---|
| `com.agentic_ai/pocket_tts` | `MethodChannel` | Control (initialize, synthesize, voice cloning, …) |
| `com.agentic_ai/pocket_tts_audio` | `EventChannel` | Streaming PCM16 audio chunks from native |

**Initialization sequence**

1. `isModelAvailable` — checks the native side before loading anything heavy.
2. `initialize` — loads ONNX sessions and tokenizer; returns a bool.
3. On success: resolves the default voice WAV path, decodes it to PCM16, and calls
   `encodeVoice` to prime the cloned-voice embedding.
4. `setVoice` — sets the named Pocket TTS voice style.
5. `warmup` — runs a silent synthesis to JIT-compile the ONNX graph.

**Default voice WAV path** is platform-specific because the binary location differs:

```dart
if (Platform.isMacOS) {
  // binary at Contents/MacOS/; models at Contents/Resources/
  refWav = '$binaryDir/../Resources/models/pocket-tts-onnx/reference_sample.wav';
} else {
  refWav = '$binaryDir/data/flutter_assets/models/pocket-tts-onnx/reference_sample.wav';
}
```

**Streaming synthesis pipeline**

Text is segmented into sentences by `TextSegmenter`. Each sentence is dispatched to the
native `synthesize` method on a serial synthesis queue. The native side calls back with
4800-byte PCM16 chunks over the `EventChannel`; `PocketTtsService` forwards these to
`AudioTap` for playback.

**Voice cloning**

`cloneVoiceFromFile(filePath, voiceId)` decodes the file to PCM16 24 kHz mono (WAV
natively, all other formats via ffmpeg), then sends the raw bytes to `encodeVoice`.
The native encoder runs `mimi_encoder.onnx` and stores the resulting embedding under
`voiceId`. Embeddings can be serialized to bytes (`exportVoiceEmbedding`) and restored
(`importVoiceEmbedding`) across sessions.

**ffmpeg/ffprobe path resolution**

macOS .app bundles do not inherit Homebrew's `PATH`. `_resolveBinary(name)` checks
`/opt/homebrew/bin` and `/usr/local/bin` before falling back to a bare name:

```dart
static String _resolveBinary(String binary) {
  if (Platform.isMacOS) {
    for (final prefix in ['/opt/homebrew/bin', '/usr/local/bin']) {
      final f = File('$prefix/$binary');
      if (f.existsSync()) return f.path;
    }
  }
  return binary;
}
```

Both `ffprobe` (duration check) and `ffmpeg` (non-WAV decode) go through this helper.
`getAudioDurationSeconds` also catches all exceptions and returns 0 so a missing
`ffprobe` degrades gracefully rather than silently aborting the Browse flow in settings.

### Method channel argument keys

All argument keys are shared between Dart, the Linux GObject channel, and the Swift
channel. Mismatches silently produce empty data on the native side.

| Method | Key | Value type |
|---|---|---|
| `encodeVoice` | `audioData` | `FlutterStandardTypedData` (PCM16 bytes) |
| `encodeVoice` | `voiceId` | `String` |
| `importVoiceEmbedding` | `voiceId` | `String` |
| `importVoiceEmbedding` | `embeddingData` | `FlutterStandardTypedData` |
| `exportVoiceEmbedding` | `voiceId` | `String` |
| `synthesize` | `text` | `String` |
| `synthesize` | `voice` | `String` |

### UI: `lib/src/widgets/agent_settings_tab.dart`

The Pocket TTS provider chip is shown when `Platform.isLinux || Platform.isMacOS`.
The voice clone row shows a Browse button that calls `FilePicker`, validates duration
via `getAudioDurationSeconds` (≤ 30 s), and saves the path to `TtsConfig`.
`AgentService` picks up the saved path on next initialization and calls
`cloneVoiceFromFile` to encode the custom embedding.

---

## macOS native layer

### Layer diagram

```
Dart (PocketTtsService)
  │  MethodChannel / EventChannel
  ▼
PocketTtsChannel.swift          ← Swift; owns channels, dispatches to engine
  │  Obj-C method calls
  ▼
PocketTtsEngine.mm              ← Obj-C++; thin wrapper, hides C++ from Swift
  │  C++ calls
  ▼
pocket_tts_onnx_engine.cc/.h    ← Pure C++; ONNX Runtime + SentencePiece
  │
  ├── text_conditioner.onnx
  ├── flow_lm_main_int8.onnx
  ├── flow_lm_flow_int8.onnx
  ├── mimi_decoder_int8.onnx
  └── mimi_encoder.onnx         ← lazy-loaded on first encodeVoice call
```

### Shared C++ engine: `native/pocket_tts/`

`pocket_tts_onnx_engine.h/.cc` is platform-agnostic and shared between Linux and macOS.
Linux references it from `linux/runner/CMakeLists.txt`; macOS adds it directly to the
Xcode Sources build phase.

Conditional compilation guards keep the file safe to compile without the dependencies:

- `#ifdef HAS_ONNXRUNTIME` — ONNX inference (set via `GCC_PREPROCESSOR_DEFINITIONS` in
  Xcode, or CMake `target_compile_definitions` on Linux)
- `#ifdef HAS_SENTENCEPIECE` — tokenizer (same)

Without either flag every method compiles to a safe stub returning false/empty.

**Inference pipeline** (text → PCM16 24 kHz mono):

1. SentencePiece tokenizes the text.
2. `text_conditioner.onnx` produces a text embedding.
3. `flow_lm_main_int8.onnx` runs autoregressively, generating latent tokens.
4. `flow_lm_flow_int8.onnx` applies flow matching.
5. `mimi_decoder_int8.onnx` decodes latents to audio, yielding chunks as they become
   available (`synthesize_streaming`).

**Voice conditioning** — if a cloned-voice embedding is present for the requested voice
id, it is passed as the reference style. Otherwise synthesis falls back to the built-in
style. `mimi_encoder.onnx` is lazy-loaded on the first `encode_voice` call.

### `PocketTtsEngine.h` / `PocketTtsEngine.mm`

An Objective-C++ wrapper that presents a pure Obj-C interface to Swift. No C++ types
cross the header boundary — all inputs and outputs use `NSString`, `NSData`, and `BOOL`.
The `.mm` file `#include`s `pocket_tts_onnx_engine.h` and holds a
`std::unique_ptr<pocket_tts::PocketTtsOnnxEngine>` ivar.

```objc
@interface PocketTtsEngine : NSObject
- (BOOL)initializeWithModelsDir:(NSString *)dir;
+ (BOOL)isModelAvailableAtDir:(NSString *)dir;
- (void)setVoice:(NSString *)voiceName;
- (void)setGainOverride:(float)gain;
- (NSData *)synthesize:(NSString *)text voice:(NSString *)voice;
- (void)synthesizeStreaming:(NSString *)text
                     voice:(NSString *)voice
                   onChunk:(void(^)(NSData *pcm))chunkCallback;
- (BOOL)encodeVoice:(NSData *)pcm16Data voiceId:(NSString *)voiceId;
- (NSData * _Nullable)exportVoiceEmbedding:(NSString *)voiceId;
- (BOOL)importVoiceEmbedding:(NSString *)voiceId data:(NSData *)data;
- (void)dispose;
@end
```

`synthesizeStreaming` bridges the C++ `std::function<void(std::vector<int16_t>)>` callback
to an Obj-C block by capturing the block in a lambda.

### `PocketTtsChannel.swift`

Swift channel bridge registered in `MainFlutterWindow.swift`. Owns a
`DispatchQueue(label: "com.agentic_ai.pocket_tts", qos: .userInitiated)` for all engine
calls so the main thread is never blocked.

**Model directory** is resolved from the app bundle at runtime:

```swift
private func modelsDir() -> String {
    Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources")
        .appendingPathComponent("models/pocket-tts-onnx")
        .path
}
```

**Streaming synthesis** calls `eng.synthesizeStreaming(_:voice:onChunk:)`. The chunk
callback slices each returned `NSData` into 4800-byte pieces (matching the Linux chunk
size) and dispatches each slice to the `EventChannel` sink on the main thread.

### Xcode project configuration (`Runner.xcodeproj`)

| Setting | Value |
|---|---|
| `CLANG_CXX_LANGUAGE_STANDARD` | `c++17` |
| `HEADER_SEARCH_PATHS` | `$(SRCROOT)/../native/pocket_tts` |
| `GCC_PREPROCESSOR_DEFINITIONS` | `HAS_ONNXRUNTIME=1 HAS_SENTENCEPIECE=1` |
| Sources build phase | `PocketTtsEngine.mm`, `PocketTtsChannel.swift`, `pocket_tts_onnx_engine.cc` |
| "Copy Pocket TTS Models" Run Script | runs before Compile Sources (see below) |

### Model bundling

A Run Script build phase copies models into the app bundle at build time:

```bash
MODELS_SRC="${SRCROOT}/../models/pocket-tts-onnx"
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/models/pocket-tts-onnx"
if [ -d "$MODELS_SRC" ]; then
  mkdir -p "$DEST"
  rsync -a --delete "$MODELS_SRC/" "$DEST/"
fi
```

`SRCROOT` is `phonegentic/macos/`, so `../models` resolves to `phonegentic/models/`.
Models are downloaded there by `scripts/download_models.sh pocket-tts`.

### Dependencies

**ONNX Runtime** — `macos/Podfile`:
```ruby
pod 'onnxruntime-c', '~> 1.20'
```
Microsoft's official CocoaPod; provides the same C API used on Linux.

**SentencePiece** — no official CocoaPod. Linked via Homebrew for development:
- `brew install sentencepiece`
- `/opt/homebrew/lib/libsentencepiece.a` added to "Link Binary With Libraries"
- `/opt/homebrew/include` added to header search paths

For distribution, build a static lib from source with CMake and commit to
`vendor/sentencepiece/macos/`.

**ffmpeg/ffprobe** — subprocess invoked by Dart; not linked into the app. Requires
`brew install ffmpeg` on the developer machine. The `_resolveBinary()` helper in
`PocketTtsService` finds the Homebrew binary even when launched as a .app.
