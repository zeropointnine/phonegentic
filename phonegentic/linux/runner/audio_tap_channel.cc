#include "audio_tap_channel.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <pulse/pulseaudio.h>
#include <string.h>
#include <pthread.h>
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

// PulseAudio context and stream for audio capture
static pa_mainloop* g_mainloop = nullptr;
static pa_context* g_context = nullptr;
static pa_stream* g_capture_stream = nullptr;
static pa_stream* g_playback_stream = nullptr;
static gboolean g_is_capturing = FALSE;
static gboolean g_mainloop_running = FALSE;
static pthread_t g_mainloop_thread;
static AudioTapChannel* g_tap_channel_instance = nullptr;

static int64_t g_suppress_diag_count = 0;

// Forward declarations
static void audio_tap_channel_dispose(GObject* object);
static void audio_tap_channel_class_init(AudioTapChannelClass* klass);
static void audio_tap_channel_init(AudioTapChannel* self);

// PulseAudio context state callback
static void context_state_cb(pa_context* c, void* userdata) {
  switch (pa_context_get_state(c)) {
    case PA_CONTEXT_READY:
      g_debug("[AudioTap] PulseAudio context ready");
      break;
    case PA_CONTEXT_FAILED:
    case PA_CONTEXT_TERMINATED:
      g_warning("[AudioTap] PulseAudio context failed/terminated");
      g_mainloop_running = FALSE;
      break;
    default:
      break;
  }
}

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

// Stream read callback - called when audio data is available
static void stream_read_cb(pa_stream* s, size_t nbytes, void* userdata) {
  const void* data = nullptr;
  size_t bytes_read = 0;

  if (pa_stream_peek(s, &data, &bytes_read) < 0) {
    g_warning("[AudioTap] Failed to read from stream: %s",
              pa_strerror(pa_context_errno(g_context)));
    return;
  }

  // Audio data for processing
  const uint8_t* processed_data = (const uint8_t*)data;
  size_t processed_bytes = bytes_read;

  // Log periodically
  g_suppress_diag_count++;
  if (g_suppress_diag_count <= 5 || g_suppress_diag_count % 50 == 0) {
    g_debug("[AudioTap] capture check #%lld: bytes=%zu",
            (long long)g_suppress_diag_count,
            processed_bytes);
  }

  // Send audio data to Flutter if event channel is listening
  if (processed_data && processed_bytes > 0 && g_tap_channel_instance && g_tap_channel_instance->event_listening) {
    AudioData* audio = new AudioData();
    audio->data = (uint8_t*)g_malloc(processed_bytes);
    memcpy(audio->data, processed_data, processed_bytes);
    audio->size = processed_bytes;
    g_idle_add(send_audio_idle, audio);
  }

  // Consume the data
  pa_stream_drop(s);
}

// Stream state callback
static void stream_state_cb(pa_stream* s, void* userdata) {
  switch (pa_stream_get_state(s)) {
    case PA_STREAM_READY:
      g_debug("[AudioTap] Capture stream ready");
      break;
    case PA_STREAM_FAILED:
    case PA_STREAM_TERMINATED:
      g_warning("[AudioTap] Capture stream failed/terminated");
      g_is_capturing = FALSE;
      break;
    default:
      break;
  }
}

// Mainloop thread function - runs PulseAudio event loop
static void* mainloop_thread_func(void* userdata) {
  g_debug("[AudioTap] Mainloop thread started");

  while (g_mainloop_running && g_mainloop) {
    pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
  }

  g_debug("[AudioTap] Mainloop thread exiting");
  return nullptr;
}

// Initialize PulseAudio connection
static gboolean pulse_audio_init() {
  if (g_context != nullptr) {
    return TRUE;  // Already initialized
  }

  // Note: WebRTC AEC disabled on Linux due to API compatibility.
  // Playback-aware echo suppression (g_last_tts_time_ms) handles echo instead.
  g_debug("[AudioTap] Using playback-aware echo suppression instead of WebRTC AEC");

  g_mainloop = pa_mainloop_new();
  if (!g_mainloop) {
    g_warning("[AudioTap] Failed to create PulseAudio mainloop");
    return FALSE;
  }

  pa_mainloop_api* api = pa_mainloop_get_api(g_mainloop);
  g_context = pa_context_new(api, "phonegentic-audio-tap");
  if (!g_context) {
    g_warning("[AudioTap] Failed to create PulseAudio context");
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
    return FALSE;
  }

  pa_context_set_state_callback(g_context, context_state_cb, nullptr);

  // Connect to PulseAudio server
  if (pa_context_connect(g_context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
    g_warning("[AudioTap] Failed to connect to PulseAudio: %s",
              pa_strerror(pa_context_errno(g_context)));
    pa_context_unref(g_context);
    g_context = nullptr;
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
    return FALSE;
  }

  // Wait for context to be ready
  pa_context_state_t state;
  int iterations = 0;
  while (iterations < 100) {  // Timeout after ~10 seconds
    pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    state = pa_context_get_state(g_context);
    if (state == PA_CONTEXT_READY) {
      break;
    }
    if (!PA_CONTEXT_IS_GOOD(state)) {
      g_warning("[AudioTap] PulseAudio connection failed: %s",
                pa_strerror(pa_context_errno(g_context)));
      pa_context_disconnect(g_context);
      pa_context_unref(g_context);
      g_context = nullptr;
      pa_mainloop_free(g_mainloop);
      g_mainloop = nullptr;
      return FALSE;
    }
    iterations++;
    g_usleep(100000);  // 100ms
  }

  // Start the mainloop thread
  g_mainloop_running = TRUE;
  if (pthread_create(&g_mainloop_thread, nullptr, mainloop_thread_func, nullptr) != 0) {
    g_warning("[AudioTap] Failed to create mainloop thread");
    g_mainloop_running = FALSE;
    pa_context_disconnect(g_context);
    pa_context_unref(g_context);
    g_context = nullptr;
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
    return FALSE;
  }

  return TRUE;
}

// Cleanup PulseAudio connection
static void pulse_audio_cleanup() {
  g_is_capturing = FALSE;
  g_mainloop_running = FALSE;

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

  if (g_mainloop) {
    // Wait for mainloop thread to finish
    if (pthread_join(g_mainloop_thread, nullptr) == 0) {
      g_debug("[AudioTap] Mainloop thread joined");
    }
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
  }

  // Reset suppression state
  g_suppress_diag_count = 0;
}

// Start audio capture
static FlMethodResponse* start_capture() {
  if (g_is_capturing) {
    g_debug("[AudioTap] Already capturing");
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (!pulse_audio_init()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "PULSEAUDIO_ERROR", "Failed to initialize PulseAudio", nullptr));
  }

  // Create audio specification
  pa_sample_spec sample_spec;
  sample_spec.format = PA_SAMPLE_S16LE;
  sample_spec.rate = kTargetSampleRate;
  sample_spec.channels = kChannels;

  // Create stream
  g_capture_stream = pa_stream_new(g_context, "audio_tap_capture", &sample_spec, nullptr);
  if (!g_capture_stream) {
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
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "CONNECT_ERROR", "Failed to connect stream", nullptr));
  }

  // Reset suppression state on capture start
  g_suppress_diag_count = 0;

  g_is_capturing = TRUE;
  g_debug("[AudioTap] Audio capture started");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Stop audio capture
static FlMethodResponse* stop_capture() {
  if (!g_is_capturing) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  if (g_capture_stream) {
    pa_stream_disconnect(g_capture_stream);
    pa_stream_unref(g_capture_stream);
    g_capture_stream = nullptr;
  }

  g_is_capturing = FALSE;
  g_debug("[AudioTap] Audio capture stopped");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

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
  g_idle_add(notify_playback_complete_idle, nullptr);
}

// Playback stream write callback
static void stream_write_cb(pa_stream* s, size_t nbytes, void* userdata) {
  // This is called when PulseAudio is ready for more data
  // We don't need to do anything here as we write data directly
}

// Play audio response
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
  if (!g_context) {
    if (!pulse_audio_init()) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "PULSEAUDIO_ERROR", "Failed to initialize PulseAudio", nullptr));
    }
  }

  // Create playback stream if it doesn't exist
  if (!g_playback_stream) {
    pa_sample_spec sample_spec;
    sample_spec.format = PA_SAMPLE_S16LE;
    sample_spec.rate = kTargetSampleRate;
    sample_spec.channels = kChannels;

    g_playback_stream = pa_stream_new(g_context, "audio_tap_playback", &sample_spec, nullptr);
    if (!g_playback_stream) {
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

    if (pa_stream_connect_playback(g_playback_stream, nullptr, &buffer_attr,
                                   PA_STREAM_ADJUST_LATENCY, nullptr, nullptr) < 0) {
      g_warning("[AudioTap] Failed to connect playback stream: %s",
                pa_strerror(pa_context_errno(g_context)));
      pa_stream_unref(g_playback_stream);
      g_playback_stream = nullptr;
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "CONNECT_ERROR", "Failed to connect playback stream", nullptr));
    }

    // Wait for playback stream to become ready before writing data.
    // pa_stream_connect_playback() is asynchronous — the stream must
    // transition to PA_STREAM_READY before pa_stream_write() can succeed.
    // Without this wait, the first audio chunk fails with "Bad state".
    pa_stream_state_t stream_state;
    int wait_iterations = 0;
    while (wait_iterations < 100) {
      stream_state = pa_stream_get_state(g_playback_stream);
      if (stream_state == PA_STREAM_READY) {
        break;
      }
      if (!PA_STREAM_IS_GOOD(stream_state)) {
        g_warning("[AudioTap] Playback stream connection failed: %s",
                  pa_strerror(pa_context_errno(g_context)));
        pa_stream_unref(g_playback_stream);
        g_playback_stream = nullptr;
        return FL_METHOD_RESPONSE(fl_method_error_response_new(
            "CONNECT_ERROR", "Playback stream failed to become ready", nullptr));
      }
      // Sleep briefly — the dedicated mainloop thread processes state
      // transitions. We must NOT call pa_mainloop_iterate() here because
      // the mainloop thread is already iterating it (pa_mainloop is not
      // thread-safe).
      g_usleep(10000);  // 10ms
      wait_iterations++;
    }

    if (pa_stream_get_state(g_playback_stream) != PA_STREAM_READY) {
      g_warning("[AudioTap] Playback stream timed out waiting for READY state");
      pa_stream_unref(g_playback_stream);
      g_playback_stream = nullptr;
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "CONNECT_ERROR", "Playback stream timed out", nullptr));
    }

    g_debug("[AudioTap] Playback stream created and connected");
  }

  // Write audio data to the stream
  int result = pa_stream_write(g_playback_stream, data, length, nullptr, 0, PA_SEEK_RELATIVE);
  if (result < 0) {
    g_warning("[AudioTap] Failed to write audio data: %s",
              pa_strerror(pa_context_errno(g_context)));
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "WRITE_ERROR", "Failed to write audio data", nullptr));
  }

  g_debug("[AudioTap] Wrote %zu bytes to playback stream", length);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Stop audio playback
static FlMethodResponse* stop_audio_playback() {
  if (!g_playback_stream) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  pa_stream_disconnect(g_playback_stream);
  pa_stream_unref(g_playback_stream);
  g_playback_stream = nullptr;
  g_debug("[AudioTap] Playback stopped");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Stub implementations for speaker identification methods (not implemented on Linux yet)
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

// Method call handler
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

// Event channel stream handler - onListen
static FlMethodErrorResponse* on_listen_cb(FlEventChannel* channel, FlValue* args,
                                         gpointer user_data) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(user_data);
  self->event_listening = TRUE;
  g_tap_channel_instance = self;
  g_debug("[AudioTap] Event channel listening");
  return nullptr;
}

// Event channel stream handler - onCancel
static FlMethodErrorResponse* on_cancel_cb(FlEventChannel* channel, FlValue* args,
                                         gpointer user_data) {
  AudioTapChannel* self = AUDIO_TAP_CHANNEL(user_data);
  self->event_listening = FALSE;
  g_debug("[AudioTap] Event channel cancelled");
  return nullptr;
}

// Dispose implementation
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

// Class initialization
static void audio_tap_channel_class_init(AudioTapChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = audio_tap_channel_dispose;
}

// Instance initialization
static void audio_tap_channel_init(AudioTapChannel* self) {
  self->channel = nullptr;
  self->event_channel = nullptr;
  self->event_listening = FALSE;
}

// Create a new AudioTapChannel
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

  g_debug("[AudioTap] AudioTapChannel created");
  return self;
}

// Dispose function (public)
void audio_tap_channel_dispose(AudioTapChannel* self) {
  if (self) {
    g_clear_object(&self->channel);
    g_clear_object(&self->event_channel);
    pulse_audio_cleanup();
  }
}
