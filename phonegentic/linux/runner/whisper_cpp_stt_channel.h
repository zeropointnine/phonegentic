#ifndef RUNNER_WHISPER_CPP_STT_CHANNEL_H_
#define RUNNER_WHISPER_CPP_STT_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>

G_BEGIN_DECLS

#define WHISPER_CPP_STT_CHANNEL_TYPE (whisper_cpp_stt_channel_get_type())
#define WHISPER_CPP_STT_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), WHISPER_CPP_STT_CHANNEL_TYPE, WhisperCppSttChannel))
#define IS_WHISPER_CPP_STT_CHANNEL(obj) \
  (G_TYPE_CHECK_INSTANCE_TYPE((obj), WHISPER_CPP_STT_CHANNEL_TYPE))

typedef struct _WhisperCppSttChannel      WhisperCppSttChannel;
typedef struct _WhisperCppSttChannelClass WhisperCppSttChannelClass;

// Creates a new WhisperCppSttChannel and registers the Flutter platform channels.
WhisperCppSttChannel* whisper_cpp_stt_channel_new(FlBinaryMessenger* messenger);

// Tears down the channel: stops transcription, frees the whisper context.
void whisper_cpp_stt_channel_dispose(WhisperCppSttChannel* self);

GType whisper_cpp_stt_channel_get_type();

G_END_DECLS

#endif  // RUNNER_WHISPER_CPP_STT_CHANNEL_H_
