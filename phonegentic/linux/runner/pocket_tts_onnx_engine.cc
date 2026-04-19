#include "pocket_tts_onnx_engine.h"

#include <algorithm>
#include <chrono>
#include <map>
#include <mutex>
#include <random>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <thread>
#include <sys/stat.h>
#include <vector>

// HAS_ONNXRUNTIME and HAS_SENTENCEPIECE are defined by CMake when the
// corresponding libraries are found. Without them the engine compiles to safe
// no-op stubs, matching the Kokoro HAS_ONNXRUNTIME / HAS_ESPEAK_NG pattern.

#ifdef HAS_ONNXRUNTIME
#include <onnxruntime_cxx_api.h>
#endif

#ifdef HAS_SENTENCEPIECE
#include <sentencepiece_processor.h>
#endif

namespace pocket_tts {

// ── Constants ────────────────────────────────────────────────────────────────
static const int kLsdSteps      = 8;     // flow matching Euler steps; 4 is sane lower bound (fastest); 32 is sane upper bound (best); 8 is reasonable for production probably
static const int kMaxFrames     = 500;   // max autoregressive frames
static const int kFramesAfterEos = 3;   // keep generating after EOS detected
static const float kEosThreshold = -4.0f;
static const int kMimiChunkSize = 4;    // latent frames per mimi_decoder call; note, not really worth lowering this value; most of the cost for 'time to first audio' is in the conditioning step

// High-frequency emphasis applied to decoded PCM before gain.
// Compensates for the HF rolloff inherent to int8-quantized neural codecs
// (mimi_decoder_int8.onnx rolls off noticeably above ~6 kHz, which is
// perceived as muffle).  Filter: y[n] = x[n] + kHfEmphasis*(x[n] - x[n-1])
// — a 1-pole FIR that boosts ~+3 dB at Nyquist (12 kHz), ~+1.5 dB at 6 kHz,
// ~0.8 dB at 3 kHz, 0 dB at DC.  Set to 0.0f to bypass.
static constexpr float kHfEmphasisAlpha = 0.25f;

// ═══════════════════════════════════════════════════════════════════════════════
// Impl struct — hides ONNX Runtime and SentencePiece from the header
// ═══════════════════════════════════════════════════════════════════════════════

struct PocketTtsOnnxEngine::Impl {
  bool  initialized   = false;
  // See set_gain_override() for semantics. 75 = fixed gain calibrated for
  // the default voice (mimi_decoder raw RMS ≈ 0.002, target 0.15).
  float gain_override = 75.0f;

  std::string models_dir_cached;  // stored during initialize() for lazy encoder load

#ifdef HAS_ONNXRUNTIME
  Ort::Env              ort_env{ORT_LOGGING_LEVEL_WARNING, "PocketTtsOnnx"};
  Ort::SessionOptions   session_opts;
  Ort::AllocatorWithDefaultOptions allocator;

  // Pre-loaded default voice embeddings [n_frames × 1024].
  std::vector<float> default_voice_data;
  int64_t default_voice_frames = 0;
  static const int64_t kVoiceDim = 1024;

  // Cloned voices: voiceId → (n_frames, float embeddings [n_frames × 1024]).
  std::map<std::string, std::pair<int64_t, std::vector<float>>> cloned_voices;
  std::mutex cloned_voices_mutex;

  std::unique_ptr<Ort::Session> text_conditioner;
  std::unique_ptr<Ort::Session> flow_lm_main;
  std::unique_ptr<Ort::Session> flow_lm_flow;
  std::unique_ptr<Ort::Session> mimi_decoder;

  // Lazily loaded voice encoder (Phase 3).
  std::unique_ptr<Ort::Session> mimi_encoder;
  bool encoder_loaded = false;

  // Cached I/O name strings (string storage keeps pointers alive)
  std::vector<std::string>  tc_in_storage,   tc_out_storage;
  std::vector<std::string>  lm_in_storage,   lm_out_storage;
  std::vector<std::string>  fl_in_storage,   fl_out_storage;
  std::vector<std::string>  mi_in_storage,   mi_out_storage;
  std::vector<std::string>  enc_in_storage,  enc_out_storage;
  std::vector<const char*>  tc_in_names,     tc_out_names;
  std::vector<const char*>  lm_in_names,     lm_out_names;
  std::vector<const char*>  fl_in_names,     fl_out_names;
  std::vector<const char*>  mi_in_names,     mi_out_names;
  std::vector<const char*>  enc_in_names,    enc_out_names;

  // ── helpers ────────────────────────────────────────────────────────────────

  static void load_io_names(Ort::Session& sess,
                             Ort::AllocatorWithDefaultOptions& alloc,
                             std::vector<std::string>& in_storage,
                             std::vector<const char*>& in_names,
                             std::vector<std::string>& out_storage,
                             std::vector<const char*>& out_names) {
    size_t ni = sess.GetInputCount();
    in_storage.resize(ni);
    in_names.resize(ni);
    for (size_t i = 0; i < ni; ++i) {
      in_storage[i] = std::string(sess.GetInputNameAllocated(i, alloc).get());
      in_names[i]   = in_storage[i].c_str();
    }
    size_t no = sess.GetOutputCount();
    out_storage.resize(no);
    out_names.resize(no);
    for (size_t i = 0; i < no; ++i) {
      out_storage[i] = std::string(sess.GetOutputNameAllocated(i, alloc).get());
      out_names[i]   = out_storage[i].c_str();
    }
  }

  /// Create a zero-filled tensor of the given dtype and shape.
  /// Symbolic dimensions (< 0) in shape are replaced with 0.
  static Ort::Value make_zero_tensor(Ort::AllocatorWithDefaultOptions& alloc,
                                      std::vector<int64_t> shape,
                                      ONNXTensorElementDataType dtype) {
    for (int64_t& d : shape) if (d < 0) d = 0;

    size_t elem_count = 1;
    bool empty = false;
    for (int64_t d : shape) {
      if (d == 0) { empty = true; break; }
      elem_count *= static_cast<size_t>(d);
    }
    if (empty) elem_count = 0;

    switch (dtype) {
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: {
        Ort::Value v = Ort::Value::CreateTensor<float>(
            alloc, shape.data(), shape.size());
        if (elem_count > 0)
          std::fill_n(v.GetTensorMutableData<float>(), elem_count, 0.0f);
        return v;
      }
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: {
        Ort::Value v = Ort::Value::CreateTensor<int64_t>(
            alloc, shape.data(), shape.size());
        if (elem_count > 0)
          std::fill_n(v.GetTensorMutableData<int64_t>(), elem_count, int64_t{0});
        return v;
      }
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: {
        Ort::Value v = Ort::Value::CreateTensor<bool>(
            alloc, shape.data(), shape.size());
        if (elem_count > 0)
          std::fill_n(v.GetTensorMutableData<bool>(), elem_count, false);
        return v;
      }
      default: {
        Ort::Value v = Ort::Value::CreateTensor<float>(
            alloc, shape.data(), shape.size());
        if (elem_count > 0)
          std::fill_n(v.GetTensorMutableData<float>(), elem_count, 0.0f);
        return v;
      }
    }
  }

  /// Initialize state tensors for a stateful session. Scans inputs for names
  /// starting with "state_" and creates zero tensors matching their shapes.
  std::vector<Ort::Value> init_states(Ort::Session& sess) {
    std::vector<Ort::Value> states;
    size_t n = sess.GetInputCount();
    for (size_t i = 0; i < n; ++i) {
      auto name = sess.GetInputNameAllocated(i, allocator);
      if (strncmp(name.get(), "state_", 6) != 0) continue;
      auto type_info   = sess.GetInputTypeInfo(i);
      auto tensor_info = type_info.GetTensorTypeAndShapeInfo();
      states.push_back(make_zero_tensor(
          allocator,
          tensor_info.GetShape(),
          tensor_info.GetElementType()));
    }
    return states;
  }

  /// Run a stateful session. Consumes non_state_inputs and states, returns
  /// the first num_non_state_out output values; updates states from remaining
  /// outputs (out_state_N → state_N ordering).
  std::vector<Ort::Value> run_stateful(
      Ort::Session& sess,
      const std::vector<const char*>& in_names,
      const std::vector<const char*>& out_names,
      std::vector<Ort::Value>& non_state_inputs,   // consumed
      std::vector<Ort::Value>& states,             // consumed & replaced
      size_t num_non_state_out) {
    // Combine inputs
    std::vector<Ort::Value> all_in;
    all_in.reserve(non_state_inputs.size() + states.size());
    for (auto& v : non_state_inputs) all_in.push_back(std::move(v));
    for (auto& v : states)           all_in.push_back(std::move(v));
    states.clear();

    auto all_out = sess.Run(Ort::RunOptions{nullptr},
                            in_names.data(), all_in.data(), all_in.size(),
                            out_names.data(), out_names.size());

    // Split outputs
    std::vector<Ort::Value> result;
    result.reserve(num_non_state_out);
    for (size_t i = 0; i < num_non_state_out && i < all_out.size(); ++i)
      result.push_back(std::move(all_out[i]));
    for (size_t i = num_non_state_out; i < all_out.size(); ++i)
      states.push_back(std::move(all_out[i]));

    return result;
  }

  /// Create a float32 tensor [shape] filled with val.
  Ort::Value make_float_tensor(const std::vector<int64_t>& shape, float val) {
    Ort::Value v = Ort::Value::CreateTensor<float>(
        allocator, shape.data(), shape.size());
    size_t n = 1;
    bool empty = false;
    for (int64_t d : shape) { if (d == 0) { empty = true; break; } n *= d; }
    if (!empty)
      std::fill_n(v.GetTensorMutableData<float>(), n, val);
    return v;
  }

  /// Create a float32 tensor from a raw buffer.
  Ort::Value make_float_tensor_from(const std::vector<int64_t>& shape,
                                     const float* data) {
    Ort::Value v = Ort::Value::CreateTensor<float>(
        allocator, shape.data(), shape.size());
    size_t n = 1;
    for (int64_t d : shape) n *= static_cast<size_t>(d);
    if (n > 0) std::memcpy(v.GetTensorMutableData<float>(), data, n * sizeof(float));
    return v;
  }

  /// float32 → PCM16, matching Kokoro's clamp-and-scale.
  static std::vector<int16_t> float_to_pcm16(const float* data, size_t n) {
    std::vector<int16_t> out(n);
    for (size_t i = 0; i < n; ++i) {
      float s = std::max(-1.0f, std::min(1.0f, data[i]));
      out[i] = static_cast<int16_t>(s * 32767.0f);
    }
    return out;
  }
#endif  // HAS_ONNXRUNTIME

#ifdef HAS_SENTENCEPIECE
  sentencepiece::SentencePieceProcessor sp;
#endif

  /// Prepare text: trim, ensure uppercase start, ensure punctuation end.
  static std::string prepare_text(const std::string& text_in) {
    size_t s = text_in.find_first_not_of(" \t\n\r");
    if (s == std::string::npos) return ".";
    size_t e = text_in.find_last_not_of(" \t\n\r");
    std::string t = text_in.substr(s, e - s + 1);
    if (t.empty()) return ".";
    if (isalnum(static_cast<unsigned char>(t.back()))) t += '.';
    if (islower(static_cast<unsigned char>(t[0])))
      t[0] = static_cast<char>(toupper(static_cast<unsigned char>(t[0])));
    return t;
  }
};

// ── Constructor / Destructor ─────────────────────────────────────────────────

PocketTtsOnnxEngine::PocketTtsOnnxEngine() : impl_(new Impl()) {}

PocketTtsOnnxEngine::~PocketTtsOnnxEngine() {
  if (impl_->initialized) dispose();
}

// ── Static helpers ───────────────────────────────────────────────────────────

// static
bool PocketTtsOnnxEngine::is_model_available(const std::string& models_dir) {
  std::string sentinel =
      models_dir + "/onnx/flow_lm_main_int8.onnx";
  struct stat st;
  return stat(sentinel.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// ── Initialize ───────────────────────────────────────────────────────────────

bool PocketTtsOnnxEngine::initialize(const std::string& models_dir) {
  if (impl_->initialized) return true;

#if !defined(HAS_ONNXRUNTIME) || !defined(HAS_SENTENCEPIECE)
  (void)models_dir;
  fprintf(stderr,
          "[PocketTTS] Missing required deps (ONNX Runtime and/or "
          "SentencePiece) — cannot initialize\n");
  return false;
#else
  impl_->models_dir_cached = models_dir;

  if (!is_model_available(models_dir)) {
    fprintf(stderr, "[PocketTTS] Model files not found in: %s\n",
            models_dir.c_str());
    return false;
  }

  // ── 1. Configure session options ──────────────────────────────────────────
  impl_->session_opts.SetIntraOpNumThreads(
      std::min(static_cast<int>(std::thread::hardware_concurrency()), 4));
  impl_->session_opts.SetGraphOptimizationLevel(
      GraphOptimizationLevel::ORT_ENABLE_ALL);

  // ── 2. Load ONNX sessions ─────────────────────────────────────────────────
  try {
    auto load = [&](const std::string& rel) -> std::unique_ptr<Ort::Session> {
      std::string path = models_dir + "/" + rel;
      fprintf(stderr, "[PocketTTS] Loading: %s\n", path.c_str());
      return std::unique_ptr<Ort::Session>(
          new Ort::Session(impl_->ort_env, path.c_str(),
                           impl_->session_opts));
    };
    impl_->text_conditioner = load("onnx/text_conditioner.onnx");
    impl_->flow_lm_main     = load("onnx/flow_lm_main_int8.onnx");
    impl_->flow_lm_flow     = load("onnx/flow_lm_flow_int8.onnx");
    impl_->mimi_decoder     = load("onnx/mimi_decoder_int8.onnx");
  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[PocketTTS] ONNX session load error: %s\n", e.what());
    return false;
  }

  // ── 3. Cache I/O names for all sessions ───────────────────────────────────
  Impl::load_io_names(*impl_->text_conditioner, impl_->allocator,
                      impl_->tc_in_storage,  impl_->tc_in_names,
                      impl_->tc_out_storage, impl_->tc_out_names);
  Impl::load_io_names(*impl_->flow_lm_main, impl_->allocator,
                      impl_->lm_in_storage,  impl_->lm_in_names,
                      impl_->lm_out_storage, impl_->lm_out_names);
  Impl::load_io_names(*impl_->flow_lm_flow, impl_->allocator,
                      impl_->fl_in_storage,  impl_->fl_in_names,
                      impl_->fl_out_storage, impl_->fl_out_names);
  Impl::load_io_names(*impl_->mimi_decoder, impl_->allocator,
                      impl_->mi_in_storage,  impl_->mi_in_names,
                      impl_->mi_out_storage, impl_->mi_out_names);

  // ── 4. Load SentencePiece tokenizer ───────────────────────────────────────
  std::string sp_path = models_dir + "/tokenizer.model";
  auto status = impl_->sp.Load(sp_path);
  if (!status.ok()) {
    fprintf(stderr, "[PocketTTS] SentencePiece load failed: %s — %s\n",
            sp_path.c_str(), status.ToString().c_str());
    return false;
  }

  // ── 5. Load default voice embeddings ─────────────────────────────────────
  std::string voice_bin_path = models_dir + "/default_voice.bin";
  FILE* vf = fopen(voice_bin_path.c_str(), "rb");
  if (!vf) {
    fprintf(stderr, "[PocketTTS] WARNING: default_voice.bin not found at %s — "
            "voice conditioning disabled (audio will be low quality)\n",
            voice_bin_path.c_str());
  } else {
    int32_t hdr[2] = {0, 0};
    fread(hdr, sizeof(int32_t), 2, vf);
    impl_->default_voice_frames = hdr[0];
    int64_t expected_dim = hdr[1];
    size_t n_elems = static_cast<size_t>(hdr[0]) * static_cast<size_t>(hdr[1]);
    impl_->default_voice_data.resize(n_elems);
    size_t read = fread(impl_->default_voice_data.data(), sizeof(float), n_elems, vf);
    fclose(vf);
    if (read != n_elems || expected_dim != Impl::kVoiceDim) {
      fprintf(stderr, "[PocketTTS] WARNING: default_voice.bin corrupt (read=%zu expected=%zu dim=%lld)\n",
              read, n_elems, (long long)expected_dim);
      impl_->default_voice_data.clear();
      impl_->default_voice_frames = 0;
    } else {
      fprintf(stderr, "[PocketTTS] Voice embeddings loaded: %lld frames × %lld dims\n",
              (long long)impl_->default_voice_frames, (long long)Impl::kVoiceDim);
    }
  }

  // ── Diagnostic: dump I/O names for all sessions ──────────────────────────
  auto dump_names = [](const char* label,
                       const std::vector<const char*>& in_names,
                       const std::vector<const char*>& out_names) {
    fprintf(stderr, "[PocketTTS-IO] %s inputs:\n", label);
    for (size_t i = 0; i < in_names.size(); ++i)
      fprintf(stderr, "  [%zu] %s\n", i, in_names[i]);
    fprintf(stderr, "[PocketTTS-IO] %s outputs:\n", label);
    for (size_t i = 0; i < out_names.size(); ++i)
      fprintf(stderr, "  [%zu] %s\n", i, out_names[i]);
  };
  dump_names("text_conditioner", impl_->tc_in_names, impl_->tc_out_names);
  dump_names("flow_lm_main",     impl_->lm_in_names, impl_->lm_out_names);
  dump_names("flow_lm_flow",     impl_->fl_in_names, impl_->fl_out_names);
  dump_names("mimi_decoder",     impl_->mi_in_names, impl_->mi_out_names);

  impl_->initialized = true;
  fprintf(stderr, "[PocketTTS] Initialized (models_dir=%s)\n",
          models_dir.c_str());
  return true;
#endif
}

bool PocketTtsOnnxEngine::is_initialized() const {
  return impl_->initialized;
}

bool PocketTtsOnnxEngine::set_voice(const std::string& voice_name) {
  if (!impl_->initialized) return false;
  if (voice_name.empty() || voice_name == "default") return true;
#ifdef HAS_ONNXRUNTIME
  std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
  return impl_->cloned_voices.count(voice_name) > 0;
#else
  return false;
#endif
}

void PocketTtsOnnxEngine::set_gain_override(float gain) {
  impl_->gain_override = gain;
  if (gain < 0.0f)
    fprintf(stderr, "[PocketTTS] Gain: dynamic RMS normalization\n");
  else if (gain == 0.0f)
    fprintf(stderr, "[PocketTTS] Gain: pass-through (no gain)\n");
  else
    fprintf(stderr, "[PocketTTS] Gain: fixed %.1fx\n", gain);
}

// ── Dispose ──────────────────────────────────────────────────────────────────

void PocketTtsOnnxEngine::dispose() {
  if (!impl_->initialized) return;
#ifdef HAS_ONNXRUNTIME
  impl_->text_conditioner.reset();
  impl_->flow_lm_main.reset();
  impl_->flow_lm_flow.reset();
  impl_->mimi_decoder.reset();
  impl_->mimi_encoder.reset();
  impl_->encoder_loaded = false;
  {
    std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
    impl_->cloned_voices.clear();
  }
#endif
  impl_->initialized = false;
  fprintf(stderr, "[PocketTTS] Disposed\n");
}

// ── Voice cloning ────────────────────────────────────────────────────────────

bool PocketTtsOnnxEngine::encode_voice(const int16_t* pcm_data,
                                        size_t n_samples,
                                        const std::string& voice_id) {
#if !defined(HAS_ONNXRUNTIME)
  return false;
#else
  if (!impl_->initialized || !pcm_data || n_samples == 0 || voice_id.empty())
    return false;

  // Lazy-load mimi_encoder.onnx on first call.
  if (!impl_->encoder_loaded) {
    std::string enc_path = impl_->models_dir_cached + "/onnx/mimi_encoder.onnx";
    struct stat st;
    if (stat(enc_path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
      fprintf(stderr, "[PocketTTS] mimi_encoder.onnx not found: %s\n",
              enc_path.c_str());
      return false;
    }
    try {
      impl_->mimi_encoder = std::unique_ptr<Ort::Session>(
          new Ort::Session(impl_->ort_env, enc_path.c_str(),
                           impl_->session_opts));
      Impl::load_io_names(*impl_->mimi_encoder, impl_->allocator,
                          impl_->enc_in_storage, impl_->enc_in_names,
                          impl_->enc_out_storage, impl_->enc_out_names);
      impl_->encoder_loaded = true;
      fprintf(stderr, "[PocketTTS] mimi_encoder loaded (%zu inputs, %zu outputs)\n",
              impl_->enc_in_names.size(), impl_->enc_out_names.size());
    } catch (const Ort::Exception& e) {
      fprintf(stderr, "[PocketTTS] mimi_encoder load error: %s\n", e.what());
      return false;
    }
  }

  // PCM16 → float32 normalized [-1, 1].
  std::vector<float> audio_f32(n_samples);
  constexpr float kScale = 1.0f / 32768.0f;
  for (size_t i = 0; i < n_samples; ++i)
    audio_f32[i] = static_cast<float>(pcm_data[i]) * kScale;

  // Input tensor: [1, 1, n_samples].
  std::vector<int64_t> audio_shape = {1, 1, static_cast<int64_t>(n_samples)};
  Ort::Value audio_val = Ort::Value::CreateTensor<float>(
      impl_->allocator, audio_shape.data(), audio_shape.size());
  std::memcpy(audio_val.GetTensorMutableData<float>(),
              audio_f32.data(), n_samples * sizeof(float));

  std::vector<Ort::Value> enc_inputs;
  enc_inputs.push_back(std::move(audio_val));

  std::vector<Ort::Value> enc_out;
  try {
    enc_out = impl_->mimi_encoder->Run(
        Ort::RunOptions{nullptr},
        impl_->enc_in_names.data(),  enc_inputs.data(), enc_inputs.size(),
        impl_->enc_out_names.data(), impl_->enc_out_names.size());
  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[PocketTTS] mimi_encoder run error: %s\n", e.what());
    return false;
  }

  if (enc_out.empty()) return false;
  auto shape = enc_out[0].GetTensorTypeAndShapeInfo().GetShape();
  if (shape.size() < 2) {
    fprintf(stderr, "[PocketTTS] Unexpected encoder output rank %zu\n",
            shape.size());
    return false;
  }
  int64_t n_frames = shape[shape.size() - 2];  // [1, n_frames, 1024]
  size_t n_elems = enc_out[0].GetTensorTypeAndShapeInfo().GetElementCount();

  std::vector<float> emb(n_elems);
  std::memcpy(emb.data(),
              enc_out[0].GetTensorMutableData<float>(),
              n_elems * sizeof(float));

  {
    std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
    impl_->cloned_voices[voice_id] = {n_frames, std::move(emb)};
  }
  fprintf(stderr, "[PocketTTS] Voice encoded: '%s' → %lld frames × %lld dims\n",
          voice_id.c_str(), (long long)n_frames, (long long)Impl::kVoiceDim);
  return true;
#endif
}

std::vector<uint8_t> PocketTtsOnnxEngine::export_voice_embedding(
    const std::string& voice_id) {
#ifndef HAS_ONNXRUNTIME
  return {};
#else
  std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
  auto it = impl_->cloned_voices.find(voice_id);
  if (it == impl_->cloned_voices.end()) return {};

  int64_t n_frames = it->second.first;
  const auto& data = it->second.second;

  // Binary format: int32 n_frames | int32 n_dims | float32[] data
  int32_t hdr[2] = {static_cast<int32_t>(n_frames),
                    static_cast<int32_t>(Impl::kVoiceDim)};
  std::vector<uint8_t> out(8 + data.size() * sizeof(float));
  std::memcpy(out.data(),     hdr,        8);
  std::memcpy(out.data() + 8, data.data(), data.size() * sizeof(float));
  return out;
#endif
}

bool PocketTtsOnnxEngine::import_voice_embedding(const std::string& voice_id,
                                                   const uint8_t* data,
                                                   size_t size) {
#ifndef HAS_ONNXRUNTIME
  return false;
#else
  if (!impl_->initialized || voice_id.empty() || !data || size < 8) return false;

  int32_t hdr[2];
  std::memcpy(hdr, data, 8);
  int64_t n_frames = static_cast<int64_t>(hdr[0]);
  int64_t n_dims   = static_cast<int64_t>(hdr[1]);

  if (n_dims != Impl::kVoiceDim || n_frames <= 0) {
    fprintf(stderr, "[PocketTTS] import_voice_embedding: bad header "
            "(frames=%lld dims=%lld)\n", (long long)n_frames, (long long)n_dims);
    return false;
  }

  size_t expected = 8 + static_cast<size_t>(n_frames) *
                    static_cast<size_t>(n_dims) * sizeof(float);
  if (size < expected) {
    fprintf(stderr, "[PocketTTS] import_voice_embedding: data too short "
            "(%zu < %zu)\n", size, expected);
    return false;
  }

  std::vector<float> emb(static_cast<size_t>(n_frames * n_dims));
  std::memcpy(emb.data(), data + 8, emb.size() * sizeof(float));

  {
    std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
    impl_->cloned_voices[voice_id] = {n_frames, std::move(emb)};
  }
  fprintf(stderr, "[PocketTTS] Voice imported: '%s' (%lld frames)\n",
          voice_id.c_str(), (long long)n_frames);
  return true;
#endif
}

// ── Warmup ───────────────────────────────────────────────────────────────────

void PocketTtsOnnxEngine::warmup() {
  if (!impl_->initialized) return;
  fprintf(stderr, "[PocketTTS] Warmup: running discard synthesis...\n");
  auto start = std::chrono::steady_clock::now();
  auto discard = synthesize(".", "");
  double ms = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - start).count();
  fprintf(stderr, "[PocketTTS] Warmup complete: %.0fms, %zu samples\n",
          ms, discard.size());
}

// ── Synthesize ───────────────────────────────────────────────────────────────

// Core synthesis pipeline. on_chunk is called with decoded PCM16 as each
// mimi_decoder chunk completes — Phase 2 streaming delivery.
void PocketTtsOnnxEngine::synthesize_impl(
    const std::string& text_in,
    const std::string& voice_name,
    std::function<void(std::vector<int16_t>)> on_chunk) {
  if (!impl_->initialized || text_in.empty() || !on_chunk) return;

#if !defined(HAS_ONNXRUNTIME) || !defined(HAS_SENTENCEPIECE)
  fprintf(stderr, "[PocketTTS] Compiled without required deps\n");
  return;
#else
  auto total_start = std::chrono::steady_clock::now();
  auto t0 = total_start;

  // ── 1. Prepare text ───────────────────────────────────────────────────────
  std::string text = Impl::prepare_text(text_in);

  // ── 2. Tokenize ───────────────────────────────────────────────────────────
  std::vector<int> sp_ids = impl_->sp.EncodeAsIds(text);
  if (sp_ids.empty()) {
    fprintf(stderr, "[PocketTTS] Tokenization returned empty for: %s\n",
            text.c_str());
    return;
  }
  std::vector<int64_t> token_ids(sp_ids.begin(), sp_ids.end());

  // ── 3+4+5a. text_conditioner and voice conditioning run in parallel ─────────
  // The two sessions are independent so concurrent inference is safe.
  // text_conditioner result is needed only for step 5b, so it can overlap
  // entirely with the voice conditioning pass on flow_lm_main.
  std::vector<Ort::Value> text_emb_val;
  std::vector<Ort::Value> main_states;
  std::string text_cond_error;

  {
    std::thread text_thread([&]() {
      try {
        std::vector<int64_t> tok_shape = {1, static_cast<int64_t>(token_ids.size())};
        Ort::Value tok_tensor = Ort::Value::CreateTensor<int64_t>(
            impl_->allocator, tok_shape.data(), tok_shape.size());
        std::memcpy(tok_tensor.GetTensorMutableData<int64_t>(),
                    token_ids.data(), token_ids.size() * sizeof(int64_t));
        std::vector<Ort::Value> tc_inputs;
        tc_inputs.push_back(std::move(tok_tensor));
        text_emb_val = impl_->text_conditioner->Run(
            Ort::RunOptions{nullptr},
            impl_->tc_in_names.data(),  tc_inputs.data(), tc_inputs.size(),
            impl_->tc_out_names.data(), impl_->tc_out_names.size());
      } catch (const Ort::Exception& e) {
        text_cond_error = e.what();
      }
    });

    main_states = impl_->init_states(*impl_->flow_lm_main);

    // Resolve voice embedding: cloned voice > default voice.
    // Copy under lock so the synthesis thread has a stable snapshot.
    std::vector<float> voice_data_copy;
    int64_t voice_frames = 0;
    {
      std::lock_guard<std::mutex> lock(impl_->cloned_voices_mutex);
      if (!voice_name.empty() && voice_name != "default") {
        auto it = impl_->cloned_voices.find(voice_name);
        if (it != impl_->cloned_voices.end()) {
          voice_frames   = it->second.first;
          voice_data_copy = it->second.second;
        }
      }
      if (voice_data_copy.empty() && !impl_->default_voice_data.empty()) {
        voice_frames   = impl_->default_voice_frames;
        voice_data_copy = impl_->default_voice_data;
      }
    }

    if (!voice_data_copy.empty()) {
      try {
        std::vector<Ort::Value> ns_inputs;
        ns_inputs.push_back(
            impl_->make_zero_tensor(impl_->allocator, {1, 0, 32},
                                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT));
        std::vector<int64_t> v_shape = {1, voice_frames, Impl::kVoiceDim};
        ns_inputs.push_back(
            impl_->make_float_tensor_from(v_shape, voice_data_copy.data()));
        impl_->run_stateful(*impl_->flow_lm_main,
                            impl_->lm_in_names, impl_->lm_out_names,
                            ns_inputs, main_states, 2);
      } catch (const Ort::Exception& e) {
        text_thread.join();
        fprintf(stderr, "[PocketTTS] voice conditioning error: %s\n", e.what());
        return;
      }
    } else {
      fprintf(stderr, "[PocketTTS] No voice embeddings — skipping voice conditioning\n");
    }

    text_thread.join();
  }

  if (!text_cond_error.empty()) {
    fprintf(stderr, "[PocketTTS] text_conditioner error: %s\n", text_cond_error.c_str());
    return;
  }

  // ── 5b. Text conditioning pass ────────────────────────────────────────────
  try {
    std::vector<Ort::Value> ns_inputs;
    ns_inputs.push_back(
        impl_->make_zero_tensor(impl_->allocator, {1, 0, 32},
                                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT));
    ns_inputs.push_back(std::move(text_emb_val[0]));
    impl_->run_stateful(*impl_->flow_lm_main,
                        impl_->lm_in_names, impl_->lm_out_names,
                        ns_inputs, main_states, 2);
  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[PocketTTS] text conditioning error: %s\n", e.what());
    return;
  }

  double cond_ms = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - t0).count();
  (void)t0;

  // ── 6+7. Autoregressive generation with interleaved mimi_decoder ──────────
  // Phase 2: decode every kMimiChunkSize latent frames so first audio arrives
  // after only the first chunk completes rather than after the full loop.
  // Mimi decoder state persists across chunk boundaries for audio continuity.

  std::vector<float> curr(32);
  std::fill(curr.begin(), curr.end(),
            std::numeric_limits<float>::quiet_NaN());
  const float dt = 1.0f / kLsdSteps;

  std::vector<Ort::Value> mimi_states =
      impl_->init_states(*impl_->mimi_decoder);

  std::vector<std::vector<float>> pending_latents;
  pending_latents.reserve(kMimiChunkSize);

  // Accumulate decoded float PCM across all chunks for batch normalization.
  // Normalizing per-chunk causes audible pumping / amplified noise floor on
  // quiet frames (e.g. the short EOS tail). Batch normalization over the full
  // utterance matches Phase 1 quality while still interleaving decode with
  // generation (avoiding the need to buffer all latents before decoding).
  std::vector<float> all_pcm_float;
  all_pcm_float.reserve(200 * 1920);

  size_t total_latents  = 0;
  int    eos_step       = -1;
  bool   first_audio    = true;  // used to log time-to-first-audio once

  // Decode pending_latents and append raw float samples to all_pcm_float.
  auto flush_pending = [&]() -> bool {
    if (pending_latents.empty()) return true;

    size_t chunk_size = pending_latents.size();
    std::vector<int64_t> lat_shape = {1, static_cast<int64_t>(chunk_size), 32};
    Ort::Value lat_val = Ort::Value::CreateTensor<float>(
        impl_->allocator, lat_shape.data(), lat_shape.size());
    float* lat_buf = lat_val.GetTensorMutableData<float>();
    for (size_t j = 0; j < chunk_size; ++j)
      std::memcpy(lat_buf + j * 32, pending_latents[j].data(), 32 * sizeof(float));
    pending_latents.clear();

    try {
      std::vector<Ort::Value> ns_inputs;
      ns_inputs.push_back(std::move(lat_val));
      auto mi_out = impl_->run_stateful(*impl_->mimi_decoder,
                                        impl_->mi_in_names, impl_->mi_out_names,
                                        ns_inputs, mimi_states, 1);
      size_t n_samples = mi_out[0].GetTensorTypeAndShapeInfo().GetElementCount();
      if (n_samples == 0) return true;
      if (first_audio) {
        double ttfa_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - total_start).count();
        fprintf(stderr, "[PocketTTS] Time to first audio: %.0fms\n", ttfa_ms);
        first_audio = false;
      }
      const float* audio_ptr = mi_out[0].GetTensorMutableData<float>();
      all_pcm_float.insert(all_pcm_float.end(), audio_ptr, audio_ptr + n_samples);
    } catch (const Ort::Exception& e) {
      fprintf(stderr, "[PocketTTS] mimi_decoder error: %s\n", e.what());
      return false;
    }
    return true;
  };

  for (int step = 0; step < kMaxFrames; ++step) {
    std::vector<Ort::Value> lm_out;
    try {
      std::vector<Ort::Value> ns_inputs;
      ns_inputs.push_back(
          impl_->make_float_tensor_from({1, 1, 32}, curr.data()));
      ns_inputs.push_back(
          impl_->make_zero_tensor(impl_->allocator, {1, 0, 1024},
                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT));
      lm_out = impl_->run_stateful(*impl_->flow_lm_main,
                                    impl_->lm_in_names, impl_->lm_out_names,
                                    ns_inputs, main_states, 2);
    } catch (const Ort::Exception& e) {
      fprintf(stderr, "[PocketTTS] flow_lm_main step %d error: %s\n",
              step, e.what());
      break;
    }

    const float* cond_ptr = lm_out[0].GetTensorMutableData<float>();
    const float  eos_val  = *lm_out[1].GetTensorMutableData<float>();

    if (eos_val > kEosThreshold && eos_step == -1) eos_step = step;
    bool at_eos = (eos_step != -1 && step >= eos_step + kFramesAfterEos);

    // Flow matching: Euler integration, seeded per-step for reproducibility.
    std::mt19937 x_rng(static_cast<uint32_t>(step) * 2654435761u);
    std::normal_distribution<float> x_dist(0.0f, 0.8366f);  // sqrt(0.7)
    std::vector<float> x(32);
    for (float& v : x) v = x_dist(x_rng);

    bool flow_ok = true;
    for (int j = 0; j < kLsdSteps && flow_ok; ++j) {
      float s_val = static_cast<float>(j) / kLsdSteps;
      float t_val = s_val + dt;
      try {
        std::vector<Ort::Value> fl_inputs;
        fl_inputs.push_back(impl_->make_float_tensor_from({1, 1024}, cond_ptr));
        fl_inputs.push_back(impl_->make_float_tensor({1, 1}, s_val));
        fl_inputs.push_back(impl_->make_float_tensor({1, 1}, t_val));
        fl_inputs.push_back(impl_->make_float_tensor_from({1, 32}, x.data()));
        auto fl_out = impl_->flow_lm_flow->Run(
            Ort::RunOptions{nullptr},
            impl_->fl_in_names.data(),  fl_inputs.data(), fl_inputs.size(),
            impl_->fl_out_names.data(), impl_->fl_out_names.size());
        const float* dir = fl_out[0].GetTensorMutableData<float>();
        for (int k = 0; k < 32; ++k) x[k] += dir[k] * dt;
      } catch (const Ort::Exception& e) {
        fprintf(stderr, "[PocketTTS] flow_lm_flow step %d/%d error: %s\n",
                step, j, e.what());
        flow_ok = false;
      }
    }
    if (!flow_ok) break;

    pending_latents.push_back(x);
    total_latents++;
    curr = x;

    if (pending_latents.size() == static_cast<size_t>(kMimiChunkSize) || at_eos) {
      if (!flush_pending()) break;
    }
    if (at_eos) break;
  }

  flush_pending();  // drain any remaining latents

  double total_ms = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - total_start).count();
  fprintf(stderr,
          "[PocketTTS] Synthesis done: %.0fms total (cond=%.0fms) | %zu latent frames\n",
          total_ms, cond_ms, total_latents);

  if (all_pcm_float.empty()) return;

  // High-frequency emphasis (see kHfEmphasisAlpha).
  if (kHfEmphasisAlpha > 0.0f) {
    float prev = 0.0f;
    for (float& s : all_pcm_float) {
      float orig = s;
      s = s + kHfEmphasisAlpha * (s - prev);
      prev = orig;
    }
  }

  // Amplitude gain. peak is needed by both branches for the clip cap.
  {
    float peak = 0.0f;
    for (float s : all_pcm_float)
      if (std::abs(s) > peak) peak = std::abs(s);

    float gain = impl_->gain_override;

    if (gain < 0.0f) {
      // Dynamic: target RMS 0.15 (-16 dBFS) over the full utterance.
      double sum_sq = 0.0;
      for (float s : all_pcm_float) sum_sq += static_cast<double>(s) * s;
      float rms = static_cast<float>(std::sqrt(sum_sq / all_pcm_float.size()));
      if (rms > 1e-7f) {
        constexpr float kTargetRms = 0.15f;
        gain = kTargetRms / rms;
      } else {
        gain = 1.0f;
      }
    }

    if (gain > 0.0f) {
      if (peak * gain > 0.95f) gain = 0.95f / peak;
      for (float& s : all_pcm_float) s *= gain;
      fprintf(stderr, "[PocketTTS] Amplitude: peak=%.5f gain=%.1fx\n", peak, gain);
    }
  }

  // Deliver normalized PCM in chunks so the EventChannel receives multiple
  // events rather than one large burst.
  constexpr size_t kDeliveryChunk = 4800;  // ~200ms at 24 kHz
  for (size_t off = 0; off < all_pcm_float.size(); off += kDeliveryChunk) {
    size_t n = std::min(kDeliveryChunk, all_pcm_float.size() - off);
    on_chunk(Impl::float_to_pcm16(all_pcm_float.data() + off, n));
  }
#endif
}

std::vector<int16_t> PocketTtsOnnxEngine::synthesize(
    const std::string& text_in,
    const std::string& voice_name) {
  std::vector<int16_t> accumulated;
  synthesize_impl(text_in, voice_name, [&](std::vector<int16_t> chunk) {
    accumulated.insert(accumulated.end(), chunk.begin(), chunk.end());
  });
  return accumulated;
}

void PocketTtsOnnxEngine::synthesize_streaming(
    const std::string& text_in,
    const std::string& voice_name,
    std::function<void(std::vector<int16_t>)> on_chunk) {
  synthesize_impl(text_in, voice_name, std::move(on_chunk));
}

}  // namespace pocket_tts
