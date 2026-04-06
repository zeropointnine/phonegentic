#ifndef RUNNER_AUDIO_DEVICE_CHANNEL_H_
#define RUNNER_AUDIO_DEVICE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

G_BEGIN_DECLS

#define AUDIO_DEVICE_CHANNEL(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), audio_device_channel_get_type(), AudioDeviceChannel))
#define IS_AUDIO_DEVICE_CHANNEL(obj) (G_TYPE_CHECK_INSTANCE_TYPE((obj), audio_device_channel_get_type()))

typedef struct _AudioDeviceChannel AudioDeviceChannel;
typedef struct _AudioDeviceChannelClass AudioDeviceChannelClass;

// Creates a new AudioDeviceChannel instance
AudioDeviceChannel* audio_device_channel_new(FlBinaryMessenger* messenger);

// Disposes of the AudioDeviceChannel instance
void audio_device_channel_dispose(AudioDeviceChannel* self);

// Gets the type
GType audio_device_channel_get_type();

G_END_DECLS

#endif  // RUNNER_AUDIO_DEVICE_CHANNEL_H_
