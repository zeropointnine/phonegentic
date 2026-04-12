import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../agent_service.dart';
import '../elevenlabs_api_service.dart';
import '../theme_provider.dart';
import 'waveform_bars.dart';

class VoiceCloneResult {
  const VoiceCloneResult({required this.voiceId, required this.name});

  final String voiceId;
  final String name;
}

/// Shows the voice clone modal and returns the created voice, or null.
Future<VoiceCloneResult?> showVoiceCloneModal(
  BuildContext context, {
  required String apiKey,
  String? preRecordedPath,
  String? sampleParty,
}) {
  return showDialog<VoiceCloneResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _VoiceCloneDialog(
      apiKey: apiKey,
      preRecordedPath: preRecordedPath,
      sampleParty: sampleParty,
    ),
  );
}

class _VoiceCloneDialog extends StatefulWidget {
  const _VoiceCloneDialog({
    required this.apiKey,
    this.preRecordedPath,
    this.sampleParty,
  });

  final String apiKey;
  final String? preRecordedPath;
  final String? sampleParty;

  @override
  State<_VoiceCloneDialog> createState() => _VoiceCloneDialogState();
}

class _VoiceCloneDialogState extends State<_VoiceCloneDialog>
    with TickerProviderStateMixin {
  static const MethodChannel _tapControl =
      MethodChannel('com.agentic_ai/audio_tap_control');

  final TextEditingController _nameCtrl = TextEditingController();

  late final AnimationController _pulseCtrl;

  AgentService? _agentService;
  StreamSubscription<double>? _levelSub;
  bool _didMuteAgent = false;

  /// Rolling buffer of real-time mic RMS levels — one per waveform bar.
  static const int _barCount = 45;
  final List<double> _micLevels = List<double>.filled(_barCount, 0.0);

  String? _recordingPath;
  String? _uploadedFilePath;
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isSubmitting = false;
  String? _error;
  Timer? _recTimer;
  Timer? _playbackTimer;
  int _recSeconds = 0;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;

  bool get _hasAudio =>
      _recordingPath != null ||
      _uploadedFilePath != null ||
      widget.preRecordedPath != null;

  String? get _audioPath =>
      _recordingPath ?? _uploadedFilePath ?? widget.preRecordedPath;

  String? get _uploadedFileName =>
      _uploadedFilePath != null ? p.basename(_uploadedFilePath!) : null;

  double get _waveAmplitude {
    if (_isRecording) return 0.55 + 0.45 * _pulseCtrl.value;
    if (_isPlaying) return 0.40 + 0.30 * _pulseCtrl.value;
    if (_hasAudio) return 0.15 + 0.05 * _pulseCtrl.value;
    return 0.08 + 0.04 * _pulseCtrl.value;
  }

  @override
  void initState() {
    super.initState();
    _recordingPath = widget.preRecordedPath;

    if (widget.sampleParty != null) {
      _nameCtrl.text =
          widget.sampleParty == 'host' ? 'My Voice' : 'Remote Voice';
    }

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_agentService != null) return;
    try {
      _agentService = context.read<AgentService>();

      // Tap into the real-time mic level stream for the waveform.
      // _emitAudioLevel fires before the mute guard so levels keep flowing.
      _levelSub ??= _agentService!.whisper.audioLevels.listen((double level) {
        if (!mounted) return;
        // Perceptual gain curve: the raw RMS from pro interfaces is very
        // small (0.01–0.15 for normal speech). Boost + power-compress so
        // quiet speech is clearly visible while loud peaks still saturate.
        final double boosted =
            math.pow((level * 2.5).clamp(0.0, 1.0), 0.4).toDouble();
        for (int i = 0; i < _micLevels.length - 1; i++) {
          _micLevels[i] = _micLevels[i + 1];
        }
        _micLevels[_micLevels.length - 1] = boosted;
      });

      if (_agentService!.active && !_agentService!.muted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _didMuteAgent) return;
          _agentService!.toggleMute();
          _didMuteAgent = true;
          debugPrint('[VoiceClone] Muted agent for voice clone session');
        });
      }
    } catch (_) {
      // AgentService not in the Provider tree — skip
    }
  }

  @override
  void dispose() {
    if (_didMuteAgent && _agentService != null && _agentService!.muted) {
      // Defer — dispose runs while the widget tree is locked.
      final AgentService agent = _agentService!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (agent.muted) {
          agent.toggleMute();
          debugPrint('[VoiceClone] Restored agent mute state');
        }
      });
    }
    if (_isPlaying) {
      _tapControl
          .invokeMethod<void>('stopAudioPlayback')
          .catchError((Object _) {});
    }
    if (_isRecording) {
      _tapControl
          .invokeMethod<void>('stopVoiceSample')
          .catchError((Object _) {});
    }
    _levelSub?.cancel();
    _playbackTimer?.cancel();
    _recTimer?.cancel();
    _nameCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Recording ──

  Future<void> _startRecording() async {
    if (_isRecording) return;

    final Directory dir = await getApplicationDocumentsDirectory();
    final Directory recDir =
        Directory(p.join(dir.path, 'phonegentic', 'voice_samples'));
    await recDir.create(recursive: true);

    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final String path = p.join(recDir.path, 'mic_sample_$timestamp.wav');

    try {
      await _tapControl.invokeMethod<void>(
          'startVoiceSample', <String, String>{'path': path, 'party': 'host'});
    } catch (e) {
      debugPrint('[VoiceClone] Failed to start native recording: $e');
      setState(() => _error = 'Failed to start recording');
      return;
    }

    _recordingPath = path;
    _uploadedFilePath = null;
    _recSeconds = 0;
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recSeconds++;
      if (mounted) setState(() {});
    });

    setState(() {
      _isRecording = true;
      _error = null;
    });
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _recTimer?.cancel();
    _recTimer = null;

    try {
      await _tapControl.invokeMethod<void>('stopVoiceSample');
    } catch (e) {
      debugPrint('[VoiceClone] Failed to stop native recording: $e');
    }

    // Let the native side finalize the WAV file before exposing for playback
    await Future<void>.delayed(const Duration(milliseconds: 300));

    setState(() => _isRecording = false);
  }

  // ── File upload ──

  Future<void> _pickFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['wav', 'mp3', 'm4a', 'ogg', 'flac', 'aac'],
    );
    if (result != null && result.files.single.path != null) {
      if (_isPlaying) await _stopNativePlayback();
      setState(() {
        _uploadedFilePath = result.files.single.path;
        _recordingPath = null;
        _playbackPosition = Duration.zero;
        _playbackDuration = Duration.zero;
        _error = null;
      });
    }
  }

  // ── Playback (routed through native AudioTap) ──

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _stopNativePlayback();
      return;
    }
    if (_audioPath == null) return;

    try {
      final File file = File(_audioPath!);
      if (!await file.exists()) {
        setState(() => _error = 'Audio file not found');
        return;
      }

      final Uint8List wav = await file.readAsBytes();
      if (wav.length < 44) {
        setState(() => _error = 'Audio file is too small');
        return;
      }

      final Uint8List pcm = _wavToNativePcm(wav);

      // Duration from mono 16-bit @ 24 kHz PCM
      const int playbackRate = 24000;
      final int totalSamples = pcm.length ~/ 2;
      final Duration totalDuration = Duration(
        milliseconds: (totalSamples * 1000 / playbackRate).round(),
      );

      setState(() {
        _playbackDuration = totalDuration;
        _playbackPosition = Duration.zero;
        _isPlaying = true;
        _error = null;
      });

      debugPrint('[VoiceClone] Playing ${pcm.length} bytes '
          '(${totalDuration.inSeconds}s) via native AudioTap');

      // Send PCM chunks to native AudioTap playback engine
      const int chunkBytes = 48000; // ~1 s at 24 kHz mono 16-bit
      for (int i = 0; i < pcm.length; i += chunkBytes) {
        if (!_isPlaying) break;
        final int end = (i + chunkBytes).clamp(0, pcm.length);
        await _tapControl.invokeMethod<void>(
          'playAudioResponse',
          pcm.sublist(i, end),
        );
      }

      // Track position via elapsed wall-clock time
      final DateTime start = DateTime.now();
      _playbackTimer?.cancel();
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: 80),
        (_) {
          if (!mounted || !_isPlaying) {
            _playbackTimer?.cancel();
            return;
          }
          final Duration elapsed = DateTime.now().difference(start);
          if (elapsed >= totalDuration) {
            _playbackTimer?.cancel();
            setState(() {
              _playbackPosition = totalDuration;
              _isPlaying = false;
            });
          } else {
            setState(() => _playbackPosition = elapsed);
          }
        },
      );
    } catch (e) {
      debugPrint('[VoiceClone] Playback failed: $e');
      if (mounted) {
        setState(() {
          _error =
              'Playback failed: ${e.toString().replaceFirst("Exception: ", "")}';
          _isPlaying = false;
        });
      }
    }
  }

  Future<void> _stopNativePlayback() async {
    _playbackTimer?.cancel();
    try {
      await _tapControl.invokeMethod<void>('stopAudioPlayback');
    } catch (_) {}
    if (mounted) setState(() => _isPlaying = false);
  }

  // ── WAV → PCM conversion for native playback ──

  /// Reads a WAV file, mixes to mono, resamples to 24 kHz PCM16 — the format
  /// expected by the AudioTap's `playAudioResponse` handler.
  static Uint8List _wavToNativePcm(Uint8List wav) {
    final ByteData hdr = wav.buffer.asByteData(wav.offsetInBytes);

    final int channels = hdr.getInt16(22, Endian.little);
    final int sampleRate = hdr.getInt32(24, Endian.little);
    final int bitsPerSample = hdr.getInt16(34, Endian.little);

    // Locate the 'data' chunk (may follow extra sub-chunks)
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

    // Stereo → mono
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

    // Resample to 24 kHz if needed
    if (sampleRate != 24000) {
      pcm = _resamplePcm16(pcm, sampleRate, 24000);
    }

    return pcm;
  }

  /// Linear-interpolation resampler for mono PCM16 data.
  static Uint8List _resamplePcm16(
      Uint8List input, int srcRate, int dstRate) {
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

  // ── Submit ──

  Future<void> _submit() async {
    final String name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a voice name');
      return;
    }
    if (_audioPath == null) {
      setState(() => _error = 'Please record or upload an audio sample');
      return;
    }
    if (widget.apiKey.isEmpty) {
      setState(() => _error = 'ElevenLabs API key is not configured');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final String voiceId = await ElevenLabsApiService.addVoice(
        widget.apiKey,
        name: name,
        filePaths: <String>[_audioPath!],
      );

      if (mounted) {
        Navigator.of(context)
            .pop(VoiceCloneResult(voiceId: voiceId, name: name));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildHeader(),
              const SizedBox(height: 20),
              _buildNameField(),
              const SizedBox(height: 16),
              if (widget.preRecordedPath == null)
                _buildRecordSection()
              else
                _buildPreRecordedWaveform(),
              if (_hasAudio && !_isRecording) ...<Widget>[
                const SizedBox(height: 12),
                _buildPlaybackSection(),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                _buildError(),
              ],
              const SizedBox(height: 20),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final String subtitle = widget.preRecordedPath != null
        ? 'Create voice from ${widget.sampleParty ?? "call"} sample'
        : 'Record or upload a voice sample';

    return Row(
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: AppColors.accent.withValues(alpha: 0.12),
          ),
          child: Icon(Icons.record_voice_over_rounded,
              size: 18, color: AppColors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Clone Voice',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style:
                    TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNameField() {
    return TextField(
      controller: _nameCtrl,
      autocorrect: false,
      style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Voice name',
        hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
        filled: true,
        fillColor: AppColors.card,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
              color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.accent, width: 1),
        ),
      ),
    );
  }

  Widget _buildWaveform({double height = 48}) {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (BuildContext context, Widget? child) {
        return WaveformBars(
          micLevels: _micLevels,
          barCount: _barCount,
          height: height,
          amplitude: _waveAmplitude,
          liveMode: _isRecording,
        );
      },
    );
  }

  Widget _buildPreRecordedWaveform() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Column(
        children: <Widget>[
          _buildWaveform(),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.audio_file_rounded,
                  size: 14, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                '${widget.sampleParty ?? "Call"} recording ready',
                style:
                    TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: _isRecording
                ? AppColors.accent.withValues(alpha: 0.3)
                : AppColors.border.withValues(alpha: 0.5),
            width: _isRecording ? 1 : 0.5),
      ),
      child: Column(
        children: <Widget>[
          _buildWaveform(),
          const SizedBox(height: 14),

          // Timer or status
          if (_isRecording)
            _buildMacosTimer(_recSeconds)
          else if (_uploadedFileName != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.audio_file_rounded,
                    size: 14, color: AppColors.accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _uploadedFileName!,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else if (_recordingPath != null)
            Text(
              'Sample recorded — tap to re-record',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            )
          else
            Text(
              'Ready to capture',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),

          const SizedBox(height: 16),

          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _buildCircleAction(
                icon:
                    _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                color: _isRecording ? AppColors.red : AppColors.accent,
                size: 48,
                onTap: _isRecording ? _stopRecording : _startRecording,
                label: _isRecording ? 'Stop' : 'Record',
              ),
              if (!_isRecording) ...<Widget>[
                const SizedBox(width: 28),
                _buildCircleAction(
                  icon: Icons.file_upload_outlined,
                  color: AppColors.textSecondary,
                  size: 48,
                  onTap: _pickFile,
                  label: 'Upload',
                  outlined: true,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCircleAction({
    required IconData icon,
    required Color color,
    required double size,
    required VoidCallback onTap,
    required String label,
    bool outlined = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        HoverButton(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size / 2),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: outlined ? Colors.transparent : color,
              border: outlined
                  ? Border.all(
                      color: color.withValues(alpha: 0.5), width: 1.5)
                  : null,
            ),
            child: Icon(
              icon,
              color: outlined ? color : AppColors.onAccent,
              size: size * 0.5,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildMacosTimer(int totalSeconds) {
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;

    final String hh = hours.toString().padLeft(2, '0');
    final String mm = minutes.toString().padLeft(2, '0');
    final String ss = seconds.toString().padLeft(2, '0');

    final bool hoursZero = hours == 0;
    final bool minutesZero = hours == 0 && minutes == 0;

    final TextStyle dimStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w200,
      fontFamily: AppColors.timerFontFamily,
      fontFamilyFallback: AppColors.timerFontFamilyFallback,
      color: AppColors.textTertiary.withValues(alpha: 0.35),
      decoration: TextDecoration.lineThrough,
      decorationColor: AppColors.textTertiary.withValues(alpha: 0.25),
      decorationThickness: 1.5,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    final TextStyle brightStyle = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w300,
      fontFamily: AppColors.timerFontFamily,
      fontFamilyFallback: AppColors.timerFontFamilyFallback,
      color: AppColors.textPrimary,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    final TextStyle dimSep = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w200,
      fontFamily: AppColors.timerFontFamily,
      fontFamilyFallback: AppColors.timerFontFamilyFallback,
      color: AppColors.textTertiary.withValues(alpha: 0.35),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    final TextStyle brightSep = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w300,
      fontFamily: AppColors.timerFontFamily,
      fontFamilyFallback: AppColors.timerFontFamilyFallback,
      color: AppColors.textPrimary.withValues(alpha: 0.5),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PulsingDot(color: AppColors.red, animation: _pulseCtrl),
        const SizedBox(width: 10),
        Text.rich(
          TextSpan(
            children: <TextSpan>[
              TextSpan(text: hh, style: hoursZero ? dimStyle : brightStyle),
              TextSpan(text: ':', style: hoursZero ? dimSep : brightSep),
              TextSpan(
                  text: mm, style: minutesZero ? dimStyle : brightStyle),
              TextSpan(text: ':', style: minutesZero ? dimSep : brightSep),
              TextSpan(text: ss, style: brightStyle),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackSection() {
    final double progress = _playbackDuration.inMilliseconds > 0
        ? _playbackPosition.inMilliseconds / _playbackDuration.inMilliseconds
        : 0.0;

    final String posStr = _fmtCompact(_playbackPosition);
    final String durStr = _fmtCompact(_playbackDuration);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: <Widget>[
          HoverButton(
            onTap: _togglePlayback,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent.withValues(alpha: 0.12),
              ),
              child: Icon(
                _isPlaying
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
                color: AppColors.accent,
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.border.withValues(alpha: 0.3),
                thumbColor: AppColors.accent,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                overlayColor: AppColors.accent.withValues(alpha: 0.12),
              ),
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                onChanged: _isPlaying ? null : (double _) {},
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$posStr / $durStr',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textTertiary,
              fontFamily: AppColors.timerFontFamily,
              fontFamilyFallback: AppColors.timerFontFamilyFallback,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtCompact(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: AppColors.red.withValues(alpha: 0.2), width: 0.5),
      ),
      child: Text(
        _error!,
        style: TextStyle(fontSize: 12, color: AppColors.red),
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 36,
          child: ElevatedButton(
            onPressed: _isSubmitting || !_hasAudio ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.crtBlack,
              disabledBackgroundColor:
                  AppColors.accent.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
            child: _isSubmitting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.crtBlack),
                    ),
                  )
                : const Text('Create Voice',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

// ── Pulsing recording dot ──

class _PulsingDot extends StatelessWidget {
  const _PulsingDot({required this.color, required this.animation});

  final Color color;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.5 + 0.5 * animation.value),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: color.withValues(alpha: 0.3 * animation.value),
                blurRadius: 6,
                spreadRadius: 2,
              ),
            ],
          ),
        );
      },
    );
  }
}
