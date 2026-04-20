import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_config_service.dart';
import 'local_tts_service.dart';
import 'text_segmenter.dart';

// =============================================================================
// Pocket TTS On-Device Service — Streaming Sentence Pipeline
// =============================================================================
//
// Bridges to the native PocketTtsChannel via MethodChannel/EventChannel.
// Produces PCM16 24 kHz mono — identical format to KokoroTtsService — so the
// same playResponseAudio path in WhisperRealtimeService handles it unchanged.
//
// The native side runs: SentencePiece tokenization → text_conditioner →
// flow_lm_main (autoregressive) → flow_lm_flow (flow matching) →
// mimi_decoder → PCM16.
//
// Streaming architecture mirrors Kokoro exactly:
//   Claude delta → TextSegmenter → sentence queue → native synthesize loop
// =============================================================================

class PocketTtsService implements LocalTtsService {
  static const _channel =
      MethodChannel('com.agentic_ai/pocket_tts');
  static const _audioChannel =
      EventChannel('com.agentic_ai/pocket_tts_audio');

  final TtsConfig _config;
  bool _initialized = false;
  bool _generating = false;
  late String _currentVoice = 'default';

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

  PocketTtsService({required TtsConfig config}) : _config = config;

  @override
  bool get isInitialized => _initialized;

  /// Check if the Pocket TTS model files are available in the app bundle.
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
          debugPrint('[PocketTTS] Audio event error: $e');
        },
      );

      if (_initialized) {
        final binaryDir = File(Platform.resolvedExecutable).parent.path;
        final refWav =
            '$binaryDir/data/flutter_assets/models/pocket-tts-onnx/reference_sample.wav';
        final ok = await cloneVoiceFromFile(refWav, 'default');
        debugPrint('[PocketTTS] Default voice encoded: $ok');
      }

      debugPrint('[PocketTTS] Initialized: $_initialized');
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] Init failed: ${e.message}');
      _initialized = false;
    }
  }

  /// Override the post-synthesis amplitude gain.
  ///
  /// [gain] > 0  — fixed multiplier (75.0 is calibrated for the default voice).
  /// [gain] == -1 — dynamic RMS normalization (default).
  /// [gain] == 0  — pass-through; audio will be very quiet (~-60 dBFS).
  Future<void> setGainOverride(double gain) async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('setGainOverride', {'gain': gain});
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] setGainOverride failed: ${e.message}');
    }
  }

  @override
  Future<void> setVoice(String voiceStyle) async {
    _currentVoice = voiceStyle;
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('setVoice', {'voice': voiceStyle});
      debugPrint('[PocketTTS] Voice set: $voiceStyle');
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] setVoice failed: ${e.message}');
    }
  }

  @override
  Future<void> warmUpSynthesis() async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('warmup', {
        'voice': _config.kokoroVoiceStyle,
      });
      debugPrint('[PocketTTS] Native warmup finished');
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] warmUpSynthesis: ${e.message}');
    } on MissingPluginException {
      // Graceful degradation if warmup not available.
    }
  }

  @override
  void startGeneration() {
    if (_generating) endGeneration();
    _generating = true;
    _segmenter.reset();
    _sentenceQueue.clear();
    _speakingController.add(true);
    debugPrint('[PocketTTS] Generation started');
  }

  @override
  void sendText(String text) {
    if (!_generating || text.isEmpty) return;
    final sentences = _segmenter.addText(text);
    if (sentences.isNotEmpty) {
      _sentenceQueue.addAll(sentences);
      _pumpQueue();
    }
  }

  @override
  Future<void> endGeneration() async {
    if (!_generating) return;
    _generating = false;

    final remainder = _segmenter.flush();
    if (remainder != null) _sentenceQueue.add(remainder);

    if (_sentenceQueue.isEmpty && !_synthesizing) {
      _speakingController.add(false);
      debugPrint('[PocketTTS] endGeneration: no text to synthesize');
      return;
    }

    _pumpQueue();

    if (_synthesizing || _sentenceQueue.isNotEmpty) {
      _drainCompleter = Completer<void>();
      await _drainCompleter!.future;
      _drainCompleter = null;
    }

    _speakingController.add(false);
    debugPrint('[PocketTTS] Generation complete');
  }

  // ───────────────────── synthesis queue pump ─────────────────────

  void _pumpQueue() {
    if (_synthesizing) return;
    if (_sentenceQueue.isEmpty) return;
    if (!_initialized) {
      debugPrint('[PocketTTS] Not initialized, dropping '
          '${_sentenceQueue.length} queued sentences');
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
      debugPrint('[PocketTTS] Synthesizing sentence '
          '(${text.length} chars, ${_sentenceQueue.length} queued): '
          '"${text.length > 60 ? text.substring(0, 60) : text}"');

      final sw = Stopwatch()..start();
      try {
        await _channel.invokeMethod('synthesize', {
          'text': text,
          'voice': _currentVoice,
        });
        debugPrint('[PocketTTS] Synthesis done in ${sw.elapsedMilliseconds} ms');
      } on PlatformException catch (e) {
        debugPrint('[PocketTTS] Synthesis failed: ${e.message}');
      }

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

  /// Encode a short audio clip (PCM16 24 kHz mono bytes) as a cloned voice
  /// stored under [voiceId]. Returns true on success. Lazily loads the voice
  /// encoder model on first call (~500 ms extra startup).
  Future<bool> cloneVoice(Uint8List audioData, String voiceId) async {
    if (!_initialized || audioData.isEmpty || voiceId.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>('encodeVoice', {
        'audioData': audioData,
        'voiceId':   voiceId,
      });
      debugPrint('[PocketTTS] cloneVoice "$voiceId": ${result == true}');
      return result == true;
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] cloneVoice failed: ${e.message}');
      return false;
    }
  }

  /// Serialize a cloned voice embedding to bytes for persistence.
  /// Returns null if the voice is not found.
  Future<Uint8List?> exportVoiceEmbedding(String voiceId) async {
    if (!_initialized || voiceId.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod<Uint8List>(
          'exportVoiceEmbedding', {'voiceId': voiceId});
      return result;
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] exportVoiceEmbedding failed: ${e.message}');
      return null;
    }
  }

  /// Restore a cloned voice from previously exported bytes.
  Future<bool> importVoiceEmbedding(String voiceId, Uint8List data) async {
    if (!_initialized || voiceId.isEmpty || data.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
          'importVoiceEmbedding', {'voiceId': voiceId, 'embeddingData': data});
      debugPrint('[PocketTTS] importVoiceEmbedding "$voiceId": ${result == true}');
      return result == true;
    } on PlatformException catch (e) {
      debugPrint('[PocketTTS] importVoiceEmbedding failed: ${e.message}');
      return false;
    }
  }

  /// Decode [filePath] to PCM16 24 kHz mono, then run the voice encoder.
  ///
  /// WAV files are decoded in Dart. All other formats (MP3, FLAC, OGG, M4A,
  /// AAC, …) are decoded via ffmpeg, which must be available on PATH.
  Future<bool> cloneVoiceFromFile(String filePath, String voiceId) async {
    if (!_initialized) return false;
    try {
      final Uint8List pcm = await decodeAudioFileToPcm16(filePath);
      if (pcm.isEmpty) {
        debugPrint('[PocketTTS] cloneVoiceFromFile: decoded PCM is empty');
        return false;
      }
      debugPrint('[PocketTTS] cloneVoiceFromFile: decoded ${pcm.length} bytes '
          '(${pcm.length ~/ 2 / 24000.0}s) for "$voiceId"');
      return cloneVoice(pcm, voiceId);
    } catch (e) {
      debugPrint('[PocketTTS] cloneVoiceFromFile failed: $e');
      return false;
    }
  }

  // ── Audio decode utility ─────────────────────────────────────────────────

  /// Decode an audio file to PCM16 24 kHz mono [Uint8List].
  ///
  /// WAV is decoded natively; all other formats fall back to ffmpeg.
  static Future<Uint8List> decodeAudioFileToPcm16(String filePath) async {
    final String ext = filePath.toLowerCase().split('.').last;
    if (ext == 'wav') {
      final Uint8List bytes = await File(filePath).readAsBytes();
      return _decodeWavToPcm16(bytes);
    }
    return _decodeFfmpegToPcm16(filePath);
  }

  /// Parse a WAV file, mix to mono, and resample to 24 kHz PCM16.
  static Uint8List _decodeWavToPcm16(Uint8List wav) {
    final ByteData hdr = wav.buffer.asByteData(wav.offsetInBytes);

    final int channels    = hdr.getInt16(22, Endian.little);
    final int sampleRate  = hdr.getInt32(24, Endian.little);
    final int bitDepth    = hdr.getInt16(34, Endian.little);

    if (bitDepth != 16) throw Exception('WAV: unsupported bit depth $bitDepth');

    // Find the 'data' sub-chunk.
    int dataOffset = 0;
    int dataSize   = 0;
    for (int i = 12; i < wav.length - 8; i++) {
      if (wav[i] == 0x64 && wav[i+1] == 0x61 &&
          wav[i+2] == 0x74 && wav[i+3] == 0x61) {
        dataSize   = hdr.getInt32(i + 4, Endian.little);
        dataOffset = i + 8;
        break;
      }
    }
    if (dataOffset == 0) throw Exception('WAV: no data chunk');

    final int end = (dataOffset + dataSize).clamp(0, wav.length);
    Uint8List pcm = wav.sublist(dataOffset, end);

    // Stereo → mono (average channels).
    if (channels == 2) {
      final ByteData bd    = pcm.buffer.asByteData(pcm.offsetInBytes);
      final int n          = pcm.length ~/ 4;
      final Uint8List mono = Uint8List(n * 2);
      final ByteData mbd   = mono.buffer.asByteData();
      for (int i = 0; i < n; i++) {
        final int l = bd.getInt16(i * 4,     Endian.little);
        final int r = bd.getInt16(i * 4 + 2, Endian.little);
        mbd.setInt16(i * 2, (l + r) ~/ 2, Endian.little);
      }
      pcm = mono;
    }

    if (sampleRate != 24000) pcm = _resamplePcm16(pcm, sampleRate, 24000);
    return pcm;
  }

  /// Decode any audio format to PCM16 24 kHz mono via ffmpeg.
  static Future<Uint8List> _decodeFfmpegToPcm16(String path) async {
    final ProcessResult result = await Process.run(
      'ffmpeg',
      <String>['-i', path, '-ar', '24000', '-ac', '1', '-f', 's16le', 'pipe:1'],
      stdoutEncoding: null,  // raw bytes
    );
    if (result.exitCode != 0) {
      throw Exception('ffmpeg failed (exit ${result.exitCode}): ${result.stderr}');
    }
    final List<int> raw = result.stdout as List<int>;
    return raw is Uint8List ? raw : Uint8List.fromList(raw);
  }

  /// Linear-interpolation resampler for mono PCM16.
  static Uint8List _resamplePcm16(Uint8List input, int srcRate, int dstRate) {
    final ByteData bd     = input.buffer.asByteData(input.offsetInBytes);
    final int srcCount    = input.length ~/ 2;
    final int dstCount    = (srcCount * dstRate / srcRate).round();
    final Uint8List out   = Uint8List(dstCount * 2);
    final ByteData obd    = out.buffer.asByteData();
    final double ratio    = srcRate / dstRate;

    for (int i = 0; i < dstCount; i++) {
      final double pos = i * ratio;
      final int idx    = pos.floor();
      final double frac = pos - idx;
      final int s0 = idx < srcCount         ? bd.getInt16(idx * 2, Endian.little) : 0;
      final int s1 = (idx + 1) < srcCount   ? bd.getInt16((idx + 1) * 2, Endian.little) : s0;
      obd.setInt16(i * 2, (s0 + (s1 - s0) * frac).round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  /// Returns the duration of [filePath] in seconds using ffprobe.
  /// Returns 0 on failure.
  static Future<double> getAudioDurationSeconds(String filePath) async {
    final ProcessResult result = await Process.run('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      filePath,
    ]);
    if (result.exitCode != 0) return 0;
    return double.tryParse((result.stdout as String).trim()) ?? 0;
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
