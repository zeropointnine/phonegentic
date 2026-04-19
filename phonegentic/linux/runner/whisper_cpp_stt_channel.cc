// whisper_cpp_stt_channel.cc
//
// Flutter platform-channel bridge for on-device STT via whisper.cpp.
//
// MethodChannel  "com.agentic_ai/whisperkit_stt"      (Dart → native)
// EventChannel   "com.agentic_ai/whisperkit_transcripts" (native → Dart)
//
// These channel names are intentionally identical to the macOS WhisperKit
// channel names so that WhisperKitSttService.dart works on Linux unchanged.
//
// Audio flow:
//   Dart calls feedAudio(pcm16Bytes)
//     → bytes appended to buffer (under mutex)
//   GLib timer fires every 500 ms (main thread)
//     → if buffer has ≥ 1 s of audio and no inference in flight:
//         swap buffer, spawn inference GThread
//   Inference thread (worker)
//     → convert PCM16 → float, call whisper_full()
//     → schedule result delivery via g_idle_add
//   Idle callback (main thread)
//     → send transcript map over EventChannel
//
// Threading notes:
//   • buffer_mutex protects audio_buffer (main thread ↔ feedAudio calls, which
//     arrive via the Flutter method channel handler on the main thread anyway,
//     but the mutex makes the contract explicit).
//   • is_inferring is only set/cleared on the main thread (set before spawning
//     the thread; cleared in the g_idle_add callback), so it needs no mutex.
//   • shutting_down is set on the main thread in dispose; the idle callback
//     checks it before calling into Flutter.

#include "whisper_cpp_stt_channel.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <gio/gio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "whisper.h"

// ─── Constants ───────────────────────────────────────────────────────────────

static const char* kMethodChannelName = "com.agentic_ai/whisperkit_stt";
static const char* kEventChannelName  = "com.agentic_ai/whisperkit_transcripts";

static const char* kMethodInitialize       = "initialize";
static const char* kMethodIsModelAvailable = "isModelAvailable";
static const char* kMethodStart            = "startTranscription";
static const char* kMethodStop             = "stopTranscription";
static const char* kMethodFeedAudio        = "feedAudio";
static const char* kMethodDispose          = "dispose";

// Timer interval: how often we poll the audio buffer for VAD decisions.
static const guint  kTimerIntervalMs    = 500;

// Audio I/O rates.
static const int    kInputSampleRate    = 24000;  // audio_tap_channel output rate
static const int    kWhisperSampleRate  = 16000;  // whisper.cpp required rate

// VAD: silence threshold — RMS below this is treated as silence.
// ~0.004 ≈ –48 dBFS on a normalised float scale.
static const float  kMinEnergyRms       = 0.012f;
// VAD: consecutive silent 500 ms ticks required to trigger submission.
// 2 ticks = 1 second of post-speech silence.
static const guint  kSilenceTriggerTicks = 2;
// Minimum PCM16 bytes in buffer before we will ever submit (~0.5 s).
static const gsize  kMinSpeechBytes     = kInputSampleRate * 2 / 2;
// Emergency cap: submit even if speech is still ongoing (8 s max window).
static const gsize  kMaxBufferBytes     = kInputSampleRate * 2 * 8;

// Per-segment no-speech probability threshold: segments above this are dropped.
static const float  kNoSpeechThold      = 0.60f;

// ─── GObject struct ──────────────────────────────────────────────────────────

struct _WhisperCppSttChannel {
  GObject parent_instance;

  FlMethodChannel* method_channel;
  FlEventChannel*  event_channel;
  gboolean         event_listening;
  gboolean         shutting_down;

  whisper_context* ctx;          // null until initialize() succeeds
  gboolean         is_initialized;
  gboolean         is_initializing; // TRUE while background init thread is in flight
  gboolean         is_transcribing;
  gboolean         is_inferring;  // set/cleared on main thread around each job

  GMutex           buffer_mutex;
  GByteArray*      audio_buffer;  // accumulates PCM16 bytes between timer ticks
  guint            timer_id;      // GLib timeout source

  // VAD state — end-of-utterance detection.
  gsize            last_tick_end;        // byte offset in audio_buffer at last timer tick
  guint            silence_ticks;        // consecutive low-energy 500 ms ticks
  gboolean         has_speech_in_buffer; // at least one voiced tick since last submit
};

struct _WhisperCppSttChannelClass {
  GObjectClass parent_class;
};

G_DEFINE_TYPE(WhisperCppSttChannel, whisper_cpp_stt_channel, G_TYPE_OBJECT)

// Forward declarations
static void whisper_cpp_stt_channel_dispose_impl(GObject* object);
static void whisper_cpp_stt_channel_class_init(WhisperCppSttChannelClass* klass);
static void whisper_cpp_stt_channel_init(WhisperCppSttChannel* self);

// ─── Model path resolution ────────────────────────────────────────────────────
//
// Mirrors the convention used by KokoroTtsChannel:
//   {binary_dir}/data/flutter_assets/models/whisper-ggml/ggml-{size}.bin

static std::string get_binary_dir() {
  char buf[PATH_MAX];
  ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (len > 0) {
    buf[len] = '\0';
    std::string path(buf);
    auto slash = path.rfind('/');
    if (slash != std::string::npos) {
      return path.substr(0, slash + 1);
    }
  }
  return "./";
}

static std::string get_model_path(const char* model_size) {
  return get_binary_dir()
    + "data/flutter_assets/models/whisper-ggml/ggml-"
    + model_size
    + ".en.bin";
}

// ─── Inference data (passed to worker thread) ─────────────────────────────────

struct InferData {
  WhisperCppSttChannel* channel;
  GByteArray*           audio;   // caller transfers ownership
};

struct TranscriptData {
  WhisperCppSttChannel* channel;
  std::string           text;
};

// ─── Event emission ───────────────────────────────────────────────────────────

static gboolean send_transcript_idle(gpointer user_data) {
  TranscriptData* td = static_cast<TranscriptData*>(user_data);
  WhisperCppSttChannel* self = td->channel;

  self->is_inferring = FALSE;

  if (!self->shutting_down && self->event_listening && !td->text.empty()) {
    g_print("[WhisperSTT] Transcript: %s\n", td->text.c_str());
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "text",
        fl_value_new_string(td->text.c_str()));
    fl_value_set_string_take(map, "isFinal",
        fl_value_new_bool(TRUE));
    fl_value_set_string_take(map, "language",
        fl_value_new_string("en"));

    GError* error = nullptr;
    fl_event_channel_send(self->event_channel, map, nullptr, &error);
    if (error) {
      g_warning("[WhisperSTT] EventChannel send error: %s", error->message);
      g_error_free(error);
    }
  }

  delete td;
  return G_SOURCE_REMOVE;
}

// ─── Inference thread ─────────────────────────────────────────────────────────

static gpointer infer_thread_func(gpointer user_data) {
  InferData* id = static_cast<InferData*>(user_data);
  WhisperCppSttChannel* self = id->channel;

  const guint8* bytes  = id->audio->data;
  const gsize   n_bytes = id->audio->len;
  const gsize   n_samples = n_bytes / 2;

  // Convert PCM16 → float [-1.0, 1.0]
  std::vector<float> pcm(n_samples);
  for (gsize i = 0; i < n_samples; i++) {
    gint16 sample;
    memcpy(&sample, bytes + i * 2, 2);
    pcm[i] = static_cast<float>(sample) / 32768.0f;
  }

  g_byte_array_free(id->audio, TRUE);
  delete id;

  // ── Resample 24 kHz → 16 kHz ──────────────────────────────────────────────
  // whisper.cpp requires WHISPER_SAMPLE_RATE (16000 Hz).  The audio tap
  // delivers 24000 Hz.  Feeding the wrong rate causes pitch/speed distortion
  // that degrades transcription accuracy severely.  Linear interpolation is
  // sufficient for speech-band audio at this downsampling ratio (3:2).
  if (kInputSampleRate != kWhisperSampleRate) {
    const size_t n_out =
        static_cast<size_t>((double)n_samples * kWhisperSampleRate / kInputSampleRate);
    std::vector<float> resampled(n_out);
    const double step = static_cast<double>(n_samples) / static_cast<double>(n_out);
    for (size_t i = 0; i < n_out; i++) {
      const double pos  = i * step;
      const size_t lo   = static_cast<size_t>(pos);
      const double frac = pos - static_cast<double>(lo);
      const float  s0   = pcm[lo];
      const float  s1   = (lo + 1 < n_samples) ? pcm[lo + 1] : s0;
      resampled[i] = static_cast<float>(s0 + frac * (s1 - s0));
    }
    pcm = std::move(resampled);
  }
  // ─────────────────────────────────────────────────────────────────────────

  std::string result;

  if (!self->shutting_down && self->ctx != nullptr && !pcm.empty()) {
    whisper_full_params params =
        whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language         = "en";
    params.single_segment   = false;
    params.print_progress   = false;
    params.print_realtime   = false;
    params.print_timestamps = false;
    // whisper.cpp internal no-speech gate: suppress segments that are
    // predominantly non-speech at the decoder level.
    params.no_speech_thold  = kNoSpeechThold;

    const auto t0 = std::chrono::steady_clock::now();
    int rc = whisper_full(self->ctx, params,
                          pcm.data(), static_cast<int>(pcm.size()));
    const auto t1 = std::chrono::steady_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    g_print("[WhisperSTT] Inference duration %.0fms\n", ms);
    if (rc == 0) {
      int n_segs = whisper_full_n_segments(self->ctx);
      for (int i = 0; i < n_segs; i++) {
        // Drop segments where the model itself is uncertain about speech.
        float no_sp = whisper_full_get_segment_no_speech_prob(self->ctx, i);
        if (no_sp > kNoSpeechThold) continue;

        const char* seg = whisper_full_get_segment_text(self->ctx, i);
        if (seg) result += seg;
      }
      // Trim leading/trailing whitespace.
      auto start = result.find_first_not_of(" \t\n\r");
      auto end   = result.find_last_not_of(" \t\n\r");
      if (start != std::string::npos)
        result = result.substr(start, end - start + 1);
      // Filter whisper.cpp hallucination tokens that indicate no real speech.
      // [BLANK_AUDIO] is the canonical "nothing to transcribe" token.
      if (result == "[BLANK_AUDIO]" ||
          result == "(music)" ||
          result == "(applause)" ||
          result == "(silence)") {
        result.clear();
      }
    } else {
      g_warning("[WhisperSTT] whisper_full failed (rc=%d)", rc);
    }
  }

  // Always schedule idle callback to clear is_inferring and emit result.
  TranscriptData* td = new TranscriptData{self, std::move(result)};
  g_idle_add(send_transcript_idle, td);

  return nullptr;
}

// ─── Timer callback ───────────────────────────────────────────────────────────

static gboolean on_transcription_timer(gpointer user_data) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(user_data);

  if (!self->is_transcribing || self->shutting_down) {
    self->timer_id = 0;
    return G_SOURCE_REMOVE;
  }
  if (self->is_inferring) return G_SOURCE_CONTINUE;

  // ── Compute energy of audio received since the last timer tick ──────────
  g_mutex_lock(&self->buffer_mutex);
  const gsize   total_len  = self->audio_buffer->len;
  const gsize   tick_start = self->last_tick_end;
  const gsize   tick_bytes = (total_len > tick_start) ? (total_len - tick_start) : 0;
  const guint8* buf        = self->audio_buffer->data;

  float sum_sq = 0.0f;
  const gsize n_tick_samp = tick_bytes / 2;
  for (gsize i = 0; i < n_tick_samp; i++) {
    gint16 s;
    memcpy(&s, buf + tick_start + i * 2, 2);
    const float f = s / 32768.0f;
    sum_sq += f * f;
  }
  const float tick_rms = (n_tick_samp > 0)
                         ? sqrtf(sum_sq / static_cast<float>(n_tick_samp))
                         : 0.0f;
  self->last_tick_end = total_len;
  g_mutex_unlock(&self->buffer_mutex);
  // ────────────────────────────────────────────────────────────────────────

  // ── VAD state machine ───────────────────────────────────────────────────
  if (tick_rms >= kMinEnergyRms) {
    if (!self->has_speech_in_buffer) {
      g_print("[WhisperSTT] Speech start\n");
    }
    self->has_speech_in_buffer = TRUE;
    self->silence_ticks = 0;
  } else if (self->has_speech_in_buffer) {
    // Speech was detected earlier — count silent ticks towards end-of-utterance.
    self->silence_ticks++;
  }

  const gboolean end_of_utterance =
      self->has_speech_in_buffer &&
      self->silence_ticks >= kSilenceTriggerTicks;
  const gboolean buffer_overflow = (total_len >= kMaxBufferBytes);

  if (buffer_overflow && !self->has_speech_in_buffer) {
    // Buffer is full of non-speech audio — drain it without running inference.
    g_mutex_lock(&self->buffer_mutex);
    g_byte_array_set_size(self->audio_buffer, 0);
    self->last_tick_end = 0;
    g_mutex_unlock(&self->buffer_mutex);
    self->silence_ticks = 0;
    return G_SOURCE_CONTINUE;
  }

  // Only submit if we have enough audio and an actual trigger condition.
  if ((!end_of_utterance && !buffer_overflow) || total_len < kMinSpeechBytes) {
    return G_SOURCE_CONTINUE;
  }

  g_print("[WhisperSTT] Speech end %.2fs\n",
          static_cast<double>(total_len) / (kInputSampleRate * 2));
  // ────────────────────────────────────────────────────────────────────────

  // ── Swap the buffer and launch inference ─────────────────────────────────
  g_mutex_lock(&self->buffer_mutex);
  GByteArray* chunk  = self->audio_buffer;
  self->audio_buffer = g_byte_array_new();
  self->last_tick_end = 0;
  g_mutex_unlock(&self->buffer_mutex);

  self->has_speech_in_buffer = FALSE;
  self->silence_ticks        = 0;
  self->is_inferring         = TRUE;

  InferData* id = new InferData{self, chunk};
  g_thread_new("whisper-infer", infer_thread_func, id);

  return G_SOURCE_CONTINUE;
}

// ─── EventChannel listener callbacks ─────────────────────────────────────────

static FlMethodErrorResponse* on_event_listen(FlEventChannel* channel,
                                               FlValue*        args,
                                               gpointer        user_data) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(user_data);
  self->event_listening = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* on_event_cancel(FlEventChannel* channel,
                                               FlValue*        args,
                                               gpointer        user_data) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(user_data);
  self->event_listening = FALSE;
  return nullptr;
}

// ─── MethodChannel handlers ───────────────────────────────────────────────────

// ─── Async model initialisation ──────────────────────────────────────────────
//
// Model loading can take several seconds for a 142 MB file.  Running it on the
// main GLib thread blocks the Flutter event loop and freezes the UI.  We spawn
// a GThread, load the model there, then deliver the result via g_idle_add so
// all struct mutations stay on the main thread.
//
// If the initial GPU-accelerated load fails (e.g. Vulkan driver unavailable at
// runtime even though the library was compiled in), we retry with CPU-only.
// This is the primary cause of the "model not found" false-positive: the model
// file IS present but ggml-vulkan init fails and whisper_init_from_file_with_params
// returns nullptr.

struct InitJob {
  WhisperCppSttChannel* channel;  // ref'd; unref'd in on_init_result
  FlMethodCall*         call;     // ref'd; unref'd in on_init_result
  bool                  use_gpu;
  std::string           path;
};

struct InitJobResult {
  WhisperCppSttChannel* channel;
  FlMethodCall*         call;
  whisper_context*      ctx;   // nullptr on failure
};

static gboolean on_init_result(gpointer user_data) {
  auto* r = static_cast<InitJobResult*>(user_data);
  WhisperCppSttChannel* self = r->channel;

  self->is_initializing = FALSE;

  if (self->shutting_down) {
    if (r->ctx) whisper_free(r->ctx);
    // Still respond so the Dart Future completes.
    fl_method_call_respond_success(r->call, fl_value_new_bool(FALSE), nullptr);
  } else {
    self->ctx = r->ctx;
    self->is_initialized = (r->ctx != nullptr);
    if (self->is_initialized)
      g_print("[WhisperSTT] Model loaded successfully\n");
    else
      g_warning("[WhisperSTT] Failed to load model");
    fl_method_call_respond_success(r->call,
        fl_value_new_bool(self->is_initialized ? TRUE : FALSE), nullptr);
  }

  g_object_unref(r->call);
  g_object_unref(r->channel);
  delete r;
  return G_SOURCE_REMOVE;
}

static gpointer init_thread_func(gpointer user_data) {
  auto* job = static_cast<InitJob*>(user_data);

  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = job->use_gpu;

  whisper_context* ctx =
      whisper_init_from_file_with_params(job->path.c_str(), cparams);

  // GPU init can fail at runtime (missing/broken Vulkan driver) even when the
  // model file is valid.  Retry with CPU so we don't surface a false-positive
  // "model not found" error to the user.
  if (ctx == nullptr && job->use_gpu) {
    g_print("[WhisperSTT] GPU init failed — retrying with CPU-only\n");
    cparams.use_gpu = false;
    ctx = whisper_init_from_file_with_params(job->path.c_str(), cparams);
  }

  auto* result = new InitJobResult{job->channel, job->call, ctx};
  g_idle_add(on_init_result, result);

  delete job;
  return nullptr;
}
// ─────────────────────────────────────────────────────────────────────────────

static void handle_initialize(WhisperCppSttChannel* self,
                               FlMethodCall*         call) {
  if (self->is_initialized) {
    fl_method_call_respond_success(call, fl_value_new_bool(TRUE), nullptr);
    return;
  }
  if (self->is_initializing) {
    // Init already in flight — respond false; caller can retry after the
    // pending init completes.
    fl_method_call_respond_success(call, fl_value_new_bool(FALSE), nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(call);
  const char* model_size = "base";
  gboolean    use_gpu    = TRUE;

  if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* ms = fl_value_lookup_string(args, "modelSize");
    if (ms && fl_value_get_type(ms) == FL_VALUE_TYPE_STRING)
      model_size = fl_value_get_string(ms);

    FlValue* gpu = fl_value_lookup_string(args, "useGpu");
    if (gpu && fl_value_get_type(gpu) == FL_VALUE_TYPE_BOOL)
      use_gpu = fl_value_get_bool(gpu);
  }

  std::string path = get_model_path(model_size);
  g_print("[WhisperSTT] Loading model: %s (gpu=%s)\n", path.c_str(),
          use_gpu ? "true" : "false");

  self->is_initializing = TRUE;
  g_object_ref(self);
  g_object_ref(call);

  auto* job = new InitJob{self, call, static_cast<bool>(use_gpu), path};
  g_thread_new("whisper-init", init_thread_func, job);
}

static void handle_is_model_available(WhisperCppSttChannel* self,
                                       FlMethodCall*          call) {
  FlValue* args = fl_method_call_get_args(call);
  const char* model_size = "base";

  if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* ms = fl_value_lookup_string(args, "modelSize");
    if (ms && fl_value_get_type(ms) == FL_VALUE_TYPE_STRING)
      model_size = fl_value_get_string(ms);
  }

  std::string path = get_model_path(model_size);
  struct stat st;
  gboolean available = (stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode));

  g_debug("[WhisperSTT] isModelAvailable(%s) → %s",
          model_size, available ? "true" : "false");

  fl_method_call_respond_success(call,
      fl_value_new_bool(available), nullptr);
}

static void handle_start_transcription(WhisperCppSttChannel* self,
                                        FlMethodCall*          call) {
  if (!self->is_initialized) {
    fl_method_call_respond_error(call, "NOT_INITIALIZED",
        "Call initialize() first", nullptr, nullptr);
    return;
  }
  if (self->is_transcribing) {
    fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
    return;
  }

  self->is_transcribing = TRUE;

  // Clear stale audio and VAD state from any previous session.
  g_mutex_lock(&self->buffer_mutex);
  g_byte_array_set_size(self->audio_buffer, 0);
  self->last_tick_end = 0;
  g_mutex_unlock(&self->buffer_mutex);
  self->has_speech_in_buffer = FALSE;
  self->silence_ticks        = 0;
  self->is_inferring         = FALSE;

  self->timer_id = g_timeout_add(kTimerIntervalMs,
                                 on_transcription_timer, self);

  g_print("[WhisperSTT] Transcription started\n");
  fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
}

static void handle_stop_transcription(WhisperCppSttChannel* self,
                                       FlMethodCall*          call) {
  if (self->is_transcribing) {
    self->is_transcribing = FALSE;
    if (self->timer_id != 0) {
      g_source_remove(self->timer_id);
      self->timer_id = 0;
    }
    g_print("[WhisperSTT] Transcription stopped\n");
  }
  fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
}

static void handle_feed_audio(WhisperCppSttChannel* self,
                               FlMethodCall*          call) {
  if (!self->is_initialized || !self->is_transcribing) {
    fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
    return;
  }

  FlValue* audio_val = fl_value_lookup_string(args, "audio");
  if (!audio_val ||
      fl_value_get_type(audio_val) != FL_VALUE_TYPE_UINT8_LIST) {
    fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
    return;
  }

  gsize         len   = fl_value_get_length(audio_val);
  const guint8* bytes = fl_value_get_uint8_list(audio_val);

  g_mutex_lock(&self->buffer_mutex);
  g_byte_array_append(self->audio_buffer, bytes, static_cast<guint>(len));
  g_mutex_unlock(&self->buffer_mutex);

  fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
}

static void handle_dispose(WhisperCppSttChannel* self, FlMethodCall* call) {
  if (self->is_transcribing) {
    self->is_transcribing = FALSE;
    if (self->timer_id != 0) {
      g_source_remove(self->timer_id);
      self->timer_id = 0;
    }
  }
  if (self->ctx) {
    whisper_free(self->ctx);
    self->ctx = nullptr;
  }
  self->is_initialized = FALSE;
  fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
}

// ─── MethodChannel dispatch ───────────────────────────────────────────────────

static void method_call_cb(FlMethodChannel* channel,
                            FlMethodCall*    call,
                            gpointer         user_data) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(user_data);
  const gchar* method = fl_method_call_get_name(call);

  if (strcmp(method, kMethodInitialize) == 0)
    handle_initialize(self, call);
  else if (strcmp(method, kMethodIsModelAvailable) == 0)
    handle_is_model_available(self, call);
  else if (strcmp(method, kMethodStart) == 0)
    handle_start_transcription(self, call);
  else if (strcmp(method, kMethodStop) == 0)
    handle_stop_transcription(self, call);
  else if (strcmp(method, kMethodFeedAudio) == 0)
    handle_feed_audio(self, call);
  else if (strcmp(method, kMethodDispose) == 0)
    handle_dispose(self, call);
  else
    fl_method_call_respond_not_implemented(call, nullptr);
}

// ─── GObject lifecycle ────────────────────────────────────────────────────────

static void whisper_cpp_stt_channel_init(WhisperCppSttChannel* self) {
  self->event_listening      = FALSE;
  self->shutting_down        = FALSE;
  self->ctx                  = nullptr;
  self->is_initialized       = FALSE;
  self->is_initializing      = FALSE;
  self->is_transcribing      = FALSE;
  self->is_inferring         = FALSE;
  self->timer_id             = 0;
  self->last_tick_end        = 0;
  self->silence_ticks        = 0;
  self->has_speech_in_buffer = FALSE;

  g_mutex_init(&self->buffer_mutex);
  self->audio_buffer = g_byte_array_new();
}

static void whisper_cpp_stt_channel_dispose_impl(GObject* object) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(object);

  self->shutting_down   = TRUE;
  self->event_listening = FALSE;

  if (self->is_transcribing) {
    self->is_transcribing = FALSE;
    if (self->timer_id != 0) {
      g_source_remove(self->timer_id);
      self->timer_id = 0;
    }
  }

  if (self->ctx) {
    whisper_free(self->ctx);
    self->ctx = nullptr;
  }

  g_byte_array_free(self->audio_buffer, TRUE);
  self->audio_buffer = nullptr;

  g_mutex_clear(&self->buffer_mutex);

  G_OBJECT_CLASS(whisper_cpp_stt_channel_parent_class)->dispose(object);
}

static void whisper_cpp_stt_channel_class_init(WhisperCppSttChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = whisper_cpp_stt_channel_dispose_impl;
}

// ─── Public API ───────────────────────────────────────────────────────────────

WhisperCppSttChannel* whisper_cpp_stt_channel_new(FlBinaryMessenger* messenger) {
  WhisperCppSttChannel* self = WHISPER_CPP_STT_CHANNEL(
      g_object_new(whisper_cpp_stt_channel_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  self->method_channel = fl_method_channel_new(
      messenger, kMethodChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->method_channel, method_call_cb, self, nullptr);

  self->event_channel = fl_event_channel_new(
      messenger, kEventChannelName, FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      self->event_channel,
      on_event_listen, on_event_cancel,
      self, nullptr);

  return self;
}

void whisper_cpp_stt_channel_dispose(WhisperCppSttChannel* self) {
  g_return_if_fail(IS_WHISPER_CPP_STT_CHANNEL(self));
  g_object_unref(self);
}
