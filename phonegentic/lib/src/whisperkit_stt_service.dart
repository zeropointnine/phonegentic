import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_config_service.dart';

// =============================================================================
// WhisperKit On-Device STT Service
// =============================================================================
//
// Bridges to the native WhisperKit Swift framework via MethodChannel +
// EventChannel. Provides real-time speech-to-text transcription running
// entirely on-device using Apple's Neural Engine / CoreML.
//
// Audio is fed from the existing AudioTapChannel (same PCM16 24kHz stream)
// to the native WhisperKit instance. Transcription results are pushed back
// via an EventChannel as they become available.
//
// Model variants: tiny (~75 MB), base (~140 MB), small (~460 MB)
// =============================================================================

/// Transcription event from WhisperKit.
class WhisperKitTranscription {
  final String text;
  final bool isFinal;
  final String? language;

  const WhisperKitTranscription({
    required this.text,
    this.isFinal = false,
    this.language,
  });
}

class WhisperKitSttService {
  static const _channel = MethodChannel('com.agentic_ai/whisperkit_stt');
  static const _transcriptChannel =
      EventChannel('com.agentic_ai/whisperkit_transcripts');

  final SttConfig _config;
  bool _initialized = false;
  bool _transcribing = false;

  final _transcriptionController =
      StreamController<WhisperKitTranscription>.broadcast();
  Stream<WhisperKitTranscription> get transcriptions =>
      _transcriptionController.stream;

  StreamSubscription? _transcriptSub;

  WhisperKitSttService({required SttConfig config}) : _config = config;

  bool get isInitialized => _initialized;
  bool get isTranscribing => _transcribing;

  static const validModelSizes = ['tiny', 'base', 'small', 'large-v3-turbo'];

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'modelSize': _config.whisperKitModelSize,
        'useGpu': _config.whisperKitUseGpu,
      });
      _initialized = result == true;

      _transcriptSub = _transcriptChannel.receiveBroadcastStream().listen(
        (data) {
          if (_transcriptionController.isClosed) return;
          if (data is Map) {
            final warning = data['warning'] as String?;
            if (warning != null) {
              debugPrint('[WhisperKit] Native warning: $warning');
            }
            _transcriptionController.add(WhisperKitTranscription(
              text: data['text'] as String? ?? '',
              isFinal: data['isFinal'] as bool? ?? false,
              language: data['language'] as String?,
            ));
          }
        },
        onError: (e) {
          debugPrint('[WhisperKit] Transcript event error: $e');
        },
      );

      debugPrint('[WhisperKit] Initialized with model: '
          '${_config.whisperKitModelSize}');
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] Init failed: ${e.message}');
      _initialized = false;
    }
  }

  /// Check if WhisperKit model files are available in the app bundle.
  static Future<bool> isModelAvailable({String modelSize = 'base'}) async {
    try {
      final result = await _channel.invokeMethod<bool>('isModelAvailable', {
        'modelSize': modelSize,
      });
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Start real-time transcription. Audio is pulled from the existing
  /// audio tap — no separate audio feed is needed.
  Future<void> startTranscription() async {
    if (!_initialized || _transcribing) return;
    try {
      await _channel.invokeMethod('startTranscription');
      _transcribing = true;
      debugPrint('[WhisperKit] Transcription started');
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] Start failed: ${e.message}');
    }
  }

  /// Feed a PCM16 audio chunk for transcription. Used when audio comes
  /// from the Dart side rather than being tapped natively.
  Future<void> feedAudio(Uint8List pcm16Data) async {
    if (!_initialized || !_transcribing) return;
    try {
      await _channel.invokeMethod('feedAudio', {'audio': pcm16Data});
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] feedAudio failed: ${e.message}');
    }
  }

  /// Reset the transcription timer and flush the audio buffer so the first
  /// post-TTS buffer is processed at a predictable offset with clean audio.
  Future<void> notifyPlaybackEnded() async {
    if (!_initialized || !_transcribing) return;
    try {
      await _channel.invokeMethod('notifyPlaybackEnded');
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] notifyPlaybackEnded failed: ${e.message}');
    }
  }

  /// Flush the audio buffer without resetting the timer.  Used on ghost
  /// onPlaybackComplete events to discard echo that leaked through gaps
  /// in native suppression.
  Future<void> flushAudioBuffer() async {
    if (!_initialized || !_transcribing) return;
    try {
      await _channel.invokeMethod('flushAudioBuffer');
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] flushAudioBuffer failed: ${e.message}');
    }
  }

  Future<void> stopTranscription() async {
    if (!_transcribing) return;
    try {
      await _channel.invokeMethod('stopTranscription');
      _transcribing = false;
      debugPrint('[WhisperKit] Transcription stopped');
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] Stop failed: ${e.message}');
    }
  }

  /// Push the user's VAD / hallucination thresholds to the native
  /// channel. Safe to call before `initialize()` — the channel persists
  /// values regardless of model state, so the very first transcription
  /// already runs with the right gate.
  Future<void> applyVadConfig(VadConfig vad) async {
    try {
      await _channel.invokeMethod('setVadConfig', {
        'adaptiveNoiseFloor': vad.adaptiveNoiseFloor,
        'rmsNoiseGate': vad.rmsNoiseGate,
        'noSpeechThreshold': vad.noSpeechThreshold,
        'logProbThreshold': vad.logProbThreshold,
        'compressionRatioThreshold': vad.compressionRatioThreshold,
      });
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] applyVadConfig failed: ${e.message}');
    } on MissingPluginException {
      // Non-Apple build — channel isn't registered. Silently ignore.
    }
  }

  /// Pause or resume the native transcription timer without tearing down
  /// WhisperKit's loaded CoreML model. Use this between calls so silence
  /// doesn't drive the hallucination loop — processing resumes on the
  /// next call-phase transition.
  Future<void> setProcessingPaused(bool paused) async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('setProcessingPaused', {'paused': paused});
    } on PlatformException catch (e) {
      debugPrint('[WhisperKit] setProcessingPaused failed: ${e.message}');
    }
  }

  Future<void> dispose() async {
    _transcribing = false;
    _transcriptSub?.cancel();
    _transcriptSub = null;

    if (_initialized) {
      try {
        await _channel.invokeMethod('dispose');
      } catch (_) {}
      _initialized = false;
    }

    await _transcriptionController.close();
  }
}
