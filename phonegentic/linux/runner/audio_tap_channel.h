#ifndef RUNNER_AUDIO_TAP_CHANNEL_H_
#define RUNNER_AUDIO_TAP_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

G_BEGIN_DECLS

#define AUDIO_TAP_CHANNEL(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), audio_tap_channel_get_type(), AudioTapChannel))
#define IS_AUDIO_TAP_CHANNEL(obj) (G_TYPE_CHECK_INSTANCE_TYPE((obj), audio_tap_channel_get_type()))

typedef struct _AudioTapChannel AudioTapChannel;
typedef struct _AudioTapChannelClass AudioTapChannelClass;

// Creates a new AudioTapChannel instance
AudioTapChannel* audio_tap_channel_new(FlBinaryMessenger* messenger);

// Disposes of the AudioTapChannel instance
void audio_tap_channel_dispose(AudioTapChannel* self);

// Gets the type
GType audio_tap_channel_get_type();

G_END_DECLS

#endif  // RUNNER_AUDIO_TAP_CHANNEL_H_
