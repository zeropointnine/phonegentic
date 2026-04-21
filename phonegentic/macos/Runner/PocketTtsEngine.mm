#import "PocketTtsEngine.h"
#include "pocket_tts_onnx_engine.h"

#include <memory>
#include <vector>

@implementation PocketTtsEngine {
    std::unique_ptr<pocket_tts::PocketTtsOnnxEngine> _engine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = std::make_unique<pocket_tts::PocketTtsOnnxEngine>();
    }
    return self;
}

- (BOOL)initializeWithModelsDir:(NSString *)dir {
    return _engine->initialize(dir.UTF8String);
}

+ (BOOL)isModelAvailableAtDir:(NSString *)dir {
    return pocket_tts::PocketTtsOnnxEngine::is_model_available(dir.UTF8String);
}

- (void)setVoice:(NSString *)voiceName {
    _engine->set_voice(voiceName.UTF8String);
}

- (void)setGainOverride:(float)gain {
    _engine->set_gain_override(gain);
}

- (NSData *)synthesize:(NSString *)text voice:(NSString *)voice {
    std::vector<int16_t> pcm = _engine->synthesize(text.UTF8String, voice.UTF8String);
    if (pcm.empty()) return [NSData data];
    return [NSData dataWithBytes:pcm.data() length:pcm.size() * sizeof(int16_t)];
}

- (void)synthesizeStreaming:(NSString *)text
                     voice:(NSString *)voice
                   onChunk:(void (^)(NSData *))chunkCallback {
    _engine->synthesize_streaming(
        text.UTF8String,
        voice.UTF8String,
        [chunkCallback](std::vector<int16_t> chunk) {
            NSData *data = [NSData dataWithBytes:chunk.data()
                                         length:chunk.size() * sizeof(int16_t)];
            chunkCallback(data);
        }
    );
}

- (BOOL)encodeVoice:(NSData *)pcm16Data voiceId:(NSString *)voiceId {
    const int16_t *samples = static_cast<const int16_t *>(pcm16Data.bytes);
    size_t nSamples = pcm16Data.length / sizeof(int16_t);
    return _engine->encode_voice(samples, nSamples, voiceId.UTF8String);
}

- (NSData * _Nullable)exportVoiceEmbedding:(NSString *)voiceId {
    std::vector<uint8_t> blob = _engine->export_voice_embedding(voiceId.UTF8String);
    if (blob.empty()) return nil;
    return [NSData dataWithBytes:blob.data() length:blob.size()];
}

- (BOOL)importVoiceEmbedding:(NSString *)voiceId data:(NSData *)data {
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    return _engine->import_voice_embedding(voiceId.UTF8String, bytes, data.length);
}

- (void)dispose {
    _engine->dispose();
}

@end
