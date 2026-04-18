import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'agent_config_service.dart';

class ComfortNoiseFileInfo {
  final String path;
  final String displayName;
  const ComfortNoiseFileInfo(this.path, this.displayName);
}

class ComfortNoiseService extends ChangeNotifier {
  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');
  static const _chunkBytes = 48000; // ~1 s at 24 kHz mono 16-bit

  ComfortNoiseConfig _config = const ComfortNoiseConfig();
  final List<ComfortNoiseFileInfo> _files = [];
  bool _loaded = false;

  Uint8List? _pcmCache;
  String? _pcmCachePath;
  bool _playing = false;
  bool _stopRequested = false;
  Timer? _chunkTimer;

  AudioPlayer? _previewPlayer;

  ComfortNoiseConfig get config => _config;
  List<ComfortNoiseFileInfo> get files => List.unmodifiable(_files);
  bool get isPlaying => _playing;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    _config = await AgentConfigService.loadComfortNoiseConfig();
    await _loadFiles();
    if (_config.enabled && _config.selectedPath != null) {
      await _loadPcm(_config.selectedPath!);
    }
    notifyListeners();
  }

  Future<void> updateConfig(ComfortNoiseConfig newConfig) async {
    _config = newConfig;
    await AgentConfigService.saveComfortNoiseConfig(newConfig);
    if (_pcmCachePath != newConfig.selectedPath) {
      _pcmCache = null;
      _pcmCachePath = null;
    }
    notifyListeners();
  }

  /// Pick an audio file and copy it to the comfort noise storage directory.
  /// Returns the destination path, or null if the user cancelled.
  /// Does NOT change the global selected path — callers decide what to do.
  Future<String?> pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'aac', 'm4a'],
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first;
    if (picked.path == null) return null;

    final dir = await _storageDir();
    await dir.create(recursive: true);

    final dest = p.join(dir.path, picked.name);
    await File(picked.path!).copy(dest);

    _files.add(ComfortNoiseFileInfo(
      dest,
      p.basenameWithoutExtension(picked.name),
    ));

    notifyListeners();
    return dest;
  }

  Future<void> deleteFile(String filePath) async {
    try {
      await File(filePath).delete();
    } catch (_) {}
    _files.removeWhere((f) => f.path == filePath);

    if (_config.selectedPath == filePath) {
      _config = _config.copyWith(clearPath: true);
      await AgentConfigService.saveComfortNoiseConfig(_config);
      _pcmCache = null;
      _pcmCachePath = null;
    }
    notifyListeners();
  }

  Future<void> preview(String filePath) async {
    try {
      _previewPlayer ??= AudioPlayer();
      await _previewPlayer!.stop();
      await _previewPlayer!.setFilePath(filePath);
      await _previewPlayer!.setLoopMode(LoopMode.off);
      await _previewPlayer!.setVolume(1.0);
      _previewPlayer!.play();
    } catch (e) {
      debugPrint('[ComfortNoise] Preview failed: $e');
    }
  }

  Future<void> stopPreview() async {
    try {
      await _previewPlayer?.stop();
    } catch (_) {}
  }

  /// Resolve the effective comfort noise path, considering a per-job override.
  /// null jobOverride = use global setting; non-null = use that file.
  /// Returns null if comfort noise is not configured.
  String? resolveEffectivePath(String? jobOverride) {
    if (jobOverride != null && jobOverride.isNotEmpty) return jobOverride;
    if (!_config.enabled) return null;
    return _config.selectedPath;
  }

  /// Start looping comfort noise into the call audio stream.
  /// The brief delay allows the native audio pipeline (enterCallMode /
  /// WebRTC processor registration) to finish before we push PCM chunks.
  Future<void> startPlayback(String? jobOverride) async {
    final path = resolveEffectivePath(jobOverride);
    debugPrint('[ComfortNoise] startPlayback: jobOverride=$jobOverride '
        'globalEnabled=${_config.enabled} globalPath=${_config.selectedPath} '
        'resolved=$path playing=$_playing');
    if (path == null || path.isEmpty) return;
    if (_playing) return;

    _stopRequested = false;

    try {
      final pcm = await _loadPcm(path);
      if (_stopRequested) {
        debugPrint('[ComfortNoise] Cancelled during PCM load');
        return;
      }
      if (pcm == null || pcm.isEmpty) {
        debugPrint('[ComfortNoise] PCM load failed or empty for $path');
        return;
      }

      // Wait for the native audio pipeline to initialise (enterCallMode
      // registers the WebRTC audio processor asynchronously).
      await Future.delayed(const Duration(milliseconds: 250));
      if (_stopRequested || _playing) {
        debugPrint('[ComfortNoise] Cancelled during pipeline wait');
        return;
      }

      debugPrint('[ComfortNoise] Playing ${pcm.length} bytes '
          'at volume ${_config.volume}');
      _playing = true;
      notifyListeners();

      final volume = _config.volume;
      final scaled = _applyVolume(pcm, volume);
      _loopPcm(scaled);
    } catch (e) {
      debugPrint('[ComfortNoise] Failed to start playback: $e');
      _playing = false;
    }
  }

  void stopPlayback() {
    _stopRequested = true;
    if (!_playing) {
      debugPrint('[ComfortNoise] stopPlayback (not playing)');
      return;
    }
    debugPrint('[ComfortNoise] stopPlayback');
    _playing = false;
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _stopNativePlayback();
    notifyListeners();
  }

  void _loopPcm(Uint8List pcm) {
    int offset = 0;
    const chunkDuration = Duration(milliseconds: 950);

    void sendNextChunk() {
      if (!_playing) return;

      final end = (offset + _chunkBytes).clamp(0, pcm.length);
      final chunk = pcm.sublist(offset, end);

      _tapChannel.invokeMethod<void>('playAudioResponse', chunk).catchError(
          (e) => debugPrint('[ComfortNoise] playAudioResponse error: $e'));

      offset += _chunkBytes;
      if (offset >= pcm.length) {
        offset = 0; // loop back
      }

      _chunkTimer = Timer(chunkDuration, sendNextChunk);
    }

    sendNextChunk();
  }

  Future<void> _stopNativePlayback() async {
    try {
      await _tapChannel.invokeMethod('stopAudioPlayback');
    } catch (_) {}
  }

  Future<Uint8List?> _loadPcm(String path) async {
    if (_pcmCachePath == path && _pcmCache != null) return _pcmCache;

    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();

    final ext = p.extension(path).toLowerCase();
    Uint8List pcm;
    if (ext == '.wav') {
      pcm = _wavToPcm24k(bytes);
    } else {
      // For mp3/aac/m4a, use just_audio to decode isn't straightforward.
      // The native playAudioResponse expects PCM16 24kHz. For non-WAV we
      // still attempt WAV-style parsing; users should prefer WAV uploads.
      // A future enhancement could use platform channels for decoding.
      debugPrint('[ComfortNoise] Non-WAV format ($ext) — attempting raw parse');
      pcm = _wavToPcm24k(bytes);
    }

    _pcmCache = pcm;
    _pcmCachePath = path;
    return pcm;
  }

  static Uint8List _applyVolume(Uint8List pcm, double volume) {
    if (volume >= 0.99) return pcm;
    final bd = pcm.buffer.asByteData(pcm.offsetInBytes);
    final out = Uint8List(pcm.length);
    final obd = out.buffer.asByteData();
    final samples = pcm.length ~/ 2;
    for (int i = 0; i < samples; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      final scaled = (s * volume).round().clamp(-32768, 32767);
      obd.setInt16(i * 2, scaled, Endian.little);
    }
    return out;
  }

  /// Parse WAV → mono PCM16 @ 24 kHz.
  static Uint8List _wavToPcm24k(Uint8List wav) {
    final ByteData hdr = wav.buffer.asByteData(wav.offsetInBytes);

    final int channels = hdr.getInt16(22, Endian.little);
    final int sampleRate = hdr.getInt32(24, Endian.little);
    final int bitsPerSample = hdr.getInt16(34, Endian.little);

    int dataOffset = 0;
    int dataSize = 0;
    for (int i = 12; i < wav.length - 8; i++) {
      if (wav[i] == 0x64 &&
          wav[i + 1] == 0x61 &&
          wav[i + 2] == 0x74 &&
          wav[i + 3] == 0x61) {
        dataSize = hdr.getInt32(i + 4, Endian.little);
        dataOffset = i + 8;
        break;
      }
    }
    if (dataOffset == 0) throw Exception('No data chunk in WAV');

    final int end = (dataOffset + dataSize).clamp(0, wav.length);
    Uint8List pcm = wav.sublist(dataOffset, end);

    if (bitsPerSample != 16) {
      throw Exception('Unsupported WAV bit depth: $bitsPerSample');
    }

    if (channels == 2) {
      final ByteData bd = pcm.buffer.asByteData(pcm.offsetInBytes);
      final int numSamples = pcm.length ~/ 4;
      final Uint8List mono = Uint8List(numSamples * 2);
      final ByteData mbd = mono.buffer.asByteData();
      for (int i = 0; i < numSamples; i++) {
        final int l = bd.getInt16(i * 4, Endian.little);
        final int r = bd.getInt16(i * 4 + 2, Endian.little);
        mbd.setInt16(i * 2, (l + r) ~/ 2, Endian.little);
      }
      pcm = mono;
    }

    if (sampleRate != 24000) {
      pcm = _resamplePcm16(pcm, sampleRate, 24000);
    }

    return pcm;
  }

  static Uint8List _resamplePcm16(Uint8List input, int srcRate, int dstRate) {
    final ByteData bd = input.buffer.asByteData(input.offsetInBytes);
    final int srcCount = input.length ~/ 2;
    final int dstCount = (srcCount * dstRate / srcRate).round();
    final Uint8List out = Uint8List(dstCount * 2);
    final ByteData obd = out.buffer.asByteData();

    final double ratio = srcRate / dstRate;
    for (int i = 0; i < dstCount; i++) {
      final double srcPos = i * ratio;
      final int idx = srcPos.floor();
      final double frac = srcPos - idx;

      final int s0 =
          idx < srcCount ? bd.getInt16(idx * 2, Endian.little) : 0;
      final int s1 = (idx + 1) < srcCount
          ? bd.getInt16((idx + 1) * 2, Endian.little)
          : s0;

      final int sample =
          (s0 + (s1 - s0) * frac).round().clamp(-32768, 32767);
      obd.setInt16(i * 2, sample, Endian.little);
    }
    return out;
  }

  Future<Directory> _storageDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'phonegentic', 'comfort_noise'));
  }

  Future<void> _loadFiles() async {
    try {
      final dir = await _storageDir();
      if (!await dir.exists()) return;
      final entries = dir.listSync().whereType<File>();
      for (final f in entries) {
        _files.add(ComfortNoiseFileInfo(
          f.path,
          p.basenameWithoutExtension(f.path),
        ));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _chunkTimer?.cancel();
    _previewPlayer?.dispose();
    super.dispose();
  }
}
