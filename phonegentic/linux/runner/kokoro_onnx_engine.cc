// Copyright 2025 Phonegentic Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license found in the LICENSE file.

#include "kokoro_onnx_engine.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// ── Conditional compilation guards ──────────────────────────────────────────
// HAS_ONNXRUNTIME and HAS_ESPEAK_NG are defined by CMake when the
// corresponding libraries are found.  Without them the engine compiles but
// every operation returns a safe default (false / empty), matching the
// macOS #if canImport(KokoroSwift) graceful-degradation pattern.

#ifdef HAS_ONNXRUNTIME
#include <onnxruntime_cxx_api.h>
#endif

#include <dlfcn.h>
#include <sys/stat.h>

namespace kokoro {

// ── Phoneme → token ID vocabulary ───────────────────────────────────────────
// Extracted from hexgrad/Kokoro-82M config.json on HuggingFace.
// The model's forward() wraps token sequences with 0 at both ends:
//   input_ids = [0, *mapped_tokens, 0]
// Token 0 is the padding/BOS/EOS symbol.
//
// Source: https://huggingface.co/hexgrad/Kokoro-82M/blob/main/config.json
// Key:   UTF-8 encoded IPA phoneme (single Unicode codepoint)
// Value: integer token ID used by the ONNX model

static const std::unordered_map<std::string, int64_t> kVocab = {
    // ── Punctuation / special ──
    {";", 1},
    {":", 2},
    {",", 3},
    {".", 4},
    {"!", 5},
    {"?", 6},
    {"\u2014", 9},   // — em dash
    {"\u2026", 10},  // … ellipsis
    {"\"", 11},
    {"(", 12},
    {")", 13},
    {"\u201c", 14},  // " left double quotation mark
    {"\u201d", 15},  // " right double quotation mark
    {" ", 16},        // space (word boundary)

    // ── Combining marks ──
    {"\u0303", 17},  // ̃  combining tilde

    // ── IPA affricate ligatures ──
    {"\u02a3", 18},  // ʣ
    {"\u02a5", 19},  // ʥ
    {"\u02a6", 20},  // ʦ
    {"\u02a8", 21},  // ʨ

    // ── Modifier letters ──
    {"\u1d5d", 22},  // ᵝ
    {"\uab67", 23},  // ꭧ

    // ── Misaki diphthong shorthand (uppercase) ──
    {"A", 24},
    {"I", 25},
    {"O", 31},
    {"Q", 33},
    {"S", 35},
    {"T", 36},
    {"W", 39},
    {"Y", 41},
    {"\u1d4a", 42},  // ᵊ

    // ── ASCII letters (IPA baseline) ──
    {"a", 43},
    {"b", 44},
    {"c", 45},
    {"d", 46},
    {"e", 47},
    {"f", 48},
    {"h", 50},
    {"i", 51},
    {"j", 52},
    {"k", 53},
    {"l", 54},
    {"m", 55},
    {"n", 56},
    {"o", 57},
    {"p", 58},
    {"q", 59},
    {"r", 60},
    {"s", 61},
    {"t", 62},
    {"u", 63},
    {"v", 64},
    {"w", 65},
    {"x", 66},
    {"y", 67},
    {"z", 68},

    // ── IPA vowels ──
    {"\u0251", 69},  // ɑ
    {"\u0250", 70},  // ɐ
    {"\u0252", 71},  // ɒ
    {"\u00e6", 72},  // æ
    {"\u03b2", 75},  // β
    {"\u0254", 76},  // ɔ
    {"\u0255", 77},  // ɕ
    {"\u00e7", 78},  // ç
    {"\u0256", 80},  // ɖ
    {"\u00f0", 81},  // ð
    {"\u02a4", 82},  // ʤ
    {"\u0259", 83},  // ə
    {"\u025a", 85},  // ɚ
    {"\u025b", 86},  // ɛ
    {"\u025c", 87},  // ɜ
    {"\u025f", 90},  // ɟ
    {"\u0261", 92},  // ɡ
    {"\u0265", 99},  // ɥ
    {"\u0268", 101}, // ɨ
    {"\u026a", 102}, // ɪ
    {"\u029d", 103}, // ʝ
    {"\u026f", 110}, // ɯ
    {"\u0270", 111}, // ɰ
    {"\u014b", 112}, // ŋ
    {"\u0273", 113}, // ɳ
    {"\u0272", 114}, // ɲ
    {"\u0274", 115}, // ɴ
    {"\u00f8", 116}, // ø
    {"\u0278", 118}, // ɸ
    {"\u03b8", 119}, // θ
    {"\u0153", 120}, // œ
    {"\u0279", 123}, // ɹ
    {"\u027e", 125}, // ɾ
    {"\u027b", 126}, // ɻ
    {"\u0281", 128}, // ʁ
    {"\u027d", 129}, // ɽ
    {"\u0282", 130}, // ʂ
    {"\u0283", 131}, // ʃ
    {"\u0288", 132}, // ʈ
    {"\u02a7", 133}, // ʧ
    {"\u028a", 135}, // ʊ
    {"\u028b", 136}, // ʋ
    {"\u028c", 138}, // ʌ
    {"\u0263", 139}, // ɣ
    {"\u0264", 140}, // ɤ
    {"\u03c7", 142}, // χ
    {"\u028e", 143}, // ʎ
    {"\u0292", 147}, // ʒ
    {"\u0294", 148}, // ʔ

    // ── Stress / length markers ──
    {"\u02c8", 156}, // ˈ primary stress
    {"\u02cc", 157}, // ˌ secondary stress
    {"\u02d0", 158}, // ː long

    // ── Superscript modifiers ──
    {"\u02b0", 162}, // ʰ
    {"\u02b2", 164}, // ʲ

    // ── Intonation arrows ──
    {"\u2193", 169}, // ↓
    {"\u2192", 171}, // →
    {"\u2197", 172}, // ↗
    {"\u2198", 173}, // ↘

    // ── Near-close near-front unrounded ──
    {"\u1d7b", 177}, // ᵻ
};

// ── espeak-ng function pointer types (dynamic loading) ──────────────────────

typedef int (*EspeakInitializeFn)(int output_mode, int buflength,
                                  const char* path, int options);
typedef int (*EspeakSetVoiceByNameFn)(const char* name);
typedef const char* (*EspeakTextToPhonemesFn)(const void** text_ptr,
                                              int textmode, int phonememode);
typedef void (*EspeakTerminateFn)(void);

// ── PIMPL implementation struct ─────────────────────────────────────────────

struct KokoroOnnxEngine::Impl {
  bool initialized = false;

  // ── ONNX Runtime (guarded by HAS_ONNXRUNTIME) ──
#ifdef HAS_ONNXRUNTIME
  Ort::Env ort_env{nullptr};
  Ort::SessionOptions session_opts;
  std::unique_ptr<Ort::Session> session;
  Ort::AllocatorWithDefaultOptions allocator;
#endif

  // ── espeak-ng (dynamic) ──
  void* espeak_dl_handle = nullptr;
  EspeakInitializeFn espeak_Initialize = nullptr;
  EspeakSetVoiceByNameFn espeak_SetVoiceByName = nullptr;
  EspeakTextToPhonemesFn espeak_TextToPhonemes = nullptr;
  EspeakTerminateFn espeak_Terminate = nullptr;
  bool espeak_initialized = false;

  // ── Voice embeddings ──
  std::unordered_map<std::string, VoiceEmbedding> voices;
  std::string current_voice;

  // ── Thread safety ──
  // espeak-ng uses global state, so we serialize calls to phonemize().
  std::mutex espeak_mutex;

  // ── Helpers ──
  bool load_voices(const std::string& voices_dir);
  bool load_espeak();
  std::string phonemize(const std::string& text);
  std::vector<int64_t> tokenize_phonemes(const std::string& ipa);
  static std::vector<int16_t> float_to_pcm16(const float* data, size_t count);
  static bool parse_numpy_voice(const std::string& filepath,
                                VoiceEmbedding* out);
};

// ── Constructor / Destructor ────────────────────────────────────────────────

KokoroOnnxEngine::KokoroOnnxEngine() : impl_(new Impl()) {}

KokoroOnnxEngine::~KokoroOnnxEngine() {
  if (impl_->initialized) {
    dispose();
  }
}

// ── Static helpers ──────────────────────────────────────────────────────────

// static
bool KokoroOnnxEngine::is_model_available(const std::string& model_path) {
  struct stat st;
  return stat(model_path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// ── Initialize ──────────────────────────────────────────────────────────────

bool KokoroOnnxEngine::initialize(const std::string& model_path,
                                   const std::string& voices_dir) {
  if (impl_->initialized) {
    fprintf(stderr, "[KokoroOnnx] Already initialized\n");
    return true;
  }

  // 1. Load ONNX model
#ifdef HAS_ONNXRUNTIME
  if (!is_model_available(model_path)) {
    fprintf(stderr, "[KokoroOnnx] Model file not found: %s\n",
            model_path.c_str());
    return false;
  }

  try {
    impl_->ort_env = Ort::Env(ORT_LOGGING_LEVEL_WARNING, "KokoroOnnx");
    // Allow ORT to use multiple threads for intra-op parallelism (e.g. matrix
    // multiplications inside the Kokoro attention/vocoder layers).  The default
    // of 1 serialises all work onto a single CPU core, adding 500-900 ms to
    // every synthesis call on a mid-range machine.  Setting to 0 lets ORT pick
    // the optimal thread count automatically (typically hardware_concurrency).
    impl_->session_opts.SetIntraOpNumThreads(0);
    impl_->session_opts.SetGraphOptimizationLevel(
        GraphOptimizationLevel::ORT_ENABLE_ALL);

    impl_->session.reset(
        new Ort::Session(impl_->ort_env, model_path.c_str(),
                         impl_->session_opts));

    fprintf(stderr, "[KokoroOnnx] ONNX session created from %s\n",
            model_path.c_str());

    // Log model I/O for debugging
    size_t num_inputs = impl_->session->GetInputCount();
    size_t num_outputs = impl_->session->GetOutputCount();
    fprintf(stderr, "[KokoroOnnx] Model inputs: %zu, outputs: %zu\n",
            num_inputs, num_outputs);

    for (size_t i = 0; i < num_inputs; ++i) {
      auto name = impl_->session->GetInputNameAllocated(i, impl_->allocator);
      fprintf(stderr, "[KokoroOnnx]   Input %zu: %s\n", i, name.get());
    }
    for (size_t i = 0; i < num_outputs; ++i) {
      auto name = impl_->session->GetOutputNameAllocated(i, impl_->allocator);
      fprintf(stderr, "[KokoroOnnx]   Output %zu: %s\n", i, name.get());
    }
  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[KokoroOnnx] ONNX Runtime error: %s\n", e.what());
    return false;
  }
#else
  (void)model_path;
  (void)voices_dir;
  fprintf(stderr,
          "[KokoroOnnx] Compiled without HAS_ONNXRUNTIME — skipping model "
          "load\n");
  return false;
#endif

  // 2. Load espeak-ng
  if (!impl_->load_espeak()) {
    fprintf(stderr,
            "[KokoroOnnx] Warning: espeak-ng not available, phonemization "
            "will fail\n");
    // Continue — the engine is "initialized" but synthesize will fail
    // gracefully if espeak is needed.
  }

  // 3. Load voice embeddings
  if (!impl_->load_voices(voices_dir)) {
    fprintf(stderr,
            "[KokoroOnnx] Warning: no voice embeddings loaded from %s\n",
            voices_dir.c_str());
  }

  impl_->initialized = true;
  fprintf(stderr, "[KokoroOnnx] Initialization complete (%zu voices)\n",
          impl_->voices.size());
  return true;
}

bool KokoroOnnxEngine::is_initialized() const {
  return impl_->initialized;
}

// ── Set voice ───────────────────────────────────────────────────────────────

bool KokoroOnnxEngine::set_voice(const std::string& voice_name) {
  auto it = impl_->voices.find(voice_name);
  if (it == impl_->voices.end()) {
    fprintf(stderr, "[KokoroOnnx] Voice '%s' not found\n", voice_name.c_str());
    return false;
  }
  impl_->current_voice = voice_name;
  fprintf(stderr, "[KokoroOnnx] Voice set to '%s'\n", voice_name.c_str());
  return true;
}

// ── Synthesize ──────────────────────────────────────────────────────────────

std::vector<int16_t> KokoroOnnxEngine::synthesize(
    const std::string& text,
    const std::string& voice_name) {
  if (!impl_->initialized) {
    fprintf(stderr, "[KokoroOnnx] synthesize called before initialize\n");
    return {};
  }

  if (text.empty()) {
    return {};
  }

  // 1. Resolve voice embedding
  std::string voice_key = voice_name.empty() ? impl_->current_voice : voice_name;
  auto voice_it = impl_->voices.find(voice_key);
  if (voice_it == impl_->voices.end()) {
    fprintf(stderr, "[KokoroOnnx] Voice '%s' not loaded\n", voice_key.c_str());
    return {};
  }
  const VoiceEmbedding& voice = voice_it->second;

  // 2. Phonemize: text → IPA string
  std::string ipa = impl_->phonemize(text);
  if (ipa.empty()) {
    fprintf(stderr, "[KokoroOnnx] Phonemization returned empty for: %s\n",
            text.c_str());
    return {};
  }
  // fprintf(stderr, "[KokoroOnnx] IPA: %s\n", ipa.c_str());

  // 3. Tokenize: IPA string → token IDs
  std::vector<int64_t> tokens = impl_->tokenize_phonemes(ipa);
  if (tokens.empty()) {
    fprintf(stderr, "[KokoroOnnx] Tokenization returned empty\n");
    return {};
  }

  // Wrap with padding token 0 at both ends, matching the Python model:
  //   input_ids = [0, *tokens, 0]
  tokens.insert(tokens.begin(), 0);
  tokens.push_back(0);

  // 4. Select style row from voice pack
  //    The Python model does: pack[len(ps) - 1]
  //    where ps is the raw phoneme string (before tokenization).
  //    The voice pack has N rows of 256 floats.
  //    NOTE: len(ps) in Python counts Unicode codepoints, NOT bytes.
  size_t phoneme_count = 0;
  {
    // Count UTF-8 codepoints (matching Python's len() on a str)
    size_t ci = 0;
    while (ci < ipa.size()) {
      uint8_t c = static_cast<uint8_t>(ipa[ci]);
      if (c >= 0xF0) ci += 4;
      else if (c >= 0xE0) ci += 3;
      else if (c >= 0xC0) ci += 2;
      else ci += 1;
      ++phoneme_count;
    }
  }
  size_t pack_rows = voice.data.size() / 256;
  if (pack_rows == 0) {
    fprintf(stderr, "[KokoroOnnx] Voice '%s' has no style data\n",
            voice_key.c_str());
    return {};
  }
  size_t style_row = (phoneme_count < pack_rows) ? phoneme_count
                                                   : (pack_rows - 1);
  if (style_row > 0) {
    --style_row;  // pack[len(ps) - 1]
  }

  // 5. Run ONNX inference
#ifdef HAS_ONNXRUNTIME
  std::vector<float> audio_float;
  try {
    // Input 0: tokens [1, N] int64
    std::vector<int64_t> input_dims_tokens = {
        1, static_cast<int64_t>(tokens.size())};
    Ort::Value input_tokens = Ort::Value::CreateTensor<int64_t>(
        impl_->allocator, input_dims_tokens.data(), input_dims_tokens.size());
    int64_t* tokens_buf = input_tokens.GetTensorMutableData<int64_t>();
    std::memcpy(tokens_buf, tokens.data(), tokens.size() * sizeof(int64_t));

    // Input 1: style [1, 256] float32
    const float* style_src = voice.data.data() + style_row * 256;
    std::vector<int64_t> input_dims_style = {1, 256};
    Ort::Value input_style = Ort::Value::CreateTensor<float>(
        impl_->allocator, input_dims_style.data(), input_dims_style.size());
    float* style_buf = input_style.GetTensorMutableData<float>();
    std::memcpy(style_buf, style_src, 256 * sizeof(float));

    // Input 2: speed scalar double (shape=[], type=tensor(double))
    // The ONNX model expects a 0-dimensional double scalar, not a float[1].
    double speed_val = 1.0;
    std::vector<int64_t> input_dims_speed = {};  // scalar = empty dims
    Ort::Value input_speed = Ort::Value::CreateTensor<double>(
        impl_->allocator, input_dims_speed.data(), input_dims_speed.size());
    double* speed_buf = input_speed.GetTensorMutableData<double>();
    *speed_buf = speed_val;

    // Resolve input names from the model
    std::vector<const char*> input_names;
    std::vector<Ort::AllocatedStringPtr> input_name_ptrs;
    size_t num_inputs = impl_->session->GetInputCount();
    input_names.reserve(num_inputs);
    for (size_t i = 0; i < num_inputs; ++i) {
      input_name_ptrs.push_back(
          impl_->session->GetInputNameAllocated(i, impl_->allocator));
      input_names.push_back(input_name_ptrs.back().get());
    }

    // Resolve output names from the model
    std::vector<const char*> output_names;
    std::vector<Ort::AllocatedStringPtr> output_name_ptrs;
    size_t num_outputs = impl_->session->GetOutputCount();
    output_names.reserve(num_outputs);
    for (size_t i = 0; i < num_outputs; ++i) {
      output_name_ptrs.push_back(
          impl_->session->GetOutputNameAllocated(i, impl_->allocator));
      output_names.push_back(output_name_ptrs.back().get());
    }

    // Run inference
    std::vector<Ort::Value> inputs;
    inputs.push_back(std::move(input_tokens));
    inputs.push_back(std::move(input_style));
    inputs.push_back(std::move(input_speed));

    auto infer_start = std::chrono::steady_clock::now();
    auto outputs = impl_->session->Run(
        Ort::RunOptions{nullptr},
        input_names.data(), inputs.data(), inputs.size(),
        output_names.data(), output_names.size());
    double infer_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - infer_start).count();

    // Extract audio from first output
    if (outputs.empty()) {
      fprintf(stderr, "[KokoroOnnx] Model returned no outputs\n");
      return {};
    }

    auto& audio_tensor = outputs[0];
    auto type_info = audio_tensor.GetTensorTypeAndShapeInfo();
    size_t element_count = type_info.GetElementCount();
    float* audio_data = audio_tensor.GetTensorMutableData<float>();

    fprintf(stderr, "[KokoroOnnx] Audio output: %zu samples, inference duration %.0fms\n",
            element_count, infer_ms);

    audio_float.assign(audio_data, audio_data + element_count);

  } catch (const Ort::Exception& e) {
    fprintf(stderr, "[KokoroOnnx] ONNX inference error: %s\n", e.what());
    return {};
  }

  // 6. Convert float32 → PCM16
  return Impl::float_to_pcm16(audio_float.data(), audio_float.size());

#else
  (void)voice_key;
  fprintf(stderr,
          "[KokoroOnnx] Compiled without HAS_ONNXRUNTIME — cannot "
          "synthesize\n");
  return {};
#endif
}

// ── Warmup ──────────────────────────────────────────────────────────────────

void KokoroOnnxEngine::warmup(const std::string& voice_name) {
  if (!impl_->initialized) {
    fprintf(stderr, "[KokoroOnnx] warmup called before initialize\n");
    return;
  }

  fprintf(stderr, "[KokoroOnnx] Warmup: synthesizing discard...\n");
  auto start = std::chrono::steady_clock::now();

  // Synthesize a short text and discard the result
  std::vector<int16_t> discard = synthesize(".", voice_name);

  auto end = std::chrono::steady_clock::now();
  double elapsed =
      std::chrono::duration<double, std::milli>(end - start).count();
  fprintf(stderr,
          "[KokoroOnnx] Warmup complete: %.1f ms, %zu samples (discarded)\n",
          elapsed, discard.size());
}

// ── Dispose ─────────────────────────────────────────────────────────────────

void KokoroOnnxEngine::dispose() {
  if (!impl_->initialized) {
    return;
  }

#ifdef HAS_ONNXRUNTIME
  impl_->session.reset();
#endif

  if (impl_->espeak_initialized && impl_->espeak_Terminate) {
    impl_->espeak_Terminate();
    impl_->espeak_initialized = false;
  }

  if (impl_->espeak_dl_handle) {
    dlclose(impl_->espeak_dl_handle);
    impl_->espeak_dl_handle = nullptr;
  }

  impl_->voices.clear();
  impl_->current_voice.clear();
  impl_->initialized = false;

  fprintf(stderr, "[KokoroOnnx] Disposed\n");
}

// ── Impl: Load espeak-ng via dlopen ─────────────────────────────────────────

bool KokoroOnnxEngine::Impl::load_espeak() {
#ifdef HAS_ESPEAK_NG
  // Try common library names
  static const char* kLibNames[] = {
      "libespeak-ng.so.1",
      "libespeak-ng.so",
      "libespeak-ng.so.2",
      "libespeak.so.1",
      "libespeak.so",
  };

  for (const char* name : kLibNames) {
    espeak_dl_handle = dlopen(name, RTLD_LAZY);
    if (espeak_dl_handle) {
      fprintf(stderr, "[KokoroOnnx] Loaded espeak-ng: %s\n", name);
      break;
    }
  }

  if (!espeak_dl_handle) {
    fprintf(stderr, "[KokoroOnnx] Could not dlopen espeak-ng: %s\n",
            dlerror());
    return false;
  }

  // Resolve function pointers
#define RESOLVE(var, type, sym)                                  \
  do {                                                           \
    var = reinterpret_cast<type>(dlsym(espeak_dl_handle, sym));  \
    if (!var) {                                                  \
      fprintf(stderr, "[KokoroOnnx] dlsym %s failed: %s\n",     \
              sym, dlerror());                                   \
      dlclose(espeak_dl_handle);                                 \
      espeak_dl_handle = nullptr;                                \
      return false;                                              \
    }                                                            \
  } while (0)

  RESOLVE(espeak_Initialize, EspeakInitializeFn, "espeak_Initialize");
  RESOLVE(espeak_SetVoiceByName, EspeakSetVoiceByNameFn, "espeak_SetVoiceByName");
  RESOLVE(espeak_TextToPhonemes, EspeakTextToPhonemesFn, "espeak_TextToPhonemes");
  RESOLVE(espeak_Terminate, EspeakTerminateFn, "espeak_Terminate");
#undef RESOLVE

  // Initialize espeak-ng
  // AUDIO_OUTPUT_SYNCHRONOUS = 0x02
  int sample_rate =
      espeak_Initialize(0x02, 0, nullptr, 0);
  if (sample_rate <= 0) {
    fprintf(stderr, "[KokoroOnnx] espeak_Initialize failed (rate=%d)\n",
            sample_rate);
    return false;
  }

  int result = espeak_SetVoiceByName("en-us");
  if (result != 0) {
    fprintf(stderr, "[KokoroOnnx] espeak_SetVoiceByName(\"en-us\") failed: %d\n",
            result);
    return false;
  }

  espeak_initialized = true;
  fprintf(stderr,
          "[KokoroOnnx] espeak-ng initialized (sample_rate=%d)\n",
          sample_rate);
  return true;

#else
  fprintf(stderr,
          "[KokoroOnnx] Compiled without HAS_ESPEAK_NG — espeak-ng "
          "disabled\n");
  return false;
#endif
}

// ── Impl: String replacement helper ─────────────────────────────────────────

static void replace_all(std::string& s, const std::string& from,
                        const std::string& to) {
  if (from.empty()) return;
  size_t pos = 0;
  while ((pos = s.find(from, pos)) != std::string::npos) {
    s.replace(pos, from.size(), to);
    pos += to.size();
  }
}

// ── Impl: Remap espeak-ng IPA → Misaki phoneme format ───────────────────────
//
// espeak-ng IPA mode (phonememode=2) outputs standard IPA, but the Kokoro
// model was trained with Misaki's G2P which uses custom diphthong tokens
// and single-character affricates.  This function mirrors the remapping
// in misaki/espeak.py EspeakFallback (American English).
//
// Order matters: diphthongs/affricates must be replaced before single-char
// substitutions (e.g. "oʊ" → "O" before "o" → "ɔ").

static std::string remap_espeak_ipa(const std::string& ipa) {
  std::string result = ipa;

  // ── 1. Diphthongs (multi-vowel → single Misaki token) ──
  // Must come before single-char "o" → "ɔ" replacement.
  replace_all(result, "oʊ", "O");   // know, hello, go
  replace_all(result, "aɪ", "I");   // like, I, my
  replace_all(result, "aʊ", "W");   // brown, how, now
  replace_all(result, "eɪ", "A");   // say, day, they
  replace_all(result, "ɔɪ", "Y");   // boy, toy
  replace_all(result, "əʊ", "Q");   // British: go, no

  // ── 2. Affricates (two-char IPA → single Misaki char) ──
  replace_all(result, "dʒ", "ʤ");   // just, join, edge
  replace_all(result, "tʃ", "ʧ");   // church, each

  // ── 3. American English rhotic mappings ──
  // Must come before ɜː → ɜɹ to avoid double-ɹ.
  replace_all(result, "ɜːɹ", "ɜɹ"); // world (ɜ + length + ɹ)
  replace_all(result, "ɜː", "ɜɹ");  // bird, word
  replace_all(result, "ɚ", "əɹ");   // better, water

  // ── 4. Single-char substitutions ──
  replace_all(result, "o", "ɔ");    // espeak < 1.52: ASCII o → ɔ
  replace_all(result, "ɐ", "ə");    // schwa variant
  replace_all(result, "ɾ", "T");    // flapped T (American)
  replace_all(result, "ʔ", "t");    // glottal stop → t

  // ── 5. Remove length markers (American English) ──
  // Misaki removes ː for en-us after handling ɜː above.
  replace_all(result, "ː", "");

  // ── 6. Palatalization cleanup ──
  replace_all(result, "ʲo", "jo");
  replace_all(result, "ʲə", "jə");
  replace_all(result, "ʲ", "");     // remove standalone palatalization

  return result;
}

// ── Impl: Phonemize text via espeak-ng ──────────────────────────────────────

std::string KokoroOnnxEngine::Impl::phonemize(const std::string& text) {
  if (!espeak_initialized) {
    fprintf(stderr, "[KokoroOnnx] espeak-ng not initialized\n");
    return "";
  }

  std::lock_guard<std::mutex> lock(espeak_mutex);

  // espeak_TextToPhonemes is an iterative API: it processes one clause at a
  // time, advances text_ptr to the next clause, and returns NULL when done.
  // Punctuation like ':' is treated as a clause boundary, so we MUST loop
  // until NULL to capture all phonemes (a single call drops everything after
  // the first boundary).
  //
  // phonememode bit flags (espeak-ng 1.51):
  //   bit 0 (0x01): reserved / no effect
  //   bit 1 (0x02): IPA output (Unicode IPA characters)
  // textmode=0 → plain text input (not SSML)
  const void* text_ptr = text.c_str();
  std::string accumulated;

  while (text_ptr != nullptr) {
    const char* ipa = espeak_TextToPhonemes(&text_ptr, 0, 0x02);
    if (!ipa) break;

    std::string raw_ipa(ipa);
    if (raw_ipa.empty()) continue;

    std::string remapped = remap_espeak_ipa(raw_ipa);
    if (raw_ipa != remapped) {
      // fprintf(stderr, "[KokoroOnnx] IPA remap: '%s' → '%s'\n",
      //        raw_ipa.c_str(), remapped.c_str());
    }
    accumulated += remapped;
  }

  if (accumulated.empty()) {
    fprintf(stderr, "[KokoroOnnx] espeak_TextToPhonemes returned empty for: %s\n",
            text.c_str());
    return "";
  }

  return accumulated;
}

// ── Impl: Tokenize IPA phonemes → token IDs ─────────────────────────────────
//
// The Kokoro model maps each Unicode codepoint of the phoneme string
// individually via the VOCAB dictionary (see Python model.py forward()):
//
//   input_ids = list(filter(None, map(lambda p: vocab.get(p), phonemes)))
//
// Unknown codepoints are silently skipped.  The result is wrapped with
// token 0 at both ends by the caller (synthesize).

std::vector<int64_t> KokoroOnnxEngine::Impl::tokenize_phonemes(
    const std::string& ipa) {
  std::vector<int64_t> tokens;
  tokens.reserve(ipa.size());

  // Iterate over UTF-8 codepoints
  size_t i = 0;
  while (i < ipa.size()) {
    uint8_t c = static_cast<uint8_t>(ipa[i]);
    size_t char_len = 1;

    if (c >= 0xF0) {
      char_len = 4;
    } else if (c >= 0xE0) {
      char_len = 3;
    } else if (c >= 0xC0) {
      char_len = 2;
    }
    // else: ASCII (1 byte)

    if (i + char_len > ipa.size()) {
      fprintf(stderr,
              "[KokoroOnnx] Truncated UTF-8 at position %zu in IPA string\n",
              i);
      break;
    }

    std::string codepoint(ipa.substr(i, char_len));
    auto it = kVocab.find(codepoint);
    if (it != kVocab.end()) {
      tokens.push_back(it->second);
    } else {
      // Skip unknown phoneme (matching Python filter(None, ...))
      fprintf(stderr, "[KokoroOnnx] Unknown phoneme codepoint at pos %zu\n",
              i);
    }

    i += char_len;
  }

  return tokens;
}

// ── Impl: Float32 → PCM16 conversion ────────────────────────────────────────
//
// Matches macOS KokoroTtsChannel.floatArrayToPCM16:
//   int16 = clamp(sample, -1.0, 1.0) * 32767

std::vector<int16_t> KokoroOnnxEngine::Impl::float_to_pcm16(
    const float* data, size_t count) {
  std::vector<int16_t> pcm;
  pcm.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    float clamped = std::max(-1.0f, std::min(1.0f, data[i]));
    pcm.push_back(static_cast<int16_t>(clamped * 32767.0f));
  }
  return pcm;
}

// ── Impl: Load voice embeddings from directory ──────────────────────────────

bool KokoroOnnxEngine::Impl::load_voices(const std::string& voices_dir) {
  // Enumerate files in the voices directory using POSIX opendir/readdir.
  DIR* dir = opendir(voices_dir.c_str());
  if (!dir) {
    fprintf(stderr, "[KokoroOnnx] Cannot open voices directory: %s\n",
            voices_dir.c_str());
    return false;
  }

  struct dirent* entry;
  int loaded = 0;
  while ((entry = readdir(dir)) != nullptr) {
    std::string filename(entry->d_name);
    // Accept .bin and .npy extensions (HuggingFace uses .bin, some repos use .npy)
    if (filename.size() < 5) continue;

    bool is_voice_file = false;
    std::string voice_name;
    if (filename.size() > 4 &&
        filename.compare(filename.size() - 4, 4, ".bin") == 0) {
      is_voice_file = true;
      voice_name = filename.substr(0, filename.size() - 4);
    } else if (filename.size() > 4 &&
               filename.compare(filename.size() - 4, 4, ".npy") == 0) {
      is_voice_file = true;
      voice_name = filename.substr(0, filename.size() - 4);
    }

    if (!is_voice_file) continue;

    std::string filepath = voices_dir + "/" + filename;
    VoiceEmbedding embedding;
    embedding.name = voice_name;

    if (parse_numpy_voice(filepath, &embedding)) {
      voices[voice_name] = std::move(embedding);
      ++loaded;
      fprintf(stderr, "[KokoroOnnx] Loaded voice '%s' (%zu floats)\n",
              voice_name.c_str(), voices[voice_name].data.size());
    }
  }

  closedir(dir);
  fprintf(stderr, "[KokoroOnnx] Loaded %d voice(s) from %s\n", loaded,
          voices_dir.c_str());
  return loaded > 0;
}

// ── Impl: Parse NumPy .npy voice file ───────────────────────────────────────
//
// NumPy .npy v1.0 binary format:
//   Offset  Size  Description
//   0       6     Magic: \x93NUMPY
//   6       1     Major version (1)
//   7       1     Minor version (0)
//   8       2     Header length (uint16 LE)
//   10      HLEN  Header string (Python dict literal)
//   10+HLEN ...   Raw data (float32 array)
//
// The voice pack is N × 256 float32 values (N rows of 256-dim style vectors).

bool KokoroOnnxEngine::Impl::parse_numpy_voice(const std::string& filepath,
                                                VoiceEmbedding* out) {
  std::ifstream file(filepath, std::ios::binary);
  if (!file.is_open()) {
    fprintf(stderr, "[KokoroOnnx] Cannot open voice file: %s\n",
            filepath.c_str());
    return false;
  }

  // Read and validate magic
  char magic[6];
  if (!file.read(magic, 6) || memcmp(magic, "\x93NUMPY", 6) != 0) {
    fprintf(stderr,
            "[KokoroOnnx] Invalid numpy magic in %s\n", filepath.c_str());
    return false;
  }

  // Read version
  uint8_t major = 0, minor = 0;
  if (!file.read(reinterpret_cast<char*>(&major), 1) ||
      !file.read(reinterpret_cast<char*>(&minor), 1)) {
    fprintf(stderr, "[KokoroOnnx] Cannot read numpy version in %s\n",
            filepath.c_str());
    return false;
  }

  if (major != 1 && major != 2) {
    fprintf(stderr,
            "[KokoroOnnx] Unsupported numpy version %d.%d in %s\n",
            major, minor, filepath.c_str());
    return false;
  }

  // Read header length
  uint16_t header_len = 0;
  if (major == 1) {
    if (!file.read(reinterpret_cast<char*>(&header_len), 2)) {
      fprintf(stderr, "[KokoroOnnx] Cannot read header length in %s\n",
              filepath.c_str());
      return false;
    }
  } else {
    // Version 2.x uses uint32 for header length
    uint32_t hlen32 = 0;
    if (!file.read(reinterpret_cast<char*>(&hlen32), 4)) {
      fprintf(stderr, "[KokoroOnnx] Cannot read header length (v2) in %s\n",
              filepath.c_str());
      return false;
    }
    header_len = static_cast<uint16_t>(hlen32);
  }

  // Skip header (we know the data format: float32)
  file.seekg(header_len, std::ios_base::cur);
  if (!file.good()) {
    fprintf(stderr, "[KokoroOnnx] Seek past header failed in %s\n",
            filepath.c_str());
    return false;
  }

  // Read remaining data as float32
  std::streampos data_start = file.tellg();
  file.seekg(0, std::ios_base::end);
  std::streampos data_end = file.tellg();
  file.seekg(data_start, std::ios_base::beg);

  auto data_size = static_cast<size_t>(data_end - data_start);
  if (data_size == 0 || data_size % sizeof(float) != 0) {
    fprintf(stderr,
            "[KokoroOnnx] Invalid data size %zu in %s\n",
            data_size, filepath.c_str());
    return false;
  }

  size_t float_count = data_size / sizeof(float);
  out->data.resize(float_count);

  if (!file.read(reinterpret_cast<char*>(out->data.data()),
                  static_cast<std::streamsize>(data_size))) {
    fprintf(stderr, "[KokoroOnnx] Failed to read voice data from %s\n",
            filepath.c_str());
    return false;
  }

  // Validate: expect N × 256 floats
  if (float_count % 256 != 0) {
    fprintf(stderr,
            "[KokoroOnnx] Voice data size (%zu floats) not a multiple of 256 "
            "in %s\n",
            float_count, filepath.c_str());
    // Continue anyway — might still work
  }

  fprintf(stderr,
          "[KokoroOnnx] Parsed voice: %zu floats (%zu rows × 256) from %s\n",
          float_count, float_count / 256, filepath.c_str());
  return true;
}

}  // namespace kokoro
