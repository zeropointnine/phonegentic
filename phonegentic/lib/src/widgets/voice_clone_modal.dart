import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../elevenlabs_api_service.dart';
import '../theme_provider.dart';

class VoiceCloneResult {
  final String voiceId;
  final String name;

  const VoiceCloneResult({required this.voiceId, required this.name});
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
  final String apiKey;
  final String? preRecordedPath;
  final String? sampleParty;

  const _VoiceCloneDialog({
    required this.apiKey,
    this.preRecordedPath,
    this.sampleParty,
  });

  @override
  State<_VoiceCloneDialog> createState() => _VoiceCloneDialogState();
}

class _VoiceCloneDialogState extends State<_VoiceCloneDialog> {
  final _nameCtrl = TextEditingController();
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();

  String? _recordingPath;
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isSubmitting = false;
  String? _error;
  Timer? _recTimer;
  int _recSeconds = 0;
  Duration _playbackPosition = Duration.zero;
  Duration _playbackDuration = Duration.zero;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;

  bool get _hasAudio =>
      _recordingPath != null || widget.preRecordedPath != null;
  String? get _audioPath => _recordingPath ?? widget.preRecordedPath;

  @override
  void initState() {
    super.initState();
    _recordingPath = widget.preRecordedPath;

    if (widget.sampleParty != null) {
      _nameCtrl.text =
          widget.sampleParty == 'host' ? 'My Voice' : 'Remote Voice';
    }

    _positionSub = _player.positionStream.listen((pos) {
      if (mounted) setState(() => _playbackPosition = pos);
    });
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
        if (state.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          _player.pause();
        }
      }
    });
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      setState(() => _error = 'Microphone permission denied');
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final recDir =
        Directory(p.join(dir.path, 'phonegentic', 'voice_samples'));
    await recDir.create(recursive: true);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = p.join(recDir.path, 'mic_sample_$timestamp.wav');

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        numChannels: 1,
        sampleRate: 24000,
      ),
      path: path,
    );

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

    final path = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recordingPath = path;
    });
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.pause();
    } else if (_audioPath != null) {
      final file = File(_audioPath!);
      if (await file.exists()) {
        if (_player.audioSource == null ||
            _playbackPosition >= _playbackDuration) {
          final duration = await _player.setFilePath(_audioPath!);
          if (duration != null) {
            setState(() => _playbackDuration = duration);
          }
        }
        await _player.play();
      }
    }
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a voice name');
      return;
    }
    if (_audioPath == null) {
      setState(() => _error = 'Please record an audio sample');
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
      final voiceId = await ElevenLabsApiService.addVoice(
        widget.apiKey,
        name: name,
        filePaths: [_audioPath!],
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildNameField(),
              const SizedBox(height: 16),
              if (widget.preRecordedPath == null) _buildRecordSection(),
              if (_hasAudio) ...[
                const SizedBox(height: 12),
                _buildPlaybackSection(),
              ],
              if (_error != null) ...[
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
    final subtitle = widget.preRecordedPath != null
        ? 'Create voice from ${widget.sampleParty ?? "call"} sample'
        : 'Record a voice sample to clone';

    return Row(
      children: [
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
            children: [
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
                style: TextStyle(
                    fontSize: 11, color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNameField() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: TextField(
        controller: _nameCtrl,
        autocorrect: false,
        style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Voice name',
          hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildRecordSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Column(
        children: [
          if (_isRecording) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fiber_manual_record,
                    size: 10, color: AppColors.red),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(Duration(seconds: _recSeconds)),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w300,
                    color: AppColors.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Recording... speak clearly',
              style:
                  TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ] else ...[
            Icon(Icons.mic_rounded, size: 32, color: AppColors.textTertiary),
            const SizedBox(height: 8),
            Text(
              _recordingPath != null
                  ? 'Sample recorded. Tap to re-record.'
                  : 'Tap to start recording',
              style:
                  TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: 48,
            height: 48,
            child: Material(
              color: _isRecording ? AppColors.red : AppColors.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _isRecording ? _stopRecording : _startRecording,
                child: Icon(
                  _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                  color: AppColors.onAccent,
                  size: 24,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackSection() {
    final progress = _playbackDuration.inMilliseconds > 0
        ? _playbackPosition.inMilliseconds / _playbackDuration.inMilliseconds
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Material(
              color: AppColors.accent.withValues(alpha: 0.12),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _togglePlayback,
                child: Icon(
                  _isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: AppColors.accent,
                  size: 18,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    backgroundColor: AppColors.border.withValues(alpha: 0.3),
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.accent),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatDuration(_playbackPosition)} / ${_formatDuration(_playbackDuration)}',
                  style: TextStyle(
                      fontSize: 10, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.red.withValues(alpha: 0.2), width: 0.5),
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
      children: [
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
            onPressed:
                _isSubmitting || !_hasAudio ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.crtBlack,
              disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.3),
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
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}
