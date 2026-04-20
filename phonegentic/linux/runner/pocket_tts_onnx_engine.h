#ifndef RUNNER_POCKET_TTS_ONNX_ENGINE_H_
#define RUNNER_POCKET_TTS_ONNX_ENGINE_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace pocket_tts {

/// Standalone C++ inference engine for Pocket TTS using ONNX Runtime.
///
/// Four-model pipeline: text_conditioner → flow_lm_main (autoregressive) →
/// flow_lm_flow (flow matching) → mimi_decoder.
/// Tokenization via SentencePiece.
///
/// Thread safety: synthesize() may be called from a background thread.
/// The ONNX sessions are thread-safe per ONNX Runtime docs.
///
/// Conditional compilation:
///   #ifdef HAS_ONNXRUNTIME   — ONNX inference
///   #ifdef HAS_SENTENCEPIECE — SentencePiece tokenization
/// Without either, every method returns a safe stub (false / empty).
class PocketTtsOnnxEngine {
 public:
  PocketTtsOnnxEngine();
  ~PocketTtsOnnxEngine();

  PocketTtsOnnxEngine(const PocketTtsOnnxEngine&) = delete;
  PocketTtsOnnxEngine& operator=(const PocketTtsOnnxEngine&) = delete;

  /// Initialize all four ONNX sessions and the SentencePiece tokenizer.
  /// models_dir must contain onnx/*.onnx and tokenizer.model.
  bool initialize(const std::string& models_dir);

  bool is_initialized() const;

  /// Check if the sentinel model file (flow_lm_main_int8.onnx) exists.
  static bool is_model_available(const std::string& models_dir);

  /// Set the active voice by name. Returns false if the voice is unknown.
  bool set_voice(const std::string& voice_name);

  /// Encode a short PCM16 audio clip (24 kHz mono) into a voice embedding and
  /// store it under voice_id. Lazily loads mimi_encoder.onnx on first call.
  bool encode_voice(const int16_t* pcm_data, size_t n_samples,
                    const std::string& voice_id);

  /// Serialize a previously encoded voice embedding to a binary blob.
  /// Returns empty on failure.
  std::vector<uint8_t> export_voice_embedding(const std::string& voice_id);

  /// Deserialize and store a voice embedding. Returns false on format error.
  bool import_voice_embedding(const std::string& voice_id,
                               const uint8_t* data, size_t size);

  /// Synthesize text → PCM16 (signed 16-bit LE, 24 kHz mono). Batch mode:
  /// returns all audio after full synthesis. Used by warmup.
  std::vector<int16_t> synthesize(const std::string& text,
                                   const std::string& voice_name);

  /// Streaming synthesis: calls on_chunk for each decoded PCM chunk as it
  /// becomes available (every kMimiChunkSize latent frames). First audio
  /// arrives after only the first chunk is generated rather than after the
  /// full autoregressive loop completes.
  void synthesize_streaming(
      const std::string& text,
      const std::string& voice_name,
      std::function<void(std::vector<int16_t>)> on_chunk);

  /// Override the post-synthesis amplitude gain applied to the decoded audio.
  ///
  /// gain > 0  — use this fixed multiplier instead of computing one from the
  ///             signal RMS. 75.0 (the default) is calibrated for the default
  ///             voice (mimi_decoder raw RMS ≈ 0.002, target 0.15). A fixed
  ///             gain has no signal-dependent artifacts and is safe for
  ///             streaming delivery.
  ///
  /// gain == -1 — fall back to adaptive RMS normalization: computes
  ///             gain from the utterance RMS and targets 0.15 (-16 dBFS) with
  ///             a 0.95 peak cap. Requires accumulating the full utterance
  ///             before delivery; can produce pumping if per-chunk normalization
  ///             is ever re-enabled.
  ///
  /// gain == 0  — disables all gain (pass-through). Audio will be very quiet
  ///             (~-60 dBFS) because the mimi_decoder output amplitude is low.
  void set_gain_override(float gain);

  /// Warmup: discard a synthesis to prime ONNX sessions.
  void warmup();

  void dispose();

 private:
  void synthesize_impl(const std::string& text,
                       const std::string& voice_name,
                       std::function<void(std::vector<int16_t>)> on_chunk);

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace pocket_tts

#endif  // RUNNER_POCKET_TTS_ONNX_ENGINE_H_
