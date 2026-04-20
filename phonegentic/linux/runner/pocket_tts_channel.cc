#include "pocket_tts_channel.h"
#include "pocket_tts_onnx_engine.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <linux/limits.h>

static const char* kChannelName      = "com.agentic_ai/pocket_tts";
static const char* kEventChannelName = "com.agentic_ai/pocket_tts_audio";

static const char* kMethodInitialize           = "initialize";
static const char* kMethodIsModelAvailable     = "isModelAvailable";
static const char* kMethodSetVoice             = "setVoice";
static const char* kMethodSetGainOverride      = "setGainOverride";
static const char* kMethodSynthesize           = "synthesize";
static const char* kMethodWarmup               = "warmup";
static const char* kMethodDispose              = "dispose";
static const char* kMethodEncodeVoice          = "encodeVoice";
static const char* kMethodExportVoiceEmbedding = "exportVoiceEmbedding";
static const char* kMethodImportVoiceEmbedding = "importVoiceEmbedding";

static const size_t kAudioChunkSize = 4800;

static const char* kModelsRelPath =
    "data/flutter_assets/models/pocket-tts-onnx";

// ═══════════════════════════════════════════════════════════════════════════════
// GObject struct
// ═══════════════════════════════════════════════════════════════════════════════

struct _PocketTtsChannel {
  GObject parent_instance;
  FlMethodChannel* method_channel;
  FlEventChannel*  event_channel;
  gboolean         event_listening;
  pocket_tts::PocketTtsOnnxEngine* engine;
  gboolean         is_initialized;
  gboolean         shutting_down;
  GMutex           synth_mutex;
};

struct _PocketTtsChannelClass {
  GObjectClass parent_class;
};

G_DEFINE_TYPE(PocketTtsChannel, pocket_tts_channel, G_TYPE_OBJECT)

static void pocket_tts_channel_dispose(GObject* object);
static void pocket_tts_channel_class_init(PocketTtsChannelClass* klass);
static void pocket_tts_channel_init(PocketTtsChannel* self);

// ── Path helpers ─────────────────────────────────────────────────────────────

static std::string get_binary_dir() {
  char buf[PATH_MAX];
  ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (len > 0) {
    buf[len] = '\0';
    std::string path(buf);
    auto slash = path.rfind('/');
    if (slash != std::string::npos) return path.substr(0, slash + 1);
  }
  return "./";
}

static std::string get_models_dir() {
  return get_binary_dir() + kModelsRelPath;
}

// ── Async result delivery via g_idle_add ─────────────────────────────────────

struct InitResult {
  PocketTtsChannel* channel;
  FlMethodCall*     method_call;
  bool success;
};

static gboolean deliver_init_result_idle(gpointer user_data) {
  InitResult* ir = static_cast<InitResult*>(user_data);
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

struct SynthResult {
  PocketTtsChannel*      channel;
  FlMethodCall*          method_call;
  std::vector<int16_t>   pcm_data;
  bool                   is_warmup;
  bool                   success;
  std::string            error_code;
  std::string            error_message;
};

// Carries a single streaming PCM chunk from the synthesis thread to the
// main thread for delivery via EventChannel.
struct StreamChunkResult {
  PocketTtsChannel*    channel;
  std::vector<int16_t> pcm_data;
};

struct EncodeVoiceParams {
  PocketTtsChannel*    channel;
  FlMethodCall*        method_call;
  std::vector<int16_t> pcm_data;
  std::string          voice_id;
};

struct EncodeVoiceResult {
  PocketTtsChannel* channel;
  FlMethodCall*     method_call;
  bool              success;
  std::string       error_code;
  std::string       error_message;
};

static gboolean deliver_synth_result_idle(gpointer user_data) {
  SynthResult* sr = static_cast<SynthResult*>(user_data);
  if (!sr->channel->shutting_down) {
    if (!sr->success) {
      g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
          fl_method_error_response_new(sr->error_code.c_str(),
                                       sr->error_message.c_str(), nullptr));
      fl_method_call_respond(sr->method_call, resp, nullptr);
    } else {
      if (!sr->is_warmup && !sr->pcm_data.empty() &&
          sr->channel->event_listening && sr->channel->event_channel) {
        const uint8_t* bytes =
            reinterpret_cast<const uint8_t*>(sr->pcm_data.data());
        size_t total = sr->pcm_data.size() * sizeof(int16_t);
        for (size_t off = 0; off < total; off += kAudioChunkSize) {
          size_t n = std::min(kAudioChunkSize, total - off);
          g_autoptr(FlValue) chunk = fl_value_new_uint8_list(bytes + off, n);
          GError* err = nullptr;
          fl_event_channel_send(sr->channel->event_channel, chunk, nullptr, &err);
          if (err) { g_warning("[PocketTTS] EventChannel send: %s", err->message); g_error_free(err); }
        }
      }
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

static gboolean deliver_stream_chunk_idle(gpointer user_data) {
  StreamChunkResult* cr = static_cast<StreamChunkResult*>(user_data);
  if (!cr->channel->shutting_down && cr->channel->event_listening &&
      cr->channel->event_channel && !cr->pcm_data.empty()) {
    const uint8_t* bytes =
        reinterpret_cast<const uint8_t*>(cr->pcm_data.data());
    size_t total = cr->pcm_data.size() * sizeof(int16_t);
    for (size_t off = 0; off < total; off += kAudioChunkSize) {
      size_t n = std::min(kAudioChunkSize, total - off);
      g_autoptr(FlValue) chunk = fl_value_new_uint8_list(bytes + off, n);
      GError* err = nullptr;
      fl_event_channel_send(cr->channel->event_channel, chunk, nullptr, &err);
      if (err) {
        g_warning("[PocketTTS] EventChannel send: %s", err->message);
        g_error_free(err);
      }
    }
  }
  g_object_unref(cr->channel);
  delete cr;
  return G_SOURCE_REMOVE;
}

static gboolean deliver_encode_voice_result_idle(gpointer user_data) {
  EncodeVoiceResult* er = static_cast<EncodeVoiceResult*>(user_data);
  if (!er->channel->shutting_down) {
    if (!er->success) {
      g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
          fl_method_error_response_new(er->error_code.c_str(),
                                       er->error_message.c_str(), nullptr));
      fl_method_call_respond(er->method_call, resp, nullptr);
    } else {
      g_autoptr(FlValue) val = fl_value_new_bool(TRUE);
      g_autoptr(FlMethodResponse) resp =
          FL_METHOD_RESPONSE(fl_method_success_response_new(val));
      fl_method_call_respond(er->method_call, resp, nullptr);
    }
  }
  g_object_unref(er->method_call);
  g_object_unref(er->channel);
  delete er;
  return G_SOURCE_REMOVE;
}

// ── Background thread functions ───────────────────────────────────────────────

static gpointer encode_voice_thread_func(gpointer user_data) {
  EncodeVoiceParams* params = static_cast<EncodeVoiceParams*>(user_data);

  EncodeVoiceResult* er = new EncodeVoiceResult();
  er->channel     = params->channel;
  er->method_call = params->method_call;
  er->success     = false;

  if (!params->channel->shutting_down && params->channel->engine) {
    er->success = params->channel->engine->encode_voice(
        params->pcm_data.data(), params->pcm_data.size(), params->voice_id);
    if (!er->success) {
      er->error_code    = "ENCODE_FAILED";
      er->error_message = "Voice encoder failed — check mimi_encoder.onnx";
    }
  } else {
    er->error_code    = "NOT_INIT";
    er->error_message = "Pocket TTS not initialized";
  }

  g_idle_add(deliver_encode_voice_result_idle, er);
  delete params;
  return nullptr;
}

static gpointer initialize_thread_func(gpointer user_data) {
  InitResult* ir = static_cast<InitResult*>(user_data);
  std::string models_dir = get_models_dir();
  fprintf(stderr, "[PocketTTS-DIAG] Init thread: models_dir=%s\n",
          models_dir.c_str());
  fflush(stderr);
  ir->success = ir->channel->engine->initialize(models_dir);
  ir->channel->is_initialized = ir->success ? TRUE : FALSE;
  fprintf(stderr, "[PocketTTS-DIAG] Init thread result: %s\n",
          ir->success ? "SUCCESS" : "FAILED");
  fflush(stderr);
  g_idle_add(deliver_init_result_idle, ir);
  return nullptr;
}

struct SynthParams {
  PocketTtsChannel* channel;
  FlMethodCall*     method_call;
  std::string       text;
  std::string       voice;
  bool              is_warmup;
};

static gpointer synthesize_thread_func(gpointer user_data) {
  SynthParams* params = static_cast<SynthParams*>(user_data);

  SynthResult* sr = new SynthResult();
  sr->channel     = params->channel;
  sr->method_call = params->method_call;
  sr->is_warmup   = params->is_warmup;
  sr->success     = false;

  g_mutex_lock(&params->channel->synth_mutex);
  if (!params->channel->shutting_down && params->channel->engine) {
    if (params->is_warmup) {
      params->channel->engine->warmup();
      sr->success = true;
    } else {
      // Streaming: deliver PCM chunks to the EventChannel as they are decoded
      // rather than accumulating all audio and sending in one burst.
      params->channel->engine->synthesize_streaming(
          params->text, params->voice,
          [params](std::vector<int16_t> chunk) {
            if (params->channel->shutting_down || chunk.empty()) return;
            StreamChunkResult* cr = new StreamChunkResult();
            cr->channel  = params->channel;
            cr->pcm_data = std::move(chunk);
            g_object_ref(params->channel);
            g_idle_add(deliver_stream_chunk_idle, cr);
          });
      sr->success = true;
    }
  }
  g_mutex_unlock(&params->channel->synth_mutex);

  // sr->pcm_data is intentionally empty in streaming mode — all chunks were
  // already dispatched via deliver_stream_chunk_idle. deliver_synth_result_idle
  // will skip EventChannel delivery and just respond to the method call.
  g_idle_add(deliver_synth_result_idle, sr);
  delete params;
  return nullptr;
}

// ── Method handlers ───────────────────────────────────────────────────────────

static void handle_initialize(PocketTtsChannel* self,
                               FlMethodCall* method_call) {
  if (self->is_initialized) {
    g_autoptr(FlValue) val = fl_value_new_bool(TRUE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  InitResult* ir = new InitResult();
  ir->channel     = self;
  ir->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  ir->success     = false;
  g_object_ref(self);

  GThread* thread = g_thread_new("pocket-tts-init", initialize_thread_func, ir);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[PocketTTS] Failed to create init thread");
    g_object_unref(ir->method_call);
    g_object_unref(ir->channel);
    delete ir;
    g_autoptr(FlValue) val = fl_value_new_bool(FALSE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

static void handle_is_model_available(PocketTtsChannel* self,
                                       FlMethodCall* method_call) {
  std::string models_dir = get_models_dir();
  gboolean available =
      pocket_tts::PocketTtsOnnxEngine::is_model_available(models_dir)
      ? TRUE : FALSE;
  g_debug("[PocketTTS] isModelAvailable(%s) → %s", models_dir.c_str(),
          available ? "true" : "false");
  g_autoptr(FlValue) val = fl_value_new_bool(available);
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

static void handle_set_voice(PocketTtsChannel* self,
                              FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice = "default";
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* v = fl_value_lookup_string(args, "voice");
    if (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING)
      voice = fl_value_get_string(v);
  }
  gboolean ok = (self->engine && self->engine->set_voice(voice)) ? TRUE : FALSE;
  g_debug("[PocketTTS] setVoice('%s') → %s", voice.c_str(),
          ok ? "ok" : "fail");
  g_autoptr(FlValue) val = fl_value_new_bool(ok);
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

static void handle_set_gain_override(PocketTtsChannel* self,
                                      FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  float gain = -1.0f;
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* v = fl_value_lookup_string(args, "gain");
    if (v && fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
      gain = static_cast<float>(fl_value_get_float(v));
  }
  if (self->engine) self->engine->set_gain_override(gain);
  g_autoptr(FlValue) null_val = fl_value_new_null();
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
  fl_method_call_respond(method_call, resp, nullptr);
}

static void handle_synthesize(PocketTtsChannel* self,
                               FlMethodCall* method_call) {
  if (self->shutting_down || !self->is_initialized || !self->engine) {
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("NOT_INIT",
                                     "Pocket TTS not initialized", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  std::string text, voice = "default";
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* tv = fl_value_lookup_string(args, "text");
    if (tv && fl_value_get_type(tv) == FL_VALUE_TYPE_STRING)
      text = fl_value_get_string(tv);
    FlValue* vv = fl_value_lookup_string(args, "voice");
    if (vv && fl_value_get_type(vv) == FL_VALUE_TYPE_STRING)
      voice = fl_value_get_string(vv);
  }

  if (text.empty()) {
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  SynthParams* params = new SynthParams();
  params->channel     = self;
  params->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  params->text        = std::move(text);
  params->voice       = std::move(voice);
  params->is_warmup   = false;
  g_object_ref(self);

  GThread* thread = g_thread_new("pocket-tts-synth", synthesize_thread_func, params);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[PocketTTS] Failed to create synth thread");
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

static void handle_warmup(PocketTtsChannel* self, FlMethodCall* method_call) {
  if (self->shutting_down || !self->is_initialized || !self->engine) {
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("NOT_INIT",
                                     "Pocket TTS not initialized", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice = "default";
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* vv = fl_value_lookup_string(args, "voice");
    if (vv && fl_value_get_type(vv) == FL_VALUE_TYPE_STRING)
      voice = fl_value_get_string(vv);
  }

  SynthParams* params = new SynthParams();
  params->channel     = self;
  params->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  params->text        = ".";
  params->voice       = std::move(voice);
  params->is_warmup   = true;
  g_object_ref(self);

  GThread* thread = g_thread_new("pocket-tts-warmup", synthesize_thread_func, params);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[PocketTTS] Failed to create warmup thread");
    g_object_unref(params->method_call);
    g_object_unref(params->channel);
    delete params;
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

static void handle_dispose_method(PocketTtsChannel* self,
                                   FlMethodCall* method_call) {
  if (self->engine) self->engine->dispose();
  self->is_initialized = FALSE;
  g_debug("[PocketTTS] Disposed via method call");
  g_autoptr(FlValue) null_val = fl_value_new_null();
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
  fl_method_call_respond(method_call, resp, nullptr);
}

static void handle_encode_voice(PocketTtsChannel* self,
                                 FlMethodCall* method_call) {
  if (self->shutting_down || !self->is_initialized || !self->engine) {
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("NOT_INIT",
                                     "Pocket TTS not initialized", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice_id;
  std::vector<int16_t> pcm_data;

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* vid = fl_value_lookup_string(args, "voiceId");
    if (vid && fl_value_get_type(vid) == FL_VALUE_TYPE_STRING)
      voice_id = fl_value_get_string(vid);

    FlValue* ad = fl_value_lookup_string(args, "audioData");
    if (ad && fl_value_get_type(ad) == FL_VALUE_TYPE_UINT8_LIST) {
      const uint8_t* bytes = fl_value_get_uint8_list(ad);
      size_t len = fl_value_get_length(ad);
      // audioData is PCM16 LE bytes; each sample is 2 bytes.
      size_t n_samples = len / 2;
      pcm_data.resize(n_samples);
      memcpy(pcm_data.data(), bytes, n_samples * sizeof(int16_t));
    }
  }

  if (voice_id.empty() || pcm_data.empty()) {
    g_autoptr(FlValue) val = fl_value_new_bool(FALSE);
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  EncodeVoiceParams* params = new EncodeVoiceParams();
  params->channel     = self;
  params->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  params->pcm_data    = std::move(pcm_data);
  params->voice_id    = std::move(voice_id);
  g_object_ref(self);

  GThread* thread = g_thread_new("pocket-tts-encode", encode_voice_thread_func, params);
  if (thread) {
    g_thread_unref(thread);
  } else {
    g_warning("[PocketTTS] Failed to create encode thread");
    g_object_unref(params->method_call);
    g_object_unref(params->channel);
    delete params;
    g_autoptr(FlMethodResponse) resp = FL_METHOD_RESPONSE(
        fl_method_error_response_new("ENCODE_ERROR",
                                     "Failed to start encoder thread", nullptr));
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

static void handle_export_voice_embedding(PocketTtsChannel* self,
                                           FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice_id;
  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* vid = fl_value_lookup_string(args, "voiceId");
    if (vid && fl_value_get_type(vid) == FL_VALUE_TYPE_STRING)
      voice_id = fl_value_get_string(vid);
  }

  if (voice_id.empty() || !self->engine) {
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  auto data = self->engine->export_voice_embedding(voice_id);
  if (data.empty()) {
    g_autoptr(FlValue) null_val = fl_value_new_null();
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_success_response_new(null_val));
    fl_method_call_respond(method_call, resp, nullptr);
    return;
  }

  g_autoptr(FlValue) val = fl_value_new_uint8_list(data.data(), data.size());
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

static void handle_import_voice_embedding(PocketTtsChannel* self,
                                           FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  std::string voice_id;
  const uint8_t* data_bytes = nullptr;
  size_t data_size = 0;

  if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* vid = fl_value_lookup_string(args, "voiceId");
    if (vid && fl_value_get_type(vid) == FL_VALUE_TYPE_STRING)
      voice_id = fl_value_get_string(vid);
    FlValue* emb = fl_value_lookup_string(args, "embeddingData");
    if (emb && fl_value_get_type(emb) == FL_VALUE_TYPE_UINT8_LIST) {
      data_bytes = fl_value_get_uint8_list(emb);
      data_size  = fl_value_get_length(emb);
    }
  }

  bool ok = (!voice_id.empty() && data_bytes && data_size > 0 && self->engine)
      ? self->engine->import_voice_embedding(voice_id, data_bytes, data_size)
      : false;

  g_autoptr(FlValue) val = fl_value_new_bool(ok ? TRUE : FALSE);
  g_autoptr(FlMethodResponse) resp =
      FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  fl_method_call_respond(method_call, resp, nullptr);
}

// ── Method call dispatcher ────────────────────────────────────────────────────

static void method_call_handler(FlMethodChannel* /*channel*/,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  PocketTtsChannel* self = POCKET_TTS_CHANNEL(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  fprintf(stderr, "[PocketTTS-DIAG] Native method called: %s\n", method);
  fflush(stderr);

  if      (strcmp(method, kMethodInitialize)           == 0) handle_initialize(self, method_call);
  else if (strcmp(method, kMethodIsModelAvailable)     == 0) handle_is_model_available(self, method_call);
  else if (strcmp(method, kMethodSetVoice)             == 0) handle_set_voice(self, method_call);
  else if (strcmp(method, kMethodSetGainOverride)      == 0) handle_set_gain_override(self, method_call);
  else if (strcmp(method, kMethodSynthesize)           == 0) handle_synthesize(self, method_call);
  else if (strcmp(method, kMethodWarmup)               == 0) handle_warmup(self, method_call);
  else if (strcmp(method, kMethodDispose)              == 0) handle_dispose_method(self, method_call);
  else if (strcmp(method, kMethodEncodeVoice)          == 0) handle_encode_voice(self, method_call);
  else if (strcmp(method, kMethodExportVoiceEmbedding) == 0) handle_export_voice_embedding(self, method_call);
  else if (strcmp(method, kMethodImportVoiceEmbedding) == 0) handle_import_voice_embedding(self, method_call);
  else {
    g_autoptr(FlMethodResponse) resp =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, resp, nullptr);
  }
}

// ── EventChannel handlers ─────────────────────────────────────────────────────

static FlMethodErrorResponse* on_listen_cb(FlEventChannel* /*channel*/,
                                            FlValue* /*args*/,
                                            gpointer user_data) {
  POCKET_TTS_CHANNEL(user_data)->event_listening = TRUE;
  g_debug("[PocketTTS] Event channel listening");
  return nullptr;
}

static FlMethodErrorResponse* on_cancel_cb(FlEventChannel* /*channel*/,
                                            FlValue* /*args*/,
                                            gpointer user_data) {
  POCKET_TTS_CHANNEL(user_data)->event_listening = FALSE;
  g_debug("[PocketTTS] Event channel cancelled");
  return nullptr;
}

// ── GObject lifecycle ─────────────────────────────────────────────────────────

static void pocket_tts_channel_dispose(GObject* object) {
  PocketTtsChannel* self = POCKET_TTS_CHANNEL(object);
  g_debug("[PocketTTS] Disposing channel");

  self->shutting_down = TRUE;

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

  G_OBJECT_CLASS(pocket_tts_channel_parent_class)->dispose(object);
}

static void pocket_tts_channel_class_init(PocketTtsChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = pocket_tts_channel_dispose;
}

static void pocket_tts_channel_init(PocketTtsChannel* self) {
  self->method_channel = nullptr;
  self->event_channel  = nullptr;
  self->event_listening = FALSE;
  self->engine         = new pocket_tts::PocketTtsOnnxEngine();
  self->is_initialized = FALSE;
  self->shutting_down  = FALSE;
  g_mutex_init(&self->synth_mutex);
}

// ── Public API ────────────────────────────────────────────────────────────────

PocketTtsChannel* pocket_tts_channel_new(FlBinaryMessenger* messenger) {
  g_return_val_if_fail(FL_IS_BINARY_MESSENGER(messenger), nullptr);

  PocketTtsChannel* self = POCKET_TTS_CHANNEL(
      g_object_new(pocket_tts_channel_get_type(), nullptr));

  FlStandardMethodCodec* codec = fl_standard_method_codec_new();

  self->method_channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));
  if (self->method_channel)
    fl_method_channel_set_method_call_handler(
        self->method_channel, method_call_handler, self, nullptr);

  self->event_channel = fl_event_channel_new(
      messenger, kEventChannelName, FL_METHOD_CODEC(codec));
  if (self->event_channel)
    fl_event_channel_set_stream_handlers(
        self->event_channel, on_listen_cb, on_cancel_cb, self, nullptr);

  g_clear_object(&codec);

  fprintf(stderr, "[PocketTTS-DIAG] PocketTtsChannel created and registered\n");
  fflush(stderr);
  return self;
}

void pocket_tts_channel_dispose(PocketTtsChannel* self) {
  if (self) g_object_unref(self);
}
