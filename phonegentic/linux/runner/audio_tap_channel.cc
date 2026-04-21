#include "audio_tap_channel.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <pulse/pulseaudio.h>
#include <pulse/thread-mainloop.h>
#include <string.h>
#include <vector>
#include <sys/time.h>
#include <cmath>

// Channel name - must match macOS implementation
static const char* kChannelName = "com.agentic_ai/audio_tap_control";
static const char* kEventChannelName = "com.agentic_ai/audio_tap";

// Method names
static const char* kMethodStartAudioTap = "startAudioTap";
static const char* kMethodStopAudioTap = "stopAudioTap";
static const char* kMethodPlayAudioResponse = "playAudioResponse";
static const char* kMethodStopAudioPlayback = "stopAudioPlayback";
static const char* kMethodInitSpeakerIdentifier = "initSpeakerIdentifier";
static const char* kMethodLoadKnownSpeakers = "loadKnownSpeakers";
static const char* kMethodRegisterHostSpeaker = "registerHostSpeaker";
static const char* kMethodGetHostSpeakerEmbedding = "getHostSpeakerEmbedding";
static const char* kMethodResetSpeakerIdentifier = "resetSpeakerIdentifier";
static const char* kMethodGetRemoteSpeakerEmbedding = "getRemoteSpeakerEmbedding";
static const char* kMethodGetDominantSpeaker = "getDominantSpeaker";

// Audio configuration
static const int kTargetSampleRate = 24000;
static const int kChannels = 1;
static const int kChunkDurationMs = 100;
static const int kChunkSize = (kTargetSampleRate * kChunkDurationMs / 1000) * sizeof(int16_t);

// AudioTapChannel structure
struct _AudioTapChannel {
  GObject parent_instance;
  FlMethodChannel* channel;
  FlEventChannel* event_channel;
  gboolean event_listening;
};

struct _AudioTapChannelClass {
  GObjectClass parent_class;
};

G_DEFINE_TYPE(AudioTapChannel, audio_tap_channel, G_TYPE_OBJECT)

// ── Thread-safe PulseAudio state ──────────────────────────────────────────────
//
// All PulseAudio operations are serialised through pa_threaded_mainloop_lock() /
// unlock().  The threaded mainloop runs its own internal thread for capture
// callbacks; every external call (from the Flutter/GLib thread) acquires the
// lock first.  This prevents the assertion crash that occurred when pa_mainloop
// was iterated on one thread while pa_stream_write() was called from another.

static pa_threaded_mainloop* g_threaded_ml = nullptr;
static pa_context* g_context = nullptr;
static pa_stream* g_capture_stream = nullptr;
static pa_stream* g_playback_stream = nullptr;
static gboolean g_is_capturing = FALSE;
static gboolean g_context_ready = FALSE;
static gboolean g_playback_ready = FALSE;
static AudioTapChannel* g_tap_channel_instance = nullptr;

static int64_t g_suppress_diag_count = 0;

// Forward declarations
static void audio_tap_channel_dispose(GObject* object);
static void audio_tap_channel_class_init(AudioTapChannelClass* klass);
static void audio_tap_channel_init(AudioTapChannel* self);
static void pulse_audio_cleanup();

// ═══════════════════════════════════════════════════════════════════════════════
// PulseAudio context state callback — signals the threaded mainloop's condvar
// so that the waiting thread can proceed once the context is READY.
// ═══════════════════════════════════════════════════════════════════════════════

static void context_state_cb(pa_context* c, void* userdata) {
  switch (pa_context_get_state(c)) {
    case PA_CONTEXT_READY:
      g_debug("[AudioTap] PulseAudio context ready");
      g_context_ready = TRUE;
      pa_threaded_mainloop_signal(g_threaded_ml, 0);
      break;
    case PA_CONTEXT_FAILED:
    case PA_CONTEXT_TERMINATED:
      g_warning("[AudioTap] PulseAudio context failed/terminated");
      g_context_ready = FALSE;
      pa_threaded_mainloop_signal(g_threaded_ml, 0);
      break;
    default:
      break;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Capture stream callbacks — run on the PA threaded mainloop thread.
// We schedule Flutter event delivery via g_idle_add (GLib main thread).
// ═══════════════════════════════════════════════════════════════════════════════

struct AudioData {
  uint8_t* data;
  size_t size;
};

static gboolean send_audio_idle(gpointer user_data) {
  AudioData* audio = static_cast<AudioData*>(user_data);
  if (g_tap_channel_instance && g_tap_channel_instance->event_listening) {
    g_autoptr(FlValue) audio_data = fl_value_new_uint8_list(audio->data, audio->size);
    GError* error = nullptr;
    fl_event_channel_send(g_tap_channel_instance->event_channel, audio_data, nullptr, &error);
    if (error) {
      g_warning("[AudioTap] Failed to send audio data: %s", error->message);
      g_error_free(error);
    }
  }
  g_free(audio->data);
  delete audio;
  return G_SOURCE_REMOVE;
}

// Stream read callback — called from the PA threaded mainloop thread.
// NOTE: The PA lock is already held when this callback fires (PA guarantees
// this for threaded mainloop callbacks).  We must not call any blocking PA
// functions inside; just peek, copy, and schedule GLib delivery.
static void stream_read_cb(pa_stream* s, size_t nbytes, void* userdata) {
  const void* data = nullptr;
  size_t bytes_read = 0;

  if (pa_stream_peek(s, &data, &bytes_read) < 0) {
    g_warning("[AudioTap] Failed to read from stream: %s",
              pa_strerror(pa_context_errno(g_context)));
    return;
  }

  const uint8_t* processed_data = (const uint8_t*)data;
  size_t processed_bytes = bytes_read;

  g_suppress_diag_count++;
  if (g_suppress_diag_count <= 5 || g_suppress_diag_count % 50 == 0) {
    g_debug("[AudioTap] capture check #%lld: bytes=%zu",
            (long long)g_suppress_diag_count,
            processed_bytes);
  }

  if (processed_data && processed_bytes > 0 && g_tap_channel_instance && g_tap_channel_instance->event_listening) {
    AudioData* audio = new AudioData();
    audio->data = (uint8_t*)g_malloc(processed_bytes);
    memcpy(audio->data, processed_data, processed_bytes);
    audio->size = processed_bytes;
    g_idle_add(send_audio_idle, audio);
  }

  pa_stream_drop(s);
}

// Stream state callback (shared by capture and playback streams).
static void stream_state_cb(pa_stream* s, void* userdata) {
  switch (pa_stream_get_state(s)) {
    case PA_STREAM_READY:
      g_debug("[AudioTap] Stream ready");
      // Signal so anyone waiting for playback ready can proceed.
      g_playback_ready = TRUE;
      pa_threaded_mainloop_signal(g_threaded_ml, 0);
      break;
    case PA_STREAM_FAILED:
    case PA_STREAM_TERMINATED:
      g_warning("[AudioTap] Stream failed/terminated");
      g_is_capturing = FALSE;
      g_playback_ready = FALSE;
      pa_threaded_mainloop_signal(g_threaded_ml, 0);
      break;
    default:
      break;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PulseAudio init / cleanup (thread-safe via pa_threaded_mainloop)
// ═══════════════════════════════════════════════════════════════════════════════

static gboolean pulse_audio_init() {
  if (g_context != nullptr && g_context_ready) {
    return TRUE;  // Already initialized and ready
  }

  // If a previous init left a broken state, clean up first.
  if (g_threaded_ml != nullptr && g_context != nullptr && !g_context_ready) {
    pulse_audio_cleanup();  // defined below — safe to call conditionally
  }

  g_debug("[AudioTap] Using playback-aware echo suppression instead of WebRTC AEC");

  g_threaded_ml = pa_threaded_mainloop_new();
  if (!g_threaded_ml) {
    g_warning("[AudioTap] Failed to create threaded PulseAudio mainloop");
    return FALSE;
  }

  pa_mainloop_api* api = pa_threaded_mainloop_get_api(g_threaded_ml);
  g_context = pa_context_new(api, "phonegentic-audio-tap");
  if (!g_context) {
    g_warning("[AudioTap] Failed to create PulseAudio context");
    pa_threaded_mainloop_free(g_threaded_ml);
    g_threaded_ml = nullptr;
    return FALSE;
  }

  pa_context_set_state_callback(g_context, context_state_cb, nullptr);

  // Start the threaded mainloop BEFORE connecting — the context state callback
  // will fire on the mainloop thread and signal the condvar.
  if (pa_threaded_mainloop_start(g_threaded_ml) < 0) {
    g_warning("[AudioTap] Failed to start threaded mainloop");
    pa_context_unref(g_context);
    g_context = nullptr;
    pa_threaded_mainloop_free(g_threaded_ml);
    g_threaded_ml = nullptr;
    return FALSE;
  }

  // Connect to PulseAudio server (must hold the lock).
  pa_threaded_mainloop_lock(g_threaded_ml);

  if (pa_context_connect(g_context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
    g_warning("[AudioTap] Failed to connect to PulseAudio: %s",
              pa_strerror(pa_context_errno(g_context)));
    pa_threaded_mainloop_unlock(g_threaded_ml);
    pa_threaded_mainloop_stop(g_threaded_ml);
    pa_context_unref(g_context);
    g_context = nullptr;
    pa_threaded_mainloop_free(g_threaded_ml);
    g_threaded_ml = nullptr;
    return FALSE;
  }

  // Wait for the context to become READY (signalled by context_state_cb).
  g_context_ready = FALSE;
  while (!g_context_ready) {
    pa_threaded_mainloop_wait(g_threaded_ml);
    if (!g_context_ready) {
      pa_context_state_t state = pa_context_get_state(g_context);
      if (!PA_CONTEXT_IS_GOOD(state)) {
        g_warning("[AudioTap] PulseAudio connection failed: %s",
                  pa_strerror(pa_context_errno(g_context)));
        pa_threaded_mainloop_unlock(g_threaded_ml);
        pa_threaded_mainloop_stop(g_threaded_ml);
        pa_context_unref(g_context);
        g_context = nullptr;
        pa_threaded_mainloop_free(g_threaded_ml);
        g_threaded_ml = nullptr;
        return FALSE;
      }
    }
  }

  pa_threaded_mainloop_unlock(g_threaded_ml);
  g_debug("[AudioTap] PulseAudio initialized (threaded mainloop)");
  return TRUE;
}

static void pulse_audio_cleanup() {
  // Stop capturing first.
  g_is_capturing = FALSE;

  if (!g_threaded_ml) return;

  pa_threaded_mainloop_lock(g_threaded_ml);

  if (g_capture_stream) {
    pa_stream_disconnect(g_capture_stream);
    pa_stream_unref(g_capture_stream);
    g_capture_stream = nullptr;
  }

  if (g_playback_stream) {
    pa_stream_disconnect(g_playback_stream);
    pa_stream_unref(g_playback_stream);
    g_playback_stream = nullptr;
  }

  if (g_context) {
    pa_context_disconnect(g_context);
    pa_context_unref(g_context);
    g_context = nullptr;
  }

  g_context_ready = FALSE;
  g_playback_ready = FALSE;

  pa_threaded_mainloop_unlock(g_threaded_ml);

  // Stop the mainloop thread and free resources.
  pa_threaded_mainloop_stop(g_threaded_ml);
  pa_threaded_mainloop_free(g_threaded_ml);
  g_threaded_ml = nullptr;

  g_suppress_diag_count = 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Audio capture
// ═══════════════════════════════════════════════════════════════════════════════

static FlMethodResponse* start_capture() {
  if (g_is_capturing) {
    g_debug("[AudioTap] Already capturing");
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (!pulse_audio_init()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "PULSEAUDIO_ERROR", "Failed to initialize PulseAudio", nullptr));
  }

  pa_threaded_mainloop_lock(g_threaded_ml);

  // Create audio specification
  pa_sample_spec sample_spec;
  sample_spec.format = PA_SAMPLE_S16LE;
  sample_spec.rate = kTargetSampleRate;
  sample_spec.channels = kChannels;

  // Create stream
  g_capture_stream = pa_stream_new(g_context, "audio_tap_capture", &sample_spec, nullptr);
  if (!g_capture_stream) {
    pa_threaded_mainloop_unlock(g_threaded_ml);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "STREAM_ERROR", "Failed to create stream", nullptr));
  }

  pa_stream_set_state_callback(g_capture_stream, stream_state_cb, nullptr);
  pa_stream_set_read_callback(g_capture_stream, stream_read_cb, nullptr);

  // Connect to default source (microphone)
  pa_buffer_attr buffer_attr;
  buffer_attr.maxlength = (uint32_t)-1;
  buffer_attr.tlength = (uint32_t)-1;
  buffer_attr.prebuf = (uint32_t)-1;
  buffer_attr.minreq = (uint32_t)-1;
  buffer_attr.fragsize = kChunkSize;

  if (pa_stream_connect_record(g_capture_stream, nullptr, &buffer_attr, PA_STREAM_ADJUST_LATENCY) < 0) {
    g_warning("[AudioTap] Failed to connect record stream: %s",
              pa_strerror(pa_context_errno(g_context)));
    pa_stream_unref(g_capture_stream);
    g_capture_stream = nullptr;
    pa_threaded_mainloop_unlock(g_threaded_ml);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "CONNECT_ERROR", "Failed to connect stream", nullptr));
  }

  g_is_capturing = TRUE;
  pa_threaded_mainloop_unlock(g_threaded_ml);

  // Reset suppression state on capture start
  g_suppress_diag_count = 0;

  g_debug("[AudioTap] Audio capture started");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* stop_capture() {
  if (!g_is_capturing) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (g_threaded_ml) {
    pa_threaded_mainloop_lock(g_threaded_ml);
  }

  if (g_capture_stream) {
    pa_stream_disconnect(g_capture_stream);
    pa_stream_unref(g_capture_stream);
    g_capture_stream = nullptr;
  }

  g_is_capturing = FALSE;

  if (g_threaded_ml) {
    pa_threaded_mainloop_unlock(g_threaded_ml);
  }

  g_debug("[AudioTap] Audio capture stopped");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Audio playback
// ═══════════════════════════════════════════════════════════════════════════════

static gboolean notify_playback_complete_idle(gpointer user_data) {
  if (g_tap_channel_instance && g_tap_channel_instance->channel) {
    fl_method_channel_invoke_method(g_tap_channel_instance->channel,
                                    "onPlaybackComplete", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return G_SOURCE_REMOVE;
}

static void stream_underflow_cb(pa_stream* s, void* userdata) {
  g_debug("[AudioTap] Playback stream underflow - playback complete");
  // Schedule on GLib main thread — do NOT call Flutter from PA thread directly.
  g_idle_add(notify_playback_complete_idle, nullptr);
}

// Playback stream write callback — PulseAudio requests more data.
static void stream_write_cb(pa_stream* s, size_t nbytes, void* userdata) {
  // No-op: we push data via play_audio_response() instead of letting PA pull.
}

/// Play audio response — called from the Flutter/GLib thread.
/// All PA operations are serialised with the threaded mainloop lock.
static FlMethodResponse* play_audio_response(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGUMENT", "Expected Uint8List", nullptr));
  }

  const uint8_t* data = fl_value_get_uint8_list(args);
  size_t length = fl_value_get_length(args);

  if (length == 0) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  // Initialize PulseAudio if not already initialized
  if (!g_context || !g_context_ready) {
    if (!pulse_audio_init()) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "PULSEAUDIO_ERROR", "Failed to initialize PulseAudio", nullptr));
    }
  }

  pa_threaded_mainloop_lock(g_threaded_ml);

  // Create playback stream if it doesn't exist
  if (!g_playback_stream) {
    pa_sample_spec sample_spec;
    sample_spec.format = PA_SAMPLE_S16LE;
    sample_spec.rate = kTargetSampleRate;
    sample_spec.channels = kChannels;

    g_playback_stream = pa_stream_new(g_context, "audio_tap_playback", &sample_spec, nullptr);
    if (!g_playback_stream) {
      pa_threaded_mainloop_unlock(g_threaded_ml);
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "STREAM_ERROR", "Failed to create playback stream", nullptr));
    }

    pa_stream_set_state_callback(g_playback_stream, stream_state_cb, nullptr);
    pa_stream_set_write_callback(g_playback_stream, stream_write_cb, nullptr);
    pa_stream_set_underflow_callback(g_playback_stream, stream_underflow_cb, nullptr);

    // Connect to default sink (speaker)
    pa_buffer_attr buffer_attr;
    buffer_attr.maxlength = (uint32_t)-1;
    buffer_attr.tlength = (uint32_t)-1;
    buffer_attr.prebuf = (uint32_t)-1;
    buffer_attr.minreq = (uint32_t)-1;
    buffer_attr.fragsize = (uint32_t)-1;

    g_playback_ready = FALSE;

    if (pa_stream_connect_playback(g_playback_stream, nullptr, &buffer_attr,
                                   PA_STREAM_ADJUST_LATENCY, nullptr, nullptr) < 0) {
      g_warning("[AudioTap] Failed to connect playback stream: %s",
                pa_strerror(pa_context_errno(g_context)));
      pa_stream_unref(g_playback_stream);
      g_playback_stream = nullptr;
      pa_threaded_mainloop_unlock(g_threaded_ml);
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "CONNECT_ERROR", "Failed to connect playback stream", nullptr));
    }

    // Wait for the playback stream to become READY (signalled by stream_state_cb).
    while (!g_playback_ready) {
      pa_threaded_mainloop_wait(g_threaded_ml);
      if (!g_playback_ready) {
        pa_stream_state_t stream_state = pa_stream_get_state(g_playback_stream);
        if (!PA_STREAM_IS_GOOD(stream_state)) {
          g_warning("[AudioTap] Playback stream connection failed: %s",
                    pa_strerror(pa_context_errno(g_context)));
          pa_stream_unref(g_playback_stream);
          g_playback_stream = nullptr;
          pa_threaded_mainloop_unlock(g_threaded_ml);
          return FL_METHOD_RESPONSE(fl_method_error_response_new(
              "CONNECT_ERROR", "Playback stream failed to become ready", nullptr));
        }
      }
    }

    g_debug("[AudioTap] Playback stream created and connected");
  }

  // Write audio data to the stream
  int result = pa_stream_write(g_playback_stream, data, length, nullptr, 0, PA_SEEK_RELATIVE);
  if (result < 0) {
    g_warning("[AudioTap] Failed to write audio data: %s",
              pa_strerror(pa_context_errno(g_context)));
    pa_threaded_mainloop_unlock(g_threaded_ml);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "WRITE_ERROR", "Failed to write audio data", nullptr));
  }

  pa_threaded_mainloop_unlock(g_threaded_ml);

  g_debug("[AudioTap] Wrote %zu bytes to playback stream", length);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Stop audio playback
static FlMethodResponse* stop_audio_playback() {
  if (!g_playback_stream && !g_threaded_ml) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (g_threaded_ml) {
    pa_threaded_mainloop_lock(g_threaded_ml);
  }

  if (g_playback_stream) {
    pa_stream_disconnect(g_playback_stream);
    pa_stream_unref(g_playback_stream);
    g_playback_stream = nullptr;
    g_playback_ready = FALSE;
  }

  if (g_threaded_ml) {
    pa_threaded_mainloop_unlock(g_threaded_ml);
  }

  g_debug("[AudioTap] Playback stopped");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Stub implementations for speaker identification (not implemented on Linux)
// ═══════════════════════════════════════════════════════════════════════════════

static FlMethodResponse* init_speaker_identifier() {
  g_debug("[AudioTap] initSpeakerIdentifier - not implemented on Linux");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* load_known_speakers() {
  g_debug("[AudioTap] loadKnownSpeakers - not implemented on Linux");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* reset_speaker_identifier() {
  g_debug("[AudioTap] resetSpeakerIdentifier - not implemented on Linux");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* get_remote_speaker_embedding() {
  g_debug("[AudioTap] getRemoteSpeakerEmbedding - not implemented on Linux");
  g_autoptr(FlValue) result = fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* get_dominant_speaker() {
  g_debug("[AudioTap] getDominantSpeaker - not implemented on Linux");
  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string(result, "source", fl_value_new_string("unknown"));
  fl_value_set_string(result, "identity", fl_value_new_string(""));
  fl_value_set_string(result, "confidence", fl_value_new_float(0.0));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Method call dispatcher
// ═══════════════════════════════════════════════════════════════════════════════

static void method_call_handler(FlMethodChannel* channel, FlMethodCall* method_call,
                                gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);

  g_debug("[AudioTap] Method called: %s", method);

  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, kMethodStartAudioTap) == 0) {
    response = start_capture();
  } else if (strcmp(method, kMethodStopAudioTap) == 0) {
    response = stop_capture();
  } else if (strcmp(method, kMethodPlayAudioResponse) == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    response = play_audio_response(args);
  } else if (strcmp(method, kMethodStopAudioPlayback) == 0) {
    response = stop_audio_playback();
  } else if (strcmp(method, kMethodInitSpeakerIdentifier) == 0) {
    response = init_speaker_identifier();
  } else if (strcmp(method, kMethodLoadKnownSpeakers) == 0) {
    response = load_known_speakers();
  } else if (strcmp(method, kMethodRegisterHostSpeaker) == 0) {
    g_debug("[AudioTap] registerHostSpeaker - not implemented on Linux");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, kMethodGetHostSpeakerEmbedding) == 0) {
    g_debug("[AudioTap] getHostSpeakerEmbedding - not implemented on Linux");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, kMethodResetSpeakerIdentifier) == 0) {
    response = reset_speaker_identifier();
  } else if (strcmp(method, kMethodGetRemoteSpeakerEmbedding) == 0) {
    response = get_remote_speaker_embedding();
  } else if (strcmp(method, kMethodGetDominantSpeaker) == 0) {
    response = get_dominant_speaker();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// ═══════════════════════════════════════════════════════════════════════════════
// EventChannel handlers
// ═══════════════════════════════════════════════════════════════════════════════

static FlMethodErrorResponse* on_listen_cb(FlEventChannel* channel, FlValue* args,
                                         gpointer user_data) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(user_data);
  self->event_listening = TRUE;
  g_tap_channel_instance = self;
  g_debug("[AudioTap] Event channel listening");
  return nullptr;
}

static FlMethodErrorResponse* on_cancel_cb(FlEventChannel* channel, FlValue* args,
                                         gpointer user_data) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(user_data);
  self->event_listening = FALSE;
  g_debug("[AudioTap] Event channel cancelled");
  return nullptr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// GObject lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

static void audio_tap_channel_dispose(GObject* object) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(object);

  g_debug("[AudioTap] Disposing channel");

  stop_capture();
  pulse_audio_cleanup();

  if (g_tap_channel_instance == self) {
    g_tap_channel_instance = nullptr;
  }

  g_clear_object(&self->channel);
  g_clear_object(&self->event_channel);

  G_OBJECT_CLASS(audio_tap_channel_parent_class)->dispose(object);
}

static void audio_tap_channel_class_init(AudioTapChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = audio_tap_channel_dispose;
}

static void audio_tap_channel_init(AudioTapChannel* self) {
  self->channel = nullptr;
  self->event_channel = nullptr;
  self->event_listening = FALSE;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Public API
// ═══════════════════════════════════════════════════════════════════════════════

AudioTapChannel* audio_tap_channel_new(FlBinaryMessenger* messenger) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(g_object_new(audio_tap_channel_get_type(), nullptr));

  FlStandardMethodCodec* codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));

  if (self->channel) {
    fl_method_channel_set_method_call_handler(self->channel, method_call_handler, self, nullptr);
  }

  // Create event channel for streaming audio data
  self->event_channel = fl_event_channel_new(messenger, kEventChannelName, FL_METHOD_CODEC(codec));

  if (self->event_channel) {
    fl_event_channel_set_stream_handlers(
        self->event_channel,
        on_listen_cb,
        on_cancel_cb,
        self,
        nullptr);
  }

  // Release the local codec ref — the channels hold their own refs.
  g_clear_object(&codec);

  g_debug("[AudioTap] AudioTapChannel created");
  return self;
}

void audio_tap_channel_dispose(AudioTapChannel* self) {
  if (self) {
    g_clear_object(&self->channel);
    g_clear_object(&self->event_channel);
    pulse_audio_cleanup();
  }
}
