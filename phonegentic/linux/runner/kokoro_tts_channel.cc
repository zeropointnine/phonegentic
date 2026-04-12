#include "kokoro_tts_channel.h"
#include "kokoro_onnx_engine.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <linux/limits.h>

// ─── Channel names (must match macOS and Dart) ──────────────────────────────
static const char* kChannelName = "com.agentic_ai/kokoro_tts";
static const char* kEventChannelName = "com.agentic_ai/kokoro_tts_audio";

// ─── Method names ───────────────────────────────────────────────────────────
static const char* kMethodInitialize = "initialize";
static const char* kMethodIsModelAvailable = "isModelAvailable";
static const char* kMethodSetVoice = "setVoice";
static const char* kMethodSynthesize = "synthesize";
static const char* kMethodWarmup = "warmup";
static const char* kMethodDispose = "dispose";

// ─── Audio chunk size for EventChannel delivery (matches macOS: 4800 bytes) ─
static const size_t kAudioChunkSize = 4800;

// ─── Model paths relative to the binary directory ───────────────────────────
static const char* kModelRelPath =
    "data/flutter_assets/models/kokoro/kokoro-v1_0.onnx";
static const char* kVoicesRelPath =
    "data/flutter_assets/models/kokoro/voices";

// ═══════════════════════════════════════════════════════════════════════════════
// GObject struct & boilerplate
// ═══════════════════════════════════════════════════════════════════════════════

struct _KokoroTtsChannel {
  GObject parent_instance;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  gboolean event_listening;
  kokoro::KokoroOnnxEngine* engine;
  gboolean is_initialized;
  gboolean shutting_down;   // Set during dispose — prevents new threads and
                            // causes idle callbacks to skip Flutter calls.
  GMutex synth_mutex;       // Held during engine->synthesize() so dispose can
                            // wait for in-flight synthesis to complete.
};

struct _KokoroTtsChannelClass {
  GObjectClass parent_class;
};

G_DEFINE_TYPE(KokoroTtsChannel, kokoro_tts_channel, G_TYPE_OBJECT)

// Forward declarations (GObject lifecycle)
static void kokoro_tts_channel_dispose(GObject* object);
static void kokoro_tts_channel_class_init(KokoroTtsChannelClass* klass);
static void kokoro_tts_channel_init(KokoroTtsChannel* self);

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers — model file paths
// ═══════════════════════════════════════════════════════════════════════════════

/// Resolve the directory that contains the running binary via /proc/self/exe.
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

static std::string get_model_path() {
  return get_binary_dir() + kModelRelPath;
}

static std::string get_voices_dir() {
  return get_binary_dir() + kVoicesRelPath;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Async result delivery — scheduled on the GLib main loop via g_idle_add
// ═══════════════════════════════════════════════════════════════════════════════

/// Carries an initialize result from the background thread to the main loop.
struct InitResult {
  KokoroTtsChannel* channel;   // reffed for lifetime of this struct
  FlMethodCall* method_call;   // reffed; will be responded to
  bool success;
};

static gboolean deliver_init_result_idle(gpointer user_data) {
  InitResult* ir = static_cast<InitResult*>(user_data);

  // If the channel is shutting down, skip Flutter interactions (channels
  // may be partially torn down) and just release the refs.
  if (!ir->channel->shutting_down) {
    g_autoptr(FlValue) val = fl_value_new_bool(ir->success ? TRUE : FALSE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(ir->method_call, resp, nullptr);
  }

  g_object_unref(ir->method_call);
  g_object_unref(ir->channel);
  delete ir;
  return G_SOURCE_REMOVE;
}

/// Carries a synthesis / warmup result from the background thread to the
/// main loop.  For non-warmup synthesis, audio chunks are sent via the
/// EventChannel before responding nil to the MethodChannel.
struct SynthResult {
  KokoroTtsChannel* channel;       // reffed
  FlMethodCall* method_call;       // reffed
  std::vector<int16_t> pcm_data;   // empty for warmup or error
  bool is_warmup;
  bool success;
  std::string error_code;
  std::string error_message;
};

static gboolean deliver_synth_result_idle(gpointer user_data) {
  SynthResult* sr = static_cast<SynthResult*>(user_data);

  // If the channel is shutting down, skip all Flutter interactions.
  // The method_channel and event_channel may already be cleared.
  if (!sr->channel->shutting_down) {
    if (!sr->success) {
      // ── Error response ────────────────────────────────────────────────
      g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
          fl_method_error_response_new(sr->error_code.c_str(),
                                       sr->error_message.c_str(), nullptr));
      fl_method_call_respond(sr->method_call, resp, nullptr);
    } else {
      // ── Send audio chunks via EventChannel (synthesize only) ──────────
      if (!sr->is_warmup && !sr->pcm_data.empty() &&
          sr->channel->event_listening && sr->channel->event_channel) {
        const uint8_t* bytes =
            reinterpret_cast<const uint8_t*>(sr->pcm_data.data());
        size_t total_bytes = sr->pcm_data.size() * sizeof(int16_t);

        for (size_t off = 0; off < total_bytes; off += kAudioChunkSize) {
          size_t n = std::min(kAudioChunkSize, total_bytes - off);
          g_autoptr(FlValue) chunk =
              fl_value_new_uint8_list(bytes + off, n);
          GError* err = nullptr;
          fl_event_channel_send(sr->channel->event_channel, chunk, nullptr,
                                &err);
          if (err) {
            g_warning("[KokoroTTS] EventChannel send failed: %s",
                      err->message);
            g_error_free(err);
          }
        }
      }

      // ── Success response (nil) ────────────────────────────────────────
      g_autoptr(FlValue) null_val = fl_value_new_null();
      g_autoptr(FlMethodResponse) resp =
          FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
      fl_method_call_respond(sr->method_call, resp, nullptr);
    }
  }

  g_object_unref(sr->method_call);
  g_object_unref(sr->channel);
  delete sr;
  return G_SOURCE_REMOVE;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Background thread functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Runs engine->initialize() on a background thread (ONNX model loading is
/// heavy — must not block the Flutter UI thread).
static gpointer initialize_thread_func(gpointer user_data) {
  InitResult* ir = static_cast<InitResult*>(user_data);

  std::string model_path = get_model_path();
  std::string voices_dir = get_voices_dir();

  fprintf(stderr, "[KokoroTTS-DIAG] Init thread: model=%s voices=%s\n",
          model_path.c_str(), voices_dir.c_str());
  fflush(stderr);
  g_debug("[KokoroTTS] Initializing engine: model=%s voices=%s",
          model_path.c_str(), voices_dir.c_str());

  ir->success = ir->channel->engine->initialize(model_path, voices_dir);
  ir->channel->is_initialized = ir->success ? TRUE : FALSE;

  fprintf(stderr, "[KokoroTTS-DIAG] Init thread result: %s\n",
          ir->success ? "SUCCESS" : "FAILED");
  fflush(stderr);
  g_debug("[KokoroTTS] Initialize %s", ir->success ? "succeeded" : "failed");

  g_idle_add(deliver_init_result_idle, ir);
  return nullptr;
}

/// Parameters for the synthesis / warmup background thread.
struct SynthParams {
  KokoroTtsChannel* channel;  // reffed
  FlMethodCall* method_call;  // reffed
  std::string text;
  std::string voice;
  bool is_warmup;
};

/// Runs engine->synthesize() on a background thread, then schedules the
/// result (audio chunks + method response) on the GLib main loop.
static gpointer synthesize_thread_func(gpointer user_data) {
  SynthParams* params = static_cast<SynthParams*>(user_data);

  SynthResult* sr = new SynthResult();
  sr->channel = params->channel;          // transfer ref
  sr->method_call = params->method_call;  // transfer ref
  sr->is_warmup = params->is_warmup;
  sr->success = false;

  if (!params->is_warmup) {
    g_debug("[KokoroTTS] Synthesizing %zu chars with voice '%s'...",
            params->text.size(), params->voice.c_str());
  } else {
    g_debug("[KokoroTTS] Warmup with voice '%s'...",
            params->voice.c_str());
  }

  // Hold synth_mutex during engine access so dispose can wait for
  // in-flight synthesis before deleting the engine.
  g_mutex_lock(&params->channel->synth_mutex);
  if (!params->channel->shutting_down && params->channel->engine) {
    sr->pcm_data =
        params->channel->engine->synthesize(params->text, params->voice);
  }
  g_mutex_unlock(&params->channel->synth_mutex);

  if (!params->is_warmup && sr->pcm_data.empty() && !params->text.empty()) {
    // Synthesis produced no audio for non-empty text — treat as error.
    sr->error_code = "SYNTH_ERROR";
    sr->error_message = "Synthesis returned empty audio";
    sr->success = false;
  } else {
    sr->success = true;
    if (!params->is_warmup) {
      g_debug("[KokoroTTS] Synthesis complete: %zu samples (%zu bytes)",
              sr->pcm_data.size(), sr->pcm_data.size() * sizeof(int16_t));
    } else {
      g_debug("[KokoroTTS] Warmup complete");
    }
  }

  g_idle_add(deliver_synth_result_idle, sr);

  delete params;
  return nullptr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Method handlers
// ═══════════════════════════════════════════════════════════════════════════════

/// initialize — load ONNX model + espeak-ng + voice embeddings.
/// Runs on a background thread because model loading is slow.
static void handle_initialize(KokoroTtsChannel* self,
                              FlMethodCall* method_call) {
  // Already initialized → return immediately.
  if (self->is_initialized) {
    g_autoptr(FlValue) val = fl_value_new_bool(TRUE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  // Ref channel + method_call so they survive until the background thread
  // delivers the result on the main loop.
  InitResult* ir = new InitResult();
  ir->channel = self;
  g_object_ref(self);
  ir->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  ir->success = false;

  GThread* thread =
      g_thread_new("kokoro-init", initialize_thread_func, ir);
  if (thread) {
    g_thread_unref(thread);  // thread will clean up itself
  } else {
    g_warning("[KokoroTTS] Failed to create init thread");
    g_object_unref(ir->method_call);
    g_object_unref(ir->channel);
    delete ir;

    g_autoptr(FlValue) val = fl_value_new_bool(FALSE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

/// isModelAvailable — check if the ONNX model file exists (synchronous).
static void handle_is_model_available(KokoroTtsChannel* self,
                                      FlMethodCall* method_call) {
  std::string model_path = get_model_path();
  gboolean available =
      kokoro::KokoroOnnxEngine::is_model_available(model_path) ? TRUE
                                                                : FALSE;

  g_debug("[KokoroTTS] isModelAvailable(%s) → %s", model_path.c_str(),
          available ? "true" : "false");

  g_autoptr(FlValue) val = fl_value_new_bool(available);
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

/// setVoice — select a voice embedding by name (synchronous).
static void handle_set_voice(KokoroTtsChannel* self,
                             FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice = "af_heart";  // default

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* voice_val = fl_value_lookup_string(args, "voice");
    if (voice_val &&
        fl_value_get_type(voice_val) == FL_VALUE_TYPE_STRING) {
      voice = fl_value_get_string(voice_val);
    }
  }

  gboolean ok = (self->engine && self->engine->set_voice(voice)) ? TRUE
                                                                  : FALSE;
  g_debug("[KokoroTTS] setVoice('%s') → %s", voice.c_str(),
          ok ? "true" : "false");

  g_autoptr(FlValue) val = fl_value_new_bool(ok);
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

/// synthesize — run inference on a background thread, stream PCM16 via
/// EventChannel in ~4800-byte chunks, then respond nil.
static void handle_synthesize(KokoroTtsChannel* self,
                              FlMethodCall* method_call) {
  if (self->shutting_down || !self->is_initialized || !self->engine) {
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("NOT_INIT",
                                     "Kokoro TTS not initialized", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  std::string text;
  std::string voice = "af_heart";

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* text_val = fl_value_lookup_string(args, "text");
    if (text_val &&
        fl_value_get_type(text_val) == FL_VALUE_TYPE_STRING) {
      text = fl_value_get_string(text_val);
    }
    FlValue* voice_val = fl_value_lookup_string(args, "voice");
    if (voice_val &&
        fl_value_get_type(voice_val) == FL_VALUE_TYPE_STRING) {
      voice = fl_value_get_string(voice_val);
    }
  }

  // Empty text → respond nil immediately (no thread needed).
  if (text.empty()) {
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  // Launch background synthesis thread.
  SynthParams* params = new SynthParams();
  params->channel = self;
  g_object_ref(self);
  params->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  params->text = std::move(text);
  params->voice = std::move(voice);
  params->is_warmup = false;

  GThread* thread =
      g_thread_new("kokoro-synth", synthesize_thread_func, params);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[KokoroTTS] Failed to create synth thread");
    g_object_unref(params->method_call);
    g_object_unref(params->channel);
    delete params;

    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("SYNTH_ERROR",
                                     "Failed to start synthesis thread",
                                     nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

/// warmup — discarded synthesis to prime the ONNX session (background thread).
static void handle_warmup(KokoroTtsChannel* self,
                          FlMethodCall* method_call) {
  if (self->shutting_down || !self->is_initialized || !self->engine) {
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("NOT_INIT",
                                     "Kokoro TTS not initialized", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice = "af_heart";

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* voice_val = fl_value_lookup_string(args, "voice");
    if (voice_val &&
        fl_value_get_type(voice_val) == FL_VALUE_TYPE_STRING) {
      voice = fl_value_get_string(voice_val);
    }
  }

  SynthParams* params = new SynthParams();
  params->channel = self;
  g_object_ref(self);
  params->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  params->text = ".";  // minimal text for warmup (matches macOS)
  params->voice = std::move(voice);
  params->is_warmup = true;

  GThread* thread =
      g_thread_new("kokoro-warmup", synthesize_thread_func, params);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[KokoroTTS] Failed to create warmup thread");
    g_object_unref(params->method_call);
    g_object_unref(params->channel);
    delete params;

    // Warmup failure is non-fatal — respond nil (matches macOS).
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

/// dispose — release all engine resources (synchronous).
static void handle_dispose(KokoroTtsChannel* self,
                           FlMethodCall* method_call) {
  if (self->engine) {
    self->engine->dispose();
  }
  self->is_initialized = FALSE;
  g_debug("[KokoroTTS] Disposed");

  g_autoptr(FlValue) null_val = fl_value_new_null();
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
  fl_method_call_respond(method_call, resp, nullptr);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Method call dispatcher
// ═══════════════════════════════════════════════════════════════════════════════

static void method_call_handler(FlMethodChannel* channel,
                                FlMethodCall* method_call,
                                gpointer user_data) {
  KokoroTtsChannel* self = KOKORO_TTS_CHANNEL(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  fprintf(stderr, "[KokoroTTS-DIAG] Native method called: %s\n", method);
  fflush(stderr);
  g_debug("[KokoroTTS] Method called: %s", method);

  if (strcmp(method, kMethodInitialize) == 0) {
    handle_initialize(self, method_call);
  } else if (strcmp(method, kMethodIsModelAvailable) == 0) {
    handle_is_model_available(self, method_call);
  } else if (strcmp(method, kMethodSetVoice) == 0) {
    handle_set_voice(self, method_call);
  } else if (strcmp(method, kMethodSynthesize) == 0) {
    handle_synthesize(self, method_call);
  } else if (strcmp(method, kMethodWarmup) == 0) {
    handle_warmup(self, method_call);
  } else if (strcmp(method, kMethodDispose) == 0) {
    handle_dispose(self, method_call);
  } else {
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// EventChannel handlers
// ═══════════════════════════════════════════════════════════════════════════════

static FlMethodErrorResponse* on_listen_cb(FlEventChannel* channel,
                                           FlValue* args,
                                           gpointer user_data) {
  KokoroTtsChannel* self = KOKORO_TTS_CHANNEL(user_data);
  self->event_listening = TRUE;
  g_debug("[KokoroTTS] Event channel listening");
  return nullptr;
}

static FlMethodErrorResponse* on_cancel_cb(FlEventChannel* channel,
                                           FlValue* args,
                                           gpointer user_data) {
  KokoroTtsChannel* self = KOKORO_TTS_CHANNEL(user_data);
  self->event_listening = FALSE;
  g_debug("[KokoroTTS] Event channel cancelled");
  return nullptr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GObject lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

static void kokoro_tts_channel_dispose(GObject* object) {
  KokoroTtsChannel* self = KOKORO_TTS_CHANNEL(object);

  g_debug("[KokoroTTS] Disposing channel (GObject dispose)");

  // Signal shutdown so idle callbacks skip Flutter interactions and
  // synthesis threads bail out quickly.
  self->shutting_down = TRUE;

  // Wait for any in-flight synthesis to finish by acquiring the mutex.
  // The synthesis thread holds this mutex while calling engine->synthesize().
  g_mutex_lock(&self->synth_mutex);
  g_mutex_unlock(&self->synth_mutex);

  if (self->engine) {
    self->engine->dispose();
    delete self->engine;
    self->engine = nullptr;
  }
  self->is_initialized = FALSE;

  g_clear_object(&self->method_channel);
  g_clear_object(&self->event_channel);

  g_mutex_clear(&self->synth_mutex);

  G_OBJECT_CLASS(kokoro_tts_channel_parent_class)->dispose(object);
}

static void kokoro_tts_channel_class_init(KokoroTtsChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = kokoro_tts_channel_dispose;
}

static void kokoro_tts_channel_init(KokoroTtsChannel* self) {
  self->method_channel = nullptr;
  self->event_channel = nullptr;
  self->event_listening = FALSE;
  self->engine = new kokoro::KokoroOnnxEngine();
  self->is_initialized = FALSE;
  self->shutting_down = FALSE;
  g_mutex_init(&self->synth_mutex);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════════

KokoroTtsChannel* kokoro_tts_channel_new(FlBinaryMessenger* messenger) {
  g_return_val_if_fail(FL_IS_BINARY_MESSENGER(messenger), nullptr);

  KokoroTtsChannel* self = KOKORO_TTS_CHANNEL(
      g_object_new(kokoro_tts_channel_get_type(), nullptr));

  // Both channels share a single codec instance (each channel refs it).
  FlStandardMethodCodec* codec = fl_standard_method_codec_new();

  self->method_channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));

  if (self->method_channel) {
    fl_method_channel_set_method_call_handler(self->method_channel,
                                              method_call_handler, self,
                                              nullptr);
  }

  self->event_channel = fl_event_channel_new(
      messenger, kEventChannelName, FL_METHOD_CODEC(codec));

  if (self->event_channel) {
    fl_event_channel_set_stream_handlers(self->event_channel, on_listen_cb,
                                         on_cancel_cb, self, nullptr);
  }

  // Release the local codec ref — the channels hold their own refs.
  g_clear_object(&codec);

  fprintf(stderr, "[KokoroTTS-DIAG] KokoroTtsChannel created and registered\n");
  fflush(stderr);
  g_debug("[KokoroTTS] KokoroTtsChannel created");
  return self;
}

void kokoro_tts_channel_dispose(KokoroTtsChannel* self) {
  if (self) {
    g_object_unref(self);
  }
}
