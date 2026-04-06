#include "audio_device_channel.h"

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <pulse/pulseaudio.h>
#include <string.h>

// Channel name - must match the macOS implementation
static const char* kChannelName = "com.agentic_ai/audio_devices";

// Method names
static const char* kMethodGetAudioDevices = "getAudioDevices";
static const char* kMethodSetDefaultInputDevice = "setDefaultInputDevice";
static const char* kMethodSetDefaultOutputDevice = "setDefaultOutputDevice";

// Device property keys
static const char* kKeyId = "id";
static const char* kKeyName = "name";
static const char* kKeyType = "type";
static const char* kKeyIsDefaultInput = "isDefaultInput";
static const char* kKeyIsDefaultOutput = "isDefaultOutput";
static const char* kKeyUid = "uid";
static const char* kKeyManufacturer = "manufacturer";
static const char* kKeyTransportType = "transportType";

// Transport types
static const char* kTransportTypeUnknown = "unknown";
static const char* kTransportTypeUsb = "usb";
static const char* kTransportTypeBluetooth = "bluetooth";
static const char* kTransportTypeBuiltIn = "built-in";
static const char* kTransportTypeHdmi = "hdmi";

// Device types
static const char* kTypeInput = "input";
static const char* kTypeOutput = "output";
static const char* kTypeBoth = "both";

// Device types
typedef enum {
  DEVICE_TYPE_INPUT,
  DEVICE_TYPE_OUTPUT,
  DEVICE_TYPE_BOTH
} DeviceType;

// Audio device info
typedef struct {
  guint32 id;
  gchar* name;
  gchar* uid;
  gchar* manufacturer;
  gchar* transport_type;
  DeviceType type;
  gboolean is_default_input;
  gboolean is_default_output;
} AudioDeviceInfo;

// AudioDeviceChannel structure
struct _AudioDeviceChannel {
  GObject parent_instance;
  FlMethodChannel* channel;
};

struct _AudioDeviceChannelClass {
  GObjectClass parent_class;
};

G_DEFINE_TYPE(AudioDeviceChannel, audio_device_channel, G_TYPE_OBJECT)

// Forward declarations
static void audio_device_channel_dispose(GObject* object);
static void audio_device_channel_class_init(AudioDeviceChannelClass* klass);
static void audio_device_channel_init(AudioDeviceChannel* self);

// PulseAudio context and mainloop for synchronous operations
static pa_mainloop* g_mainloop = nullptr;
static pa_context* g_context = nullptr;

// Initialize PulseAudio connection
static gboolean pulse_audio_init() {
  if (g_context != nullptr) {
    return TRUE;  // Already initialized
  }

  g_mainloop = pa_mainloop_new();
  if (!g_mainloop) {
    g_warning("Failed to create PulseAudio mainloop");
    return FALSE;
  }

  pa_mainloop_api* api = pa_mainloop_get_api(g_mainloop);
  g_context = pa_context_new(api, "phonegentic-audio-channel");
  if (!g_context) {
    g_warning("Failed to create PulseAudio context");
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
    return FALSE;
  }

  // Connect to PulseAudio server
  if (pa_context_connect(g_context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
    g_warning("Failed to connect to PulseAudio: %s", pa_strerror(pa_context_errno(g_context)));
    pa_context_unref(g_context);
    g_context = nullptr;
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
    return FALSE;
  }

  // Wait for context to be ready
  pa_context_state_t state;
  while (TRUE) {
    pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    state = pa_context_get_state(g_context);
    if (state == PA_CONTEXT_READY) {
      break;
    }
    if (!PA_CONTEXT_IS_GOOD(state)) {
      g_warning("PulseAudio connection failed: %s", pa_strerror(pa_context_errno(g_context)));
      pa_context_unref(g_context);
      g_context = nullptr;
      pa_mainloop_free(g_mainloop);
      g_mainloop = nullptr;
      return FALSE;
    }
  }

  return TRUE;
}

// Cleanup PulseAudio connection
static void pulse_audio_cleanup() {
  if (g_context) {
    pa_context_disconnect(g_context);
    pa_context_unref(g_context);
    g_context = nullptr;
  }
  if (g_mainloop) {
    pa_mainloop_free(g_mainloop);
    g_mainloop = nullptr;
  }
}

// Get transport type from device properties
static const gchar* get_transport_type(pa_proplist* props) {
  if (!props) {
    return kTransportTypeUnknown;
  }

  const gchar* device_bus = pa_proplist_gets(props, PA_PROP_DEVICE_BUS);
  const gchar* device_bus_path = pa_proplist_gets(props, PA_PROP_DEVICE_BUS_PATH);
  const gchar* device_form_factor = pa_proplist_gets(props, PA_PROP_DEVICE_FORM_FACTOR);

  // Check for USB
  if (device_bus && strcmp(device_bus, "usb") == 0) {
    return kTransportTypeUsb;
  }
  if (device_bus_path && strstr(device_bus_path, "usb")) {
    return kTransportTypeUsb;
  }

  // Check for Bluetooth
  if (device_bus && strcmp(device_bus, "bluetooth") == 0) {
    return kTransportTypeBluetooth;
  }

  // Check for built-in
  if (device_form_factor && strcmp(device_form_factor, "internal") == 0) {
    return kTransportTypeBuiltIn;
  }

  // Check for HDMI
  if (device_form_factor && strcmp(device_form_factor, "hdmi") == 0) {
    return kTransportTypeHdmi;
  }

  return kTransportTypeUnknown;
}

// Get manufacturer from device properties
static gchar* get_manufacturer(pa_proplist* props) {
  if (!props) {
    return g_strdup("");
  }

  const gchar* vendor = pa_proplist_gets(props, PA_PROP_DEVICE_VENDOR_NAME);
  const gchar* product = pa_proplist_gets(props, PA_PROP_DEVICE_PRODUCT_NAME);

  if (vendor && product) {
    return g_strdup_printf("%s %s", vendor, product);
  } else if (vendor) {
    return g_strdup(vendor);
  } else if (product) {
    return g_strdup(product);
  }

  return g_strdup("");
}

// Callback for sink info (output devices)
typedef struct {
  GList* devices;
  gchar* default_sink_name;
} SinkCallbackData;

static void sink_info_callback(pa_context* c, const pa_sink_info* i, int eol, void* userdata) {
  SinkCallbackData* data = static_cast<SinkCallbackData*>(userdata);

  if (eol < 0) {
    g_warning("Failed to get sink info: %s", pa_strerror(pa_context_errno(c)));
    return;
  }

  if (eol > 0) {
    return;  // End of list
  }

  AudioDeviceInfo* device = g_new0(AudioDeviceInfo, 1);
  device->id = i->index;
  device->name = g_strdup(i->name);
  device->uid = g_strdup(i->name);
  device->manufacturer = get_manufacturer(i->proplist);
  device->transport_type = g_strdup(get_transport_type(i->proplist));
  device->type = DEVICE_TYPE_OUTPUT;
  device->is_default_input = FALSE;
  device->is_default_output = (data->default_sink_name && strcmp(i->name, data->default_sink_name) == 0);

  data->devices = g_list_append(data->devices, device);
}

// Callback for source info (input devices)
typedef struct {
  GList* devices;
  gchar* default_source_name;
} SourceCallbackData;

static void source_info_callback(pa_context* c, const pa_source_info* i, int eol, void* userdata) {
  SourceCallbackData* data = static_cast<SourceCallbackData*>(userdata);

  if (eol < 0) {
    g_warning("Failed to get source info: %s", pa_strerror(pa_context_errno(c)));
    return;
  }

  if (eol > 0) {
    return;  // End of list
  }

  AudioDeviceInfo* device = g_new0(AudioDeviceInfo, 1);
  device->id = i->index;
  device->name = g_strdup(i->description ? i->description : i->name);
  device->uid = g_strdup(i->name);
  device->manufacturer = get_manufacturer(i->proplist);
  device->transport_type = g_strdup(get_transport_type(i->proplist));
  device->type = DEVICE_TYPE_INPUT;
  device->is_default_input = (data->default_source_name && strcmp(i->name, data->default_source_name) == 0);
  device->is_default_output = FALSE;

  data->devices = g_list_append(data->devices, device);
}

// Get default sink name (output)
typedef struct {
  gchar* default_sink_name;
  gchar* default_source_name;
} ServerInfoCallbackData;

static void server_info_callback(pa_context* c, const pa_server_info* i, void* userdata) {
  ServerInfoCallbackData* data = static_cast<ServerInfoCallbackData*>(userdata);
  if (i) {
    if (i->default_sink_name) {
      data->default_sink_name = g_strdup(i->default_sink_name);
    }
    if (i->default_source_name) {
      data->default_source_name = g_strdup(i->default_source_name);
    }
  }
}

// Free AudioDeviceInfo
static void audio_device_info_free(AudioDeviceInfo* device) {
  if (device) {
    g_free(device->name);
    g_free(device->uid);
    g_free(device->manufacturer);
    g_free(device->transport_type);
    g_free(device);
  }
}

// Convert AudioDeviceInfo to FlValue
static FlValue* audio_device_to_fl_value(AudioDeviceInfo* device) {
  g_autoptr(FlValue) map = fl_value_new_map();

  fl_value_set_string(map, kKeyId, fl_value_new_int(device->id));
  fl_value_set_string(map, kKeyName, fl_value_new_string(device->name));

  const gchar* type_str;
  switch (device->type) {
    case DEVICE_TYPE_INPUT:
      type_str = kTypeInput;
      break;
    case DEVICE_TYPE_OUTPUT:
      type_str = kTypeOutput;
      break;
    case DEVICE_TYPE_BOTH:
      type_str = kTypeBoth;
      break;
    default:
      type_str = kTypeOutput;
      break;
  }
  fl_value_set_string(map, kKeyType, fl_value_new_string(type_str));
  fl_value_set_string(map, kKeyIsDefaultInput, fl_value_new_bool(device->is_default_input));
  fl_value_set_string(map, kKeyIsDefaultOutput, fl_value_new_bool(device->is_default_output));
  fl_value_set_string(map, kKeyUid, fl_value_new_string(device->uid));
  fl_value_set_string(map, kKeyManufacturer, fl_value_new_string(device->manufacturer));
  fl_value_set_string(map, kKeyTransportType, fl_value_new_string(device->transport_type));

  return g_steal_pointer(&map);
}

// Get all audio devices
static FlMethodResponse* get_audio_devices() {
  if (!pulse_audio_init()) {
    g_warning("Failed to initialize PulseAudio");
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "PULSEAUDIO_ERROR", "Failed to connect to PulseAudio", nullptr));
  }

  // Get default sink and source names
  ServerInfoCallbackData server_data = {nullptr, nullptr};
  pa_operation* op = pa_context_get_server_info(g_context, server_info_callback, &server_data);
  if (op) {
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
      pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    }
    pa_operation_unref(op);
  }

  // Get output devices (sinks)
  SinkCallbackData sink_cb_data = {nullptr, server_data.default_sink_name};
  op = pa_context_get_sink_info_list(g_context, sink_info_callback, &sink_cb_data);
  if (op) {
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
      pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    }
    pa_operation_unref(op);
  }

  // Get input devices (sources)
  SourceCallbackData source_cb_data = {nullptr, server_data.default_source_name};
  op = pa_context_get_source_info_list(g_context, source_info_callback, &source_cb_data);
  if (op) {
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
      pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    }
    pa_operation_unref(op);
  }

  // Merge devices and create response
  g_autoptr(FlValue) devices_list = fl_value_new_list();

  // Add output devices
  for (GList* l = sink_cb_data.devices; l != nullptr; l = l->next) {
    AudioDeviceInfo* device = static_cast<AudioDeviceInfo*>(l->data);
    fl_value_append(devices_list, audio_device_to_fl_value(device));
  }

  // Add input devices
  for (GList* l = source_cb_data.devices; l != nullptr; l = l->next) {
    AudioDeviceInfo* device = static_cast<AudioDeviceInfo*>(l->data);
    fl_value_append(devices_list, audio_device_to_fl_value(device));
  }

  // Cleanup
  g_list_free_full(sink_cb_data.devices, (GDestroyNotify)audio_device_info_free);
  g_list_free_full(source_cb_data.devices, (GDestroyNotify)audio_device_info_free);
  g_free(server_data.default_sink_name);
  g_free(server_data.default_source_name);

  return FL_METHOD_RESPONSE(fl_method_success_response_new(devices_list));
}

// Set default input device
static FlMethodResponse* set_default_input_device(FlValue* args) {
  if (!pulse_audio_init()) {
    g_warning("Failed to initialize PulseAudio");
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "PULSEAUDIO_ERROR", "Failed to connect to PulseAudio", nullptr));
  }

  FlValue* device_id_value = fl_value_lookup_string(args, "deviceId");
  if (!device_id_value || fl_value_get_type(device_id_value) != FL_VALUE_TYPE_INT) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing or invalid deviceId", nullptr));
  }

  guint32 device_id = fl_value_get_int(device_id_value);

  // Get source info to get the source name
  typedef struct {
    gchar* source_name;
    guint32 target_id;
    gboolean found;
  } SourceNameCallbackData;

  SourceNameCallbackData name_data = {nullptr, device_id, FALSE};

  auto source_name_callback = [](pa_context* c, const pa_source_info* i, int eol, void* userdata) {
    SourceNameCallbackData* data = static_cast<SourceNameCallbackData*>(userdata);

    if (eol < 0) {
      g_warning("Failed to get source info: %s", pa_strerror(pa_context_errno(c)));
      return;
    }

    if (eol > 0) {
      return;
    }

    if (i->index == data->target_id) {
      data->source_name = g_strdup(i->name);
      data->found = TRUE;
    }
  };

  pa_operation* op = pa_context_get_source_info_list(g_context, source_name_callback, &name_data);
  if (op) {
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
      pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    }
    pa_operation_unref(op);
  }

  if (!name_data.found || !name_data.source_name) {
    g_free(name_data.source_name);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "DEVICE_NOT_FOUND", "Input device not found", nullptr));
  }

  // Set default source
  pa_context_set_default_source(g_context, name_data.source_name, nullptr, nullptr);

  g_free(name_data.source_name);

  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Set default output device
static FlMethodResponse* set_default_output_device(FlValue* args) {
  if (!pulse_audio_init()) {
    g_warning("Failed to initialize PulseAudio");
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "PULSEAUDIO_ERROR", "Failed to connect to PulseAudio", nullptr));
  }

  FlValue* device_id_value = fl_value_lookup_string(args, "deviceId");
  if (!device_id_value || fl_value_get_type(device_id_value) != FL_VALUE_TYPE_INT) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing or invalid deviceId", nullptr));
  }

  guint32 device_id = fl_value_get_int(device_id_value);

  // Get sink info to get the sink name
  typedef struct {
    gchar* sink_name;
    guint32 target_id;
    gboolean found;
  } SinkNameCallbackData;

  SinkNameCallbackData name_data = {nullptr, device_id, FALSE};

  auto sink_name_callback = [](pa_context* c, const pa_sink_info* i, int eol, void* userdata) {
    SinkNameCallbackData* data = static_cast<SinkNameCallbackData*>(userdata);

    if (eol < 0) {
      g_warning("Failed to get sink info: %s", pa_strerror(pa_context_errno(c)));
      return;
    }

    if (eol > 0) {
      return;
    }

    if (i->index == data->target_id) {
      data->sink_name = g_strdup(i->name);
      data->found = TRUE;
    }
  };

  pa_operation* op = pa_context_get_sink_info_list(g_context, sink_name_callback, &name_data);
  if (op) {
    while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
      pa_mainloop_iterate(g_mainloop, TRUE, nullptr);
    }
    pa_operation_unref(op);
  }

  if (!name_data.found || !name_data.sink_name) {
    g_free(name_data.sink_name);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "DEVICE_NOT_FOUND", "Output device not found", nullptr));
  }

  // Set default sink
  pa_context_set_default_sink(g_context, name_data.sink_name, nullptr, nullptr);

  g_free(name_data.sink_name);

  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Method call handler
static void method_call_handler(FlMethodChannel* channel, FlMethodCall* method_call,
                                gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, kMethodGetAudioDevices) == 0) {
    response = get_audio_devices();
  } else if (strcmp(method, kMethodSetDefaultInputDevice) == 0) {
    response = set_default_input_device(args);
  } else if (strcmp(method, kMethodSetDefaultOutputDevice) == 0) {
    response = set_default_output_device(args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// Dispose implementation
static void audio_device_channel_dispose(GObject* object) {
  AudioDeviceChannel* self = AUDIO_DEVICE_CHANNEL(object);

  g_clear_object(&self->channel);

  // Note: We don't cleanup PulseAudio here as it might be used by other operations
  // The cleanup will happen on application shutdown

  G_OBJECT_CLASS(audio_device_channel_parent_class)->dispose(object);
}

// Class initialization
static void audio_device_channel_class_init(AudioDeviceChannelClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = audio_device_channel_dispose;
}

// Instance initialization
static void audio_device_channel_init(AudioDeviceChannel* self) {}

// Create new AudioDeviceChannel
AudioDeviceChannel* audio_device_channel_new(FlBinaryMessenger* messenger) {
  AudioDeviceChannel* self = AUDIO_DEVICE_CHANNEL(g_object_new(audio_device_channel_get_type(), nullptr));

  FlStandardMethodCodec* codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));

  if (self->channel) {
    fl_method_channel_set_method_call_handler(self->channel, method_call_handler, self, nullptr);
  }

  return self;
}

// Dispose AudioDeviceChannel
void audio_device_channel_dispose(AudioDeviceChannel* self) {
  if (self) {
    g_clear_object(&self->channel);
    pulse_audio_cleanup();
  }
}
