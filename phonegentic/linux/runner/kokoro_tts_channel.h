#ifndef RUNNER_KOKORO_TTS_CHANNEL_H_
#define RUNNER_KOKORO_TTS_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

G_BEGIN_DECLS

#define KOKORO_TTS_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), kokoro_tts_channel_get_type(), KokoroTtsChannel))
#define IS_KOKORO_TTS_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_TYPE((obj), kokoro_tts_channel_get_type()))

typedef struct _KokoroTtsChannel KokoroTtsChannel;
typedef struct _KokoroTtsChannelClass KokoroTtsChannelClass;

// Creates a new KokoroTtsChannel instance
KokoroTtsChannel* kokoro_tts_channel_new(FlBinaryMessenger* messenger);

// Disposes of the KokoroTtsChannel instance
void kokoro_tts_channel_dispose(KokoroTtsChannel* self);

// Gets the type
GType kokoro_tts_channel_get_type();

G_END_DECLS

#endif  // RUNNER_KOKORO_TTS_CHANNEL_H_
