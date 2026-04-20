#ifndef RUNNER_POCKET_TTS_CHANNEL_H_
#define RUNNER_POCKET_TTS_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

G_BEGIN_DECLS

#define POCKET_TTS_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), pocket_tts_channel_get_type(), PocketTtsChannel))
#define IS_POCKET_TTS_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_TYPE((obj), pocket_tts_channel_get_type()))

typedef struct _PocketTtsChannel      PocketTtsChannel;
typedef struct _PocketTtsChannelClass PocketTtsChannelClass;

PocketTtsChannel* pocket_tts_channel_new(FlBinaryMessenger* messenger);
void pocket_tts_channel_dispose(PocketTtsChannel* self);
GType pocket_tts_channel_get_type();

G_END_DECLS

#endif  // RUNNER_POCKET_TTS_CHANNEL_H_
