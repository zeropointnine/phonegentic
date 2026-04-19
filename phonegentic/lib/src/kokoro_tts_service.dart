import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_config_service.dart';
import 'local_tts_service.dart';
import 'text_segmenter.dart';

// =============================================================================
// Kokoro On-Device TTS Service — Streaming Sentence Pipeline
// =============================================================================
//
// Bridges to the native KokoroTTS Swift library via MethodChannel.
// Produces PCM16 24 kHz audio identical to ElevenLabsTtsService output,
// so the same playResponseAudio path in WhisperRealtimeService works.
//
// The native side loads the Kokoro model on init, then generates audio
// from text synchronously (runs ~3.3x real-time on Apple Silicon).
//
// ## Streaming architecture
//
// Kokoro's native API is NOT streaming — it generates a full utterance at
// once. To avoid waiting for Claude's entire response before speaking, we
// use a TextSegmenter to detect sentence boundaries in the streaming text
// deltas and synthesize each sentence independently:
//
//   Claude delta → TextSegmenter → sentence queue → native synthesize loop
//
// This means audio for the first sentence starts playing as soon as that
// sentence is complete (~0.5-2s), while later sentences are queued and
// synthesized serially. The pipeline overlaps: while sentence N's audio
// plays through AudioTap, sentence N+1 is being synthesized.
// =============================================================================

class KokoroTtsService implements LocalTtsService {
  static const _channel = MethodChannel('com.agentic_ai/kokoro_tts');
  static const _audioChannel = EventChannel('com.agentic_ai/kokoro_tts_audio');

  final TtsConfig _config;
  bool _initialized = false;
  bool _generating = false;

  final TextSegmenter _segmenter = TextSegmenter();
  final List<String> _sentenceQueue = [];
  bool _synthesizing = false;
  Completer<void>? _drainCompleter;

  final _audioController = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get audioChunks => _audioController.stream;

  final _speakingController = StreamController<bool>.broadcast();
  @override
  Stream<bool> get speakingState => _speakingController.stream;

  StreamSubscription? _audioEventSub;

  KokoroTtsService({required TtsConfig config}) : _config = config;

  @override
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

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final result = await _channel.invokeMethod<bool>('initialize');
      _initialized = result == true;

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
  @override
  Future<void> setVoice(String voiceStyle) async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('setVoice', {'voice': voiceStyle});
      debugPrint('[KokoroTTS] Voice set: $voiceStyle');
    } on PlatformException catch (e) {
      debugPrint('[KokoroTTS] setVoice failed: ${e.message}');
    }
  }

  /// Prime MLX / Kokoro on the native queue with a discarded `.` synthesis so
  /// the first user-visible sentence does not pay full cold-start latency.
  @override
  Future<void> warmUpSynthesis() async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('warmup', {
        'voice': _config.kokoroVoiceStyle,
      });
      debugPrint('[KokoroTTS] Native warmup finished');
    } on PlatformException catch (e) {
      debugPrint('[KokoroTTS] warmUpSynthesis: ${e.message}');
    } on MissingPluginException {
      // Older macOS builds without `warmup` — ignore.
    }
  }

  @override
  void startGeneration() {
    if (_generating) {
      endGeneration();
    }
    _generating = true;
    _segmenter.reset();
    _sentenceQueue.clear();
    _speakingController.add(true);
    debugPrint('[KokoroTTS] Generation started');
  }

  /// Stream a text chunk. The TextSegmenter accumulates deltas and detects
  /// sentence boundaries. Each complete sentence is queued for immediate
  /// synthesis rather than waiting for the full response.
  @override
  void sendText(String text) {
    if (!_generating || text.isEmpty) return;

    final sentences = _segmenter.addText(text);
    if (sentences.isNotEmpty) {
      _sentenceQueue.addAll(sentences);
      _pumpQueue();
    }
  }

  /// Flush remaining text and wait for the synthesis queue to drain.
  @override
  Future<void> endGeneration() async {
    if (!_generating) return;
    _generating = false;

    final remainder = _segmenter.flush();
    if (remainder != null) {
      _sentenceQueue.add(remainder);
    }

    if (_sentenceQueue.isEmpty && !_synthesizing) {
      _speakingController.add(false);
      debugPrint('[KokoroTTS] endGeneration: no text to synthesize');
      return;
    }

    // Kick the queue in case it's idle with new items from flush.
    _pumpQueue();

    // Wait for the queue to fully drain before signalling done.
    if (_synthesizing || _sentenceQueue.isNotEmpty) {
      _drainCompleter = Completer<void>();
      await _drainCompleter!.future;
      _drainCompleter = null;
    }

    _speakingController.add(false);
    debugPrint('[KokoroTTS] Generation complete');
  }

  // ───────────────────── synthesis queue pump ─────────────────────

  /// Process queued sentences one at a time. Runs as a microtask chain —
  /// each native synthesize call is awaited before the next starts.
  void _pumpQueue() {
    if (_synthesizing) return;
    if (_sentenceQueue.isEmpty) return;
    if (!_initialized) {
      debugPrint('[KokoroTTS] Not initialized, dropping ${_sentenceQueue.length} queued sentences');
      _sentenceQueue.clear();
      _finishDrain();
      return;
    }

    _synthesizing = true;
    _synthesizeLoop();
  }

  Future<void> _synthesizeLoop() async {
    while (_sentenceQueue.isNotEmpty) {
      final text = _sentenceQueue.removeAt(0);
      debugPrint('[KokoroTTS] Synthesizing sentence '
          '(${text.length} chars, ${_sentenceQueue.length} queued): '
          '"${text.length > 60 ? text.substring(0, 60) : text}"');

      final sw = Stopwatch()..start();
      try {
        await _channel.invokeMethod('synthesize', {
          'text': text,
          'voice': _config.kokoroVoiceStyle,
        });
        debugPrint('[KokoroTTS] Synthesis done in ${sw.elapsedMilliseconds} ms');
      } on PlatformException catch (e) {
        debugPrint('[KokoroTTS] Synthesis failed: ${e.message}');
      }

      // If generation was cancelled (new startGeneration or dispose), bail.
      if (!_generating && _sentenceQueue.isEmpty) break;
    }

    _synthesizing = false;
    _finishDrain();
  }

  void _finishDrain() {
    if (_drainCompleter != null && !_drainCompleter!.isCompleted) {
      _drainCompleter!.complete();
    }
  }

  @override
  Future<void> dispose() async {
    _generating = false;
    _segmenter.reset();
    _sentenceQueue.clear();
    _speakingController.add(false);
    _finishDrain();
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
