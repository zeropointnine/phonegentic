#ifndef RUNNER_KOKORO_ONNX_ENGINE_H_
#define RUNNER_KOKORO_ONNX_ENGINE_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace kokoro {

/// Voice style embedding loaded from a voices/*.bin (NumPy .npy) file.
/// The data vector contains N*256 floats — N rows of 256-dim style vectors.
/// At inference time, row (phoneme_count - 1) is selected as the style input.
struct VoiceEmbedding {
  std::string name;
  std::vector<float> data;  // N × 256 floats (voice style pack)
};

/// Standalone C++ inference engine for Kokoro TTS using ONNX Runtime.
///
/// This class has no Flutter or GObject dependencies and can be tested in
/// isolation. The Flutter channel wrapper (kokoro_tts_channel.cc) calls into
/// this engine.
///
/// Thread safety: synthesis may be called from a background thread.
/// The ONNX session is created once and reused. espeak-ng calls are
/// serialized with a mutex because espeak-ng uses global state.
///
/// Conditional compilation: ONNX Runtime code is wrapped in
///   #ifdef HAS_ONNXRUNTIME
/// and espeak-ng code in
///   #ifdef HAS_ESPEAK_NG
/// so the project compiles without these libraries (graceful degradation,
/// matching the macOS #if canImport(KokoroSwift) pattern).
class KokoroOnnxEngine {
 public:
  KokoroOnnxEngine();
  ~KokoroOnnxEngine();

  // Non-copyable
  KokoroOnnxEngine(const KokoroOnnxEngine&) = delete;
  KokoroOnnxEngine& operator=(const KokoroOnnxEngine&) = delete;

  /// Initialize engine with ONNX model path and voices directory.
  /// Returns true on success, false on failure (logs error to stderr).
  bool initialize(const std::string& model_path,
                  const std::string& voices_dir);

  /// Returns true if initialize() succeeded.
  bool is_initialized() const;

  /// Check if model file exists at the given path.
  static bool is_model_available(const std::string& model_path);

  /// Set active voice by name. Returns true if voice was found.
  bool set_voice(const std::string& voice_name);

  /// Synthesize text → PCM16 audio (signed 16-bit LE, 24 kHz mono).
  /// Returns empty vector on failure.
  std::vector<int16_t> synthesize(const std::string& text,
                                   const std::string& voice_name);

  /// Warmup: run a discarded synthesis to prime the ONNX session.
  void warmup(const std::string& voice_name);

  /// Release all resources (ONNX session, espeak-ng, voice data).
  void dispose();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;  // PIMPL to hide ONNX/espeak headers
};

}  // namespace kokoro

#endif  // RUNNER_KOKORO_ONNX_ENGINE_H_
