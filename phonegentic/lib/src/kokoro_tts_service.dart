import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_config_service.dart';

// =============================================================================
// Kokoro On-Device TTS Service
// =============================================================================
//
// Bridges to the native KokoroTTS Swift library via MethodChannel.
// Produces PCM16 24 kHz audio identical to ElevenLabsTtsService output,
// so the same playResponseAudio path in WhisperRealtimeService works.
//
// The native side loads the Kokoro model on init, then generates audio
// from text synchronously (runs ~3.3x real-time on Apple Silicon).
//
// Unlike ElevenLabs, Kokoro is NOT a streaming API — it generates the
// full utterance at once. To match the streaming interface expected by
// AgentService, we buffer text until endGeneration() and then synthesise
// the complete response in one shot, emitting the audio as chunks.
// =============================================================================

class KokoroTtsService {
  static const _channel = MethodChannel('com.agentic_ai/kokoro_tts');
  static const _audioChannel = EventChannel('com.agentic_ai/kokoro_tts_audio');

  final TtsConfig _config;
  bool _initialized = false;
  bool _generating = false;
  final StringBuffer _textBuffer = StringBuffer();

  final _audioController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioChunks => _audioController.stream;

  final _speakingController = StreamController<bool>.broadcast();
  Stream<bool> get speakingState => _speakingController.stream;

  StreamSubscription? _audioEventSub;

  KokoroTtsService({required TtsConfig config}) : _config = config;

  bool get isInitialized => _initialized;

  /// Available Kokoro voice styles.
  static const voiceStyles = [
    'af_heart',
    'af_alloy',
    'af_aoede',
    'af_bella',
    'af_jessica',
    'af_kore',
    'af_nicole',
    'af_nova',
    'af_river',
    'af_sarah',
    'af_sky',
    'am_adam',
    'am_echo',
    'am_eric',
    'am_fenrir',
    'am_liam',
    'am_michael',
    'am_onyx',
    'am_puck',
    'am_santa',
    'bf_alice',
    'bf_emma',
    'bf_isabella',
    'bf_lily',
    'bm_daniel',
    'bm_fable',
    'bm_george',
    'bm_lewis',
  ];

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final result = await _channel.invokeMethod<bool>('initialize');
      _initialized = result == true;

      // Listen for audio chunks from the native side via EventChannel
      _audioEventSub = _audioChannel.receiveBroadcastStream().listen(
        (data) {
          if (data is Uint8List && data.isNotEmpty) {
            _audioController.add(data);
          }
        },
        onError: (e) {
          debugPrint('[KokoroTTS] Audio event error: $e');
        },
      );

      debugPrint('[KokoroTTS] Initialized: $_initialized');
    } on PlatformException catch (e) {
      debugPrint('[KokoroTTS] Init failed: ${e.message}');
      _initialized = false;
    }
  }

  /// Check if the Kokoro model files are available in the app bundle.
  static Future<bool> isModelAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isModelAvailable');
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Set the voice style for subsequent generations.
  Future<void> setVoice(String voiceStyle) async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('setVoice', {'voice': voiceStyle});
      debugPrint('[KokoroTTS] Voice set: $voiceStyle');
    } on PlatformException catch (e) {
      debugPrint('[KokoroTTS] setVoice failed: ${e.message}');
    }
  }

  void startGeneration() {
    if (_generating) {
      endGeneration();
    }
    _generating = true;
    _textBuffer.clear();
    _speakingController.add(true);
    debugPrint('[KokoroTTS] Generation started');
  }

  /// Buffer text for synthesis. Unlike ElevenLabs streaming, Kokoro
  /// generates full utterances — text is accumulated until endGeneration().
  void sendText(String text) {
    if (!_generating || text.isEmpty) return;
    _textBuffer.write(text);
  }

  /// Flush accumulated text and generate audio.
  Future<void> endGeneration() async {
    if (!_generating) return;
    _generating = false;

    final text = _textBuffer.toString().trim();
    _textBuffer.clear();

    if (text.isEmpty) {
      _speakingController.add(false);
      debugPrint('[KokoroTTS] endGeneration: no text to synthesize');
      return;
    }

    debugPrint('[KokoroTTS] Synthesizing ${text.length} chars...');

    if (!_initialized) {
      debugPrint('[KokoroTTS] Not initialized, dropping text');
      _speakingController.add(false);
      return;
    }

    try {
      // The native side generates audio and pushes chunks via the EventChannel.
      // This call blocks until generation is complete.
      await _channel.invokeMethod('synthesize', {
        'text': text,
        'voice': _config.kokoroVoiceStyle,
      });
    } on PlatformException catch (e) {
      debugPrint('[KokoroTTS] Synthesis failed: ${e.message}');
    }

    _speakingController.add(false);
    debugPrint('[KokoroTTS] Generation complete');
  }

  Future<void> dispose() async {
    _generating = false;
    _textBuffer.clear();
    _speakingController.add(false);
    _audioEventSub?.cancel();
    _audioEventSub = null;

    if (_initialized) {
      try {
        await _channel.invokeMethod('dispose');
      } catch (_) {}
      _initialized = false;
    }

    await _audioController.close();
    await _speakingController.close();
  }
}
