#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around pocket_tts::PocketTtsOnnxEngine.
/// No C++ types cross this header boundary.
@interface PocketTtsEngine : NSObject

- (BOOL)initializeWithModelsDir:(NSString *)dir;
+ (BOOL)isModelAvailableAtDir:(NSString *)dir;
- (void)setVoice:(NSString *)voiceName;
- (void)setGainOverride:(float)gain;

/// Batch synthesis — returns all PCM16 audio after full synthesis (used by warmup).
- (NSData *)synthesize:(NSString *)text voice:(NSString *)voice;

/// Streaming synthesis — block called on the calling thread per decoded chunk.
- (void)synthesizeStreaming:(NSString *)text
                     voice:(NSString *)voice
                   onChunk:(void (^)(NSData *pcm))chunkCallback;

/// Encode a short PCM16 clip (24 kHz mono) into a cloned voice embedding.
- (BOOL)encodeVoice:(NSData *)pcm16Data voiceId:(NSString *)voiceId;

/// Serialize a previously encoded voice embedding to a binary blob.
- (NSData * _Nullable)exportVoiceEmbedding:(NSString *)voiceId;

/// Deserialize and store a voice embedding. Returns NO on format error.
- (BOOL)importVoiceEmbedding:(NSString *)voiceId data:(NSData *)data;

- (void)dispose;

@end

NS_ASSUME_NONNULL_END
