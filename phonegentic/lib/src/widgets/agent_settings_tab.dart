import 'dart:async';
import 'dart:io';
import 'dart:math' show pi;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../agent_config_service.dart';
import '../agent_service.dart';
import '../comfort_noise_service.dart';
import '../db/pocket_tts_voice_db.dart';
import '../elevenlabs_api_service.dart';
import '../elevenlabs_tts_service.dart';
import '../kokoro_tts_service.dart';
import '../build_config.dart';
import '../whisperkit_stt_service.dart';
import '../pocket_tts_service.dart';
import '../theme_provider.dart';
import 'comfort_noise_picker.dart';
import 'voice_clone_modal.dart';

enum _PipelineSection { none, stt, llm, tts }

class AgentSettingsTab extends StatefulWidget {
  const AgentSettingsTab({super.key});

  @override
  State<AgentSettingsTab> createState() => _AgentSettingsTabState();
}

class _AgentSettingsTabState extends State<AgentSettingsTab> {
  VoiceAgentConfig _voice = const VoiceAgentConfig();
  TextAgentConfig _text = const TextAgentConfig();
  TtsConfig _tts = const TtsConfig();
  SttConfig _stt = const SttConfig();
  AgentMutePolicy _mutePolicy = AgentMutePolicy.autoToggle;
  ComfortNoiseConfig _comfortNoise = const ComfortNoiseConfig();
  _PipelineSection _expandedSection = _PipelineSection.none;
  bool _loaded = false;
  bool _dirty = false;
  AgentService? _agent;

  final _voiceKeyCtrl = TextEditingController();
  final _voiceInstructionsCtrl = TextEditingController();
  final _textOpenaiKeyCtrl = TextEditingController();
  final _textClaudeKeyCtrl = TextEditingController();
  final _textCustomKeyCtrl = TextEditingController();
  final _textCustomEndpointCtrl = TextEditingController();
  final _textCustomModelCtrl = TextEditingController();
  final _systemPromptCtrl = TextEditingController();
  final _ttsApiKeyCtrl = TextEditingController();
  final _ttsVoiceIdCtrl = TextEditingController();


  bool _whisperModelAvailable = false;

  List<ElevenLabsVoice>? _voiceList;
  bool _voiceListLoading = false;
  String? _voiceListError;

  List<PocketTtsVoice> _pocketVoiceList = [];
  bool _pocketVoiceListLoading = false;

  bool _pocketPreviewPlaying = false;
  Object? _pocketPreviewToken;
  StreamSubscription? _pocketPreviewAudioSub;

  bool _elevenLabsPreviewPlaying = false;
  Object? _elevenLabsPreviewToken;
  ElevenLabsTtsService? _previewElevenLabs;
  StreamSubscription<Uint8List>? _previewElevenLabsAudioSub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _agent ??= context.read<AgentService>();
  }

  @override
  void dispose() {
    if (_dirty) {
      _agent?.reconnect();
    }
    _voiceKeyCtrl.dispose();
    _voiceInstructionsCtrl.dispose();
    _textOpenaiKeyCtrl.dispose();
    _textClaudeKeyCtrl.dispose();
    _textCustomKeyCtrl.dispose();
    _textCustomEndpointCtrl.dispose();
    _textCustomModelCtrl.dispose();
    _systemPromptCtrl.dispose();
    _ttsApiKeyCtrl.dispose();
    _ttsVoiceIdCtrl.dispose();
    _stopPocketPreview(disposing: true);
    _stopElevenLabsPreview(disposing: true);
    super.dispose();
  }

  // PCM16 24 kHz mono = 48 000 bytes per second = 48 bytes per millisecond.
  static const double _pcm16BytesPerMs = 48.0;

  Future<void> _load() async {
    final v = await AgentConfigService.loadVoiceConfig();
    final t = await AgentConfigService.loadTextConfig();
    final tts = await AgentConfigService.loadTtsConfig();
    final stt = await AgentConfigService.loadSttConfig();
    final mp = await AgentConfigService.loadMutePolicy();
    final cn = await AgentConfigService.loadComfortNoiseConfig();
    if (!mounted) return;
    setState(() {
      _voice = v;
      _text = t;
      _tts = tts;
      _stt = stt;
      _mutePolicy = mp;
      _comfortNoise = cn;
      _voiceKeyCtrl.text = v.apiKey;
      _voiceInstructionsCtrl.text = v.instructions;
      _textOpenaiKeyCtrl.text = t.openaiApiKey;
      _textClaudeKeyCtrl.text = t.claudeApiKey;
      _textCustomKeyCtrl.text = t.customApiKey;
      _textCustomEndpointCtrl.text = t.customEndpointUrl;
      _textCustomModelCtrl.text = t.customModel;
      _systemPromptCtrl.text = t.systemPrompt;
      _ttsApiKeyCtrl.text = tts.elevenLabsApiKey;
      _ttsVoiceIdCtrl.text = tts.elevenLabsVoiceId;
      _loaded = true;
    });
    if (BuildConfig.onDeviceModelsSupported) {
      final available = await WhisperKitSttService.isModelAvailable(
          modelSize: stt.whisperKitModelSize);
      if (mounted) setState(() => _whisperModelAvailable = available);
    }
    if (tts.elevenLabsApiKey.isNotEmpty) {
      _fetchVoiceList();
    }
    _fetchPocketVoiceList();
  }

  Future<void> _fetchVoiceList() async {
    final apiKey = _tts.elevenLabsApiKey;
    if (apiKey.isEmpty) {
      setState(() {
        _voiceList = null;
        _voiceListError = null;
      });
      return;
    }
    setState(() {
      _voiceListLoading = true;
      _voiceListError = null;
    });
    try {
      final voices = await ElevenLabsApiService.listVoices(apiKey);
      if (mounted) {
        setState(() {
          _voiceList = voices;
          _voiceListLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _voiceListLoading = false;
          _voiceListError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _fetchPocketVoiceList() async {
    setState(() => _pocketVoiceListLoading = true);
    try {
      final voices = await PocketTtsVoiceDb.listVoices();
      if (mounted) {
        setState(() {
          _pocketVoiceList = voices;
          _pocketVoiceListLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[AgentSettings] Failed to load pocket voices: $e');
      if (mounted) setState(() => _pocketVoiceListLoading = false);
    }
  }

  static const _previewText =
      'The birch canoe slid on the smooth planks, and the juice of lemons '
      'makes fine punch. She had your dark blue jacket before the big show, '
      'and those crazy things were given to me. The quick brown fox jumps '
      'over a lazy dog, catching the breeze with joy.';

  static const _tapChannel =
      MethodChannel('com.agentic_ai/audio_tap_control');

  static const _pocketChannel =
      MethodChannel('com.agentic_ai/pocket_tts');
  static const _pocketAudioChannel =
      EventChannel('com.agentic_ai/pocket_tts_audio');

  Future<void> _playPocketPreview() async {
    if (_pocketPreviewPlaying) {
      _stopPocketPreview();
      return;
    }

    final voiceId = _tts.pocketTtsVoiceId;
    if (voiceId == null) return;

    final voice = _pocketVoiceList
        .cast<PocketTtsVoice?>()
        .firstWhere((v) => v!.id == voiceId, orElse: () => null);
    if (voice == null) return;

    // Flush any leftover audio from a previous preview.
    _tapChannel.invokeMethod('stopAudioPlayback').catchError((_) {});

    final token = Object();
    _pocketPreviewToken = token;
    setState(() => _pocketPreviewPlaying = true);

    try {
      // Ensure the native engine is running (idempotent on the native side
      // when already initialized — replaces engine only if needed).
      final ok =
          await _pocketChannel.invokeMethod<bool>('initialize') ?? false;
      if (!ok || _pocketPreviewToken != token) {
        _resetPocketPreview(token);
        return;
      }

      // Import voice embedding / clone voice.
      final tag = 'preview_${voice.id}';
      if (voice.embedding != null && voice.embedding!.isNotEmpty) {
        await _pocketChannel.invokeMethod('importVoiceEmbedding', {
          'voiceId': tag,
          'embeddingData': Uint8List.fromList(voice.embedding!),
        });
        await _pocketChannel.invokeMethod('setVoice', {'voice': tag});
      } else if (voice.audioPath != null && voice.audioPath!.isNotEmpty) {
        final pcm = await PocketTtsService.decodeAudioFileToPcm16(
            voice.audioPath!);
        if (pcm.isNotEmpty) {
          await _pocketChannel.invokeMethod('encodeVoice', {
            'audioData': pcm,
            'voiceId': tag,
          });
          await _pocketChannel.invokeMethod('setVoice', {'voice': tag});
        }
      }

      if (_pocketPreviewToken != token) return;

      // Subscribe to audio chunks from the native EventChannel and pipe
      // them straight to the playback engine.
      int totalPcmBytes = 0;
      final sw = Stopwatch()..start();
      _pocketPreviewAudioSub =
          _pocketAudioChannel.receiveBroadcastStream().listen((data) {
        if (data is Uint8List && data.isNotEmpty) {
          _tapChannel.invokeMethod('playAudioResponse', data);
          totalPcmBytes += data.length;
        }
      });

      // Synthesize the preview text (blocks until native synthesis finishes).
      await _pocketChannel.invokeMethod('synthesize', {
        'text': _previewText,
        'voice': tag,
      });

      if (_pocketPreviewToken != token) return;

      // Synthesis is done but the native AVAudioPlayerNode may still be
      // draining queued buffers.  Estimate remaining playback time.
      final totalDurationMs = (totalPcmBytes / _pcm16BytesPerMs).ceil();
      final remainingMs = totalDurationMs - sw.elapsedMilliseconds + 400;
      if (remainingMs > 0) {
        await Future.delayed(Duration(milliseconds: remainingMs));
      }

      _resetPocketPreview(token);
    } catch (e) {
      debugPrint('[AgentSettings] Pocket preview failed: $e');
      _resetPocketPreview(token);
    }
  }

  void _resetPocketPreview(Object token) {
    if (_pocketPreviewToken != token) return;
    _pocketPreviewAudioSub?.cancel();
    _pocketPreviewAudioSub = null;
    _pocketPreviewToken = null;
    _pocketPreviewPlaying = false;
    if (mounted) setState(() {});
  }

  void _stopPocketPreview({bool disposing = false}) {
    final sub = _pocketPreviewAudioSub;
    _pocketPreviewAudioSub = null;
    _pocketPreviewToken = null;
    _pocketPreviewPlaying = false;
    sub?.cancel();
    _tapChannel.invokeMethod('stopAudioPlayback').catchError((_) {});
    if (!disposing && mounted) setState(() {});
  }

  Future<void> _playElevenLabsPreview() async {
    if (_elevenLabsPreviewPlaying) {
      _stopElevenLabsPreview();
      return;
    }

    if (_tts.elevenLabsApiKey.isEmpty || _tts.elevenLabsVoiceId.isEmpty) {
      return;
    }

    // Flush leftover audio from a previous preview.
    _tapChannel.invokeMethod('stopAudioPlayback').catchError((_) {});

    final token = Object();
    _elevenLabsPreviewToken = token;
    setState(() => _elevenLabsPreviewPlaying = true);

    try {
      final el = ElevenLabsTtsService(config: _tts);
      _previewElevenLabs = el;

      int totalPcmBytes = 0;
      final sw = Stopwatch()..start();

      _previewElevenLabsAudioSub = el.audioChunks.listen((pcm) {
        _tapChannel.invokeMethod('playAudioResponse', pcm);
        totalPcmBytes += pcm.length;
      });

      el.startGeneration();
      el.sendText(_previewText);
      el.endGeneration();

      await el.speakingState.firstWhere((playing) => !playing).timeout(
        const Duration(seconds: 30),
        onTimeout: () => false,
      );

      if (_elevenLabsPreviewToken != token) return;

      // Wait for native playback to drain queued buffers.
      final totalDurationMs = (totalPcmBytes / _pcm16BytesPerMs).ceil();
      final remainingMs = totalDurationMs - sw.elapsedMilliseconds + 400;
      if (remainingMs > 0) {
        await Future.delayed(Duration(milliseconds: remainingMs));
      }

      _resetElevenLabsPreview(token);
      el.dispose();
    } catch (e) {
      debugPrint('[AgentSettings] ElevenLabs preview failed: $e');
      _resetElevenLabsPreview(token);
    }
  }

  void _resetElevenLabsPreview(Object token) {
    if (_elevenLabsPreviewToken != token) return;
    _previewElevenLabsAudioSub?.cancel();
    _previewElevenLabsAudioSub = null;
    _previewElevenLabs = null;
    _elevenLabsPreviewToken = null;
    _elevenLabsPreviewPlaying = false;
    if (mounted) setState(() {});
  }

  void _stopElevenLabsPreview({bool disposing = false}) {
    final el = _previewElevenLabs;
    final sub = _previewElevenLabsAudioSub;
    _previewElevenLabs = null;
    _previewElevenLabsAudioSub = null;
    _elevenLabsPreviewToken = null;
    _elevenLabsPreviewPlaying = false;
    sub?.cancel();
    el?.dispose();
    _tapChannel.invokeMethod('stopAudioPlayback').catchError((_) {});
    if (!disposing && mounted) setState(() {});
  }

  void _updateVoice(VoiceAgentConfig v) {
    setState(() => _voice = v);
    AgentConfigService.saveVoiceConfig(v);
    _dirty = true;
  }

  void _updateText(TextAgentConfig t) {
    setState(() => _text = t);
    AgentConfigService.saveTextConfig(t);
    _dirty = true;
  }

  void _updateTts(TtsConfig t) {
    setState(() => _tts = t);
    AgentConfigService.saveTtsConfig(t);
    _dirty = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        return ListView(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 14),
                        child: Text(
                          'AGENT WORKFLOW',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textTertiary,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      _buildPipelineSection(wide),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: AppColors.border.withValues(alpha: 0.7),
                        ),
                      ),
                      Text(
                        'GLOBAL AGENT SETTINGS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textTertiary,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildBottomSections(wide),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _toggleSection(_PipelineSection section) {
    setState(() {
      _expandedSection =
          _expandedSection == section ? _PipelineSection.none : section;
    });
  }

  // ───── Pipeline Section ─────

  static const _flipDuration = Duration(milliseconds: 400);

  Widget _buildPipelineSection(bool wide) {
    final isExpanded = _expandedSection != _PipelineSection.none;
    final llmTtsGrayed = _voice.enabled && !_text.enabled;

    final sections = <_PipelineSection>[
      _PipelineSection.stt,
      _PipelineSection.llm,
      _PipelineSection.tts,
    ];

    if (isExpanded) {
      return _buildExpandedView(wide);
    }

    final tiles = <Widget>[];
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      final enabled = s == _PipelineSection.stt || !llmTtsGrayed;
      tiles.add(
        wide
            ? Expanded(child: _buildSmallTile(s, enabled: enabled))
            : _buildSmallTile(s, enabled: enabled),
      );
      if (i < sections.length - 1) {
        tiles.add(Padding(
          padding: EdgeInsets.symmetric(
              horizontal: wide ? 6 : 0, vertical: wide ? 0 : 6),
          child: Icon(
            wide
                ? Icons.arrow_forward_rounded
                : Icons.arrow_downward_rounded,
            size: 18,
            color: AppColors.textTertiary.withValues(alpha: 0.6),
          ),
        ));
      }
    }

    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: tiles,
      );
    }
    return Column(children: tiles);
  }

  Widget _buildSmallTile(_PipelineSection section, {required bool enabled}) {
    final (icon, label, sub, model, badge, configured) = _tileData(section);

    return GestureDetector(
      onTap: enabled ? () => _toggleSection(section) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.35,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            configured ? AppColors.green : AppColors.orange,
                      ),
                    ),
                    Icon(Icons.edit_rounded,
                        size: 12, color: AppColors.textTertiary),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: AppColors.card,
                  ),
                  child: Center(child: icon),
                ),
                const SizedBox(height: 8),
                Text(label,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.3,
                    )),
                const SizedBox(height: 2),
                Text(sub,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                    textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text(model,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (badge.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: AppColors.textTertiary.withValues(alpha: 0.1),
                    ),
                    child: Text(badge,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textTertiary,
                          letterSpacing: 0.3,
                        )),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ───── Expanded (flipped) view ─────

  Widget _buildExpandedView(bool wide) {
    final section = _expandedSection;
    final (icon, label, _, _, _, _) = _tileData(section);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: _flipDuration,
      curve: Curves.easeInOut,
      builder: (context, t, child) {
        final angle = t * pi;
        final showBack = angle >= pi / 2;

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle),
          child: showBack
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(pi),
                  child: child!,
                )
              : _buildCollapsedPlaceholder(section, wide),
        );
      },
      child: _buildSettingsCard(section, icon, label),
    );
  }

  Widget _buildCollapsedPlaceholder(_PipelineSection section, bool wide) {
    final llmTtsGrayed = _voice.enabled && !_text.enabled;
    final sections = [
      _PipelineSection.stt,
      _PipelineSection.llm,
      _PipelineSection.tts,
    ];

    final tiles = <Widget>[];
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      final enabled = s == _PipelineSection.stt || !llmTtsGrayed;
      tiles.add(
        wide
            ? Expanded(
                child: Opacity(
                    opacity: s == section ? 1.0 : 0.3,
                    child: _buildSmallTile(s, enabled: enabled)))
            : Opacity(
                opacity: s == section ? 1.0 : 0.3,
                child: _buildSmallTile(s, enabled: enabled)),
      );
      if (i < sections.length - 1) {
        tiles.add(Padding(
          padding: EdgeInsets.symmetric(
              horizontal: wide ? 6 : 0, vertical: wide ? 0 : 6),
          child: Icon(
            wide
                ? Icons.arrow_forward_rounded
                : Icons.arrow_downward_rounded,
            size: 18,
            color: AppColors.textTertiary.withValues(alpha: 0.3),
          ),
        ));
      }
    }

    if (wide) {
      return Row(
          crossAxisAlignment: CrossAxisAlignment.center, children: tiles);
    }
    return Column(children: tiles);
  }

  Widget _buildSettingsCard(
      _PipelineSection section, Widget icon, String label) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.accent.withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: _smallIcon(section, active: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2,
                          )),
                      const SizedBox(height: 2),
                      Text(_sectionSubtitle(section),
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                HoverButton(
                  onTap: () => _toggleSection(section),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: AppColors.card,
                    ),
                    child: Icon(Icons.close_rounded,
                        size: 14, color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          Divider(
              height: 0.5,
              color: AppColors.border.withValues(alpha: 0.5)),
          ..._sectionContent(section),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ───── Tile data helpers ─────

  (Widget icon, String label, String subtitle, String model, String badge,
      bool configured) _tileData(_PipelineSection section) {
    return switch (section) {
      _PipelineSection.stt => (
          Icon(Icons.hearing_rounded, size: 22, color: AppColors.textPrimary),
          'STT',
          'Speech to Text Recognition',
          _sttModelInfo,
          _sttBadge,
          _voice.isConfigured,
        ),
      _PipelineSection.llm => (
          SvgPicture.asset('assets/brain.svg',
              width: 22,
              height: 22,
              colorFilter: ColorFilter.mode(
                  AppColors.textPrimary, BlendMode.srcIn)),
          'LLM',
          'Thinking Model',
          _llmModelInfo,
          'API',
          _text.isConfigured,
        ),
      _PipelineSection.tts => (
          Icon(Icons.spatial_audio_off_rounded,
              size: 22, color: AppColors.textPrimary),
          'TTS',
          'Text to Speech',
          _ttsModelInfo,
          _ttsBadge,
          _tts.isConfigured || (_voice.enabled && !_text.enabled),
        ),
      _PipelineSection.none => (
          const SizedBox.shrink(),
          '',
          '',
          '',
          '',
          false
        ),
    };
  }

  Widget _smallIcon(_PipelineSection section, {bool active = false}) {
    final color = active ? AppColors.accent : AppColors.textPrimary;
    return switch (section) {
      _PipelineSection.stt => Icon(Icons.hearing_rounded, size: 17, color: color),
      _PipelineSection.llm => SvgPicture.asset('assets/brain.svg',
          width: 17,
          height: 17,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn)),
      _PipelineSection.tts =>
        Icon(Icons.spatial_audio_off_rounded, size: 17, color: color),
      _PipelineSection.none => const SizedBox.shrink(),
    };
  }

  String _sectionSubtitle(_PipelineSection section) {
    return switch (section) {
      _PipelineSection.stt => 'Voice Agent & STT Configuration',
      _PipelineSection.llm => 'Text Agent Configuration',
      _PipelineSection.tts => 'TTS Configuration',
      _PipelineSection.none => '',
    };
  }

  List<Widget> _sectionContent(_PipelineSection section) {
    return switch (section) {
      _PipelineSection.stt => _buildSttContent(),
      _PipelineSection.llm => _buildLlmContent(),
      _PipelineSection.tts => _buildTtsContent(),
      _PipelineSection.none => [],
    };
  }

  // ───── STT Expanded Content ─────

  List<Widget> _buildSttContent() {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _voice.enabled
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.hearing_rounded,
                  size: 17,
                  color: _voice.enabled
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice Agent',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.2,
                      )),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text('OpenAI Realtime',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary)),
                    const SizedBox(width: 8),
                    _configuredBadge(_voice.isConfigured),
                  ]),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: Switch.adaptive(
                value: _voice.enabled,
                onChanged: (v) =>
                    _updateVoice(_voice.copyWith(enabled: v)),
                activeTrackColor: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
      if (_voice.enabled) ...[
        _divider(),
        _buildKeyField('API Key', _voiceKeyCtrl, (val) {
          _updateVoice(_voice.copyWith(apiKey: val));
        }),
      ],
      _divider(),
      _buildDropdown<String>(
        'Model',
        _voice.model,
        const {
          'gpt-4o-mini-realtime-preview': 'GPT-4o Mini Realtime',
          'gpt-4o-realtime-preview': 'GPT-4o Realtime',
        },
        (v) => _updateVoice(_voice.copyWith(model: v)),
      ),
      _divider(),
      _buildDropdown<String>(
        'Voice',
        _voice.voice,
        const {
          'coral': 'Coral',
          'alloy': 'Alloy',
          'ash': 'Ash',
          'ballad': 'Ballad',
          'echo': 'Echo',
          'sage': 'Sage',
          'shimmer': 'Shimmer',
          'verse': 'Verse',
          'marin': 'Marin',
          'cedar': 'Cedar',
        },
        (v) => _updateVoice(_voice.copyWith(voice: v)),
      ),
      _divider(),
      _buildDropdown<TranscriptionTarget>(
        'Listen To',
        _voice.target,
        const {
          TranscriptionTarget.both: 'Both Sides',
          TranscriptionTarget.localOnly: 'Local Only',
          TranscriptionTarget.remoteOnly: 'Remote Only',
        },
        (v) => _updateVoice(_voice.copyWith(target: v)),
      ),
      _divider(),
      _buildInstructionsField(),
      if (BuildConfig.onDeviceModelsSupported) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('STT PROVIDER',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textTertiary,
                letterSpacing: 0.5,
              )),
        ),
        _buildSttProviderChips(),
        if (_stt.provider == SttProvider.whisperKit) ...[
          _divider(),
          _buildDropdown<String>(
            'Model Size',
            _stt.whisperKitModelSize,
            const {
              'tiny': 'Tiny (~75 MB, fastest)',
              'base': 'Base (~140 MB, balanced)',
              'small': 'Small (~460 MB, best accuracy)',
              'large-v3-turbo': 'Large v3 Turbo (~1.6 GB, most accurate)',
            },
            (v) => _updateStt(_stt.copyWith(whisperKitModelSize: v)),
          ),
        ],
      ],
    ];
  }

  Widget _buildSttProviderChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Provider',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('OpenAI Realtime',
                      style: TextStyle(fontSize: 12)),
                  selected: _stt.provider == SttProvider.openaiRealtime,
                  onSelected: (_) => _updateStt(
                      _stt.copyWith(provider: SttProvider.openaiRealtime)),
                  selectedColor: AppColors.accent.withValues(alpha: 0.2),
                  backgroundColor: AppColors.card,
                  side: BorderSide(
                    color: _stt.provider == SttProvider.openaiRealtime
                        ? AppColors.accent
                        : AppColors.border.withValues(alpha: 0.5),
                    width: 0.5,
                  ),
                ),
                if (BuildConfig.onDeviceModelsSupported &&
                    _whisperModelAvailable)
                  ChoiceChip(
                    label: const Text('WhisperKit (On-Device)',
                        style: TextStyle(fontSize: 12)),
                    selected: _stt.provider == SttProvider.whisperKit,
                    onSelected: (_) => _updateStt(
                        _stt.copyWith(provider: SttProvider.whisperKit)),
                    selectedColor: AppColors.accent.withValues(alpha: 0.2),
                    backgroundColor: AppColors.card,
                    side: BorderSide(
                      color: _stt.provider == SttProvider.whisperKit
                          ? AppColors.accent
                          : AppColors.border.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───── LLM Expanded Content ─────

  List<Widget> _buildLlmContent() {
    final isClaude = _text.provider == TextAgentProvider.claude;
    final isOpenai = _text.provider == TextAgentProvider.openai;
    final isCustom = _text.provider == TextAgentProvider.custom;

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _text.enabled
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Center(
                child: SvgPicture.asset('assets/brain.svg',
                    width: 17,
                    height: 17,
                    colorFilter: ColorFilter.mode(
                      _text.enabled
                          ? AppColors.accent
                          : AppColors.textTertiary,
                      BlendMode.srcIn,
                    )),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Text Agent',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.2,
                      )),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text(
                        switch (_text.provider) {
                          TextAgentProvider.openai => 'OpenAI',
                          TextAgentProvider.claude => 'Claude',
                          TextAgentProvider.custom => 'Custom',
                        },
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary)),
                    const SizedBox(width: 8),
                    _configuredBadge(_text.isConfigured),
                  ]),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: Switch.adaptive(
                value: _text.enabled,
                onChanged: (v) =>
                    _updateText(_text.copyWith(enabled: v)),
                activeTrackColor: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
      _divider(),
      _buildDropdown<TextAgentProvider>(
        'Provider',
        _text.provider,
        const {
          TextAgentProvider.claude: 'Claude',
          TextAgentProvider.openai: 'OpenAI',
          TextAgentProvider.custom: 'Custom',
        },
        (v) => _updateText(_text.copyWith(provider: v)),
      ),
      _divider(),
      if (isOpenai) ...[
        _buildKeyField('API Key', _textOpenaiKeyCtrl, (val) {
          _updateText(_text.copyWith(openaiApiKey: val));
        }),
        _divider(),
        _buildDropdown<String>(
          'Model',
          _text.openaiModel,
          const {
            'gpt-4o': 'GPT-4o',
            'gpt-4o-mini': 'GPT-4o Mini',
          },
          (v) => _updateText(_text.copyWith(openaiModel: v)),
        ),
      ] else if (isClaude) ...[
        _buildKeyField('API Key', _textClaudeKeyCtrl, (val) {
          _updateText(_text.copyWith(claudeApiKey: val));
        }),
        _divider(),
        _buildDropdown<String>(
          'Model',
          _text.claudeModel,
          const {
            'claude-sonnet-4-20250514': 'Claude Sonnet 4',
            'claude-haiku-4-5-20251001': 'Claude Haiku 4.5',
          },
          (v) => _updateText(_text.copyWith(claudeModel: v)),
        ),
      ] else if (isCustom) ...[
        _buildKeyField('API Key', _textCustomKeyCtrl, (val) {
          _updateText(_text.copyWith(customApiKey: val));
        }),
        _divider(),
        _buildTextField(
          'Endpoint',
          _textCustomEndpointCtrl,
          hint: 'https://openrouter.ai/api/v1/chat/completions',
          onChanged: (val) =>
              _updateText(_text.copyWith(customEndpointUrl: val)),
        ),
        _divider(),
        _buildTextField(
          'Model',
          _textCustomModelCtrl,
          hint: 'e.g. meta-llama/llama-3.3-70b-instruct',
          onChanged: (val) =>
              _updateText(_text.copyWith(customModel: val)),
        ),
      ],
      _divider(),
      _buildPromptField(),
    ];
  }

  // ───── TTS Expanded Content ─────

  List<Widget> _buildTtsContent() {
    final isEnabled = _tts.provider != TtsProvider.none;
    final isElevenlabs = _tts.provider == TtsProvider.elevenlabs;
    final isKokoro = _tts.provider == TtsProvider.kokoro;
    final isPocketTts = _tts.provider == TtsProvider.pocketTts;

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: isEnabled
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(Icons.spatial_audio_off_rounded,
                  size: 17,
                  color: isEnabled
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Voice Output',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.2,
                      )),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text(_ttsProviderLabel,
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary)),
                    const SizedBox(width: 8),
                    _configuredBadge(_tts.isConfigured),
                  ]),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: Switch.adaptive(
                value: isEnabled,
                onChanged: (v) => _updateTts(_tts.copyWith(
                  provider: v ? TtsProvider.elevenlabs : TtsProvider.none,
                )),
                activeTrackColor: AppColors.accent,
              ),
            ),
          ],
        ),
      ),
      if (isEnabled) ...[
        _divider(),
        _buildTtsProviderChips(),
      ],
      if (isElevenlabs) ...[
        _divider(),
        _buildKeyField('API Key', _ttsApiKeyCtrl, (val) {
          _updateTts(_tts.copyWith(elevenLabsApiKey: val));
          _fetchVoiceList();
        }),
        _divider(),
        _buildVoiceSelector(),
        _divider(),
        _buildDropdown<String>(
          'Model',
          _tts.elevenLabsModelId,
          const {
            'eleven_flash_v2_5': 'Flash v2.5 (Fast)',
            'eleven_multilingual_v2': 'Multilingual v2',
            'eleven_turbo_v2_5': 'Turbo v2.5',
          },
          (v) => _updateTts(_tts.copyWith(elevenLabsModelId: v)),
        ),
      ],
      if (isKokoro) ...[
        _divider(),
        _buildDropdown<String>(
          'Voice',
          _tts.kokoroVoiceStyle,
          {
            for (final v in KokoroTtsService.voiceStyles)
              v: _formatKokoroVoiceName(v)
          },
          (v) => _updateTts(_tts.copyWith(kokoroVoiceStyle: v)),
        ),
      ],
      if (isPocketTts) ...[
        _divider(),
        _buildPocketTtsVoiceSelector(),
      ],
    ];
  }

  // ───── Bottom Sections ─────

  Widget _buildBottomSections(bool wide) {
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _buildMutePolicyCard()),
          const SizedBox(width: 16),
          Expanded(child: _buildComfortNoiseCard()),
        ],
      );
    }
    return Column(
      children: [
        _buildMutePolicyCard(),
        const SizedBox(height: 16),
        _buildComfortNoiseCard(),
      ],
    );
  }

  // ───── Pipeline Info Getters ─────

  String get _sttModelInfo {
    if (_voice.enabled) {
      return switch (_voice.model) {
        'gpt-4o-mini-realtime-preview' => 'GPT-4o Mini Realtime',
        'gpt-4o-realtime-preview' => 'GPT-4o Realtime',
        _ => _voice.model,
      };
    }
    return _stt.provider == SttProvider.whisperKit
        ? 'WhisperKit'
        : 'OpenAI Realtime';
  }

  String get _sttBadge =>
      _stt.provider == SttProvider.whisperKit ? 'On Device' : 'API';

  String get _llmModelInfo {
    if (!_text.enabled) return 'Not configured';
    return switch (_text.provider) {
      TextAgentProvider.openai => switch (_text.openaiModel) {
          'gpt-4o' => 'GPT-4o',
          'gpt-4o-mini' => 'GPT-4o Mini',
          _ => _text.openaiModel,
        },
      TextAgentProvider.claude => switch (_text.claudeModel) {
          'claude-sonnet-4-20250514' => 'Claude Sonnet 4',
          'claude-haiku-4-5-20251001' => 'Claude Haiku 4.5',
          _ => _text.claudeModel,
        },
      TextAgentProvider.custom =>
        _text.customModel.isNotEmpty ? _text.customModel : 'Custom',
    };
  }

  String get _ttsModelInfo => switch (_tts.provider) {
        TtsProvider.elevenlabs => 'ElevenLabs',
        TtsProvider.kokoro => 'Kokoro',
        TtsProvider.pocketTts => 'Pocket TTS',
        TtsProvider.none => 'None',
      };

  String get _ttsBadge => switch (_tts.provider) {
        TtsProvider.elevenlabs => 'API',
        TtsProvider.kokoro || TtsProvider.pocketTts => 'On Device',
        TtsProvider.none => '',
      };

  String get _ttsProviderLabel => switch (_tts.provider) {
        TtsProvider.elevenlabs => 'ElevenLabs',
        TtsProvider.kokoro => 'Kokoro (On-Device)',
        TtsProvider.pocketTts => 'Pocket TTS (On-Device)',
        TtsProvider.none => 'None',
      };

  Widget _configuredBadge(bool configured) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: configured
            ? AppColors.green.withValues(alpha: 0.12)
            : AppColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        configured ? 'Configured' : 'Not Set',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: configured ? AppColors.green : AppColors.orange,
        ),
      ),
    );
  }

  // ───── Agent Mute Policy ─────

  void _updateMutePolicy(AgentMutePolicy p) {
    setState(() => _mutePolicy = p);
    _agent?.setGlobalMutePolicy(p);
  }

  Widget _buildMutePolicyCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              'AGENT VOICE BEHAVIOR',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textTertiary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _mutePolicyOption(
                AgentMutePolicy.autoToggle,
                Icons.swap_horiz_rounded,
                'Auto unmute on call',
                'Agent speaks when a call starts, goes silent when it ends',
              ),
              Divider(
                  height: 0.5,
                  indent: 16,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _mutePolicyOption(
                AgentMutePolicy.stayMuted,
                Icons.volume_off_rounded,
                'Stay muted',
                'Agent stays text-only unless you manually unmute',
              ),
              Divider(
                  height: 0.5,
                  indent: 16,
                  color: AppColors.border.withValues(alpha: 0.5)),
              _mutePolicyOption(
                AgentMutePolicy.stayUnmuted,
                Icons.volume_up_rounded,
                'Stay unmuted',
                'Agent always speaks, even when not on a call',
              ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              'Can be overridden per job function.',
              style:
                  TextStyle(fontSize: 10, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mutePolicyOption(
    AgentMutePolicy value,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final selected = _mutePolicy == value;
    return HoverButton(
      onTap: () => _updateMutePolicy(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: selected
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
              ),
              child: Icon(icon,
                  size: 17,
                  color:
                      selected ? AppColors.accent : AppColors.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                        fontSize: 10, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.border,
                  width: selected ? 5 : 1.5,
                ),
                color: selected ? AppColors.accent : Colors.transparent,
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.onAccent,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  // ───── Comfort Noise ─────

  void _updateComfortNoise(ComfortNoiseConfig cn) {
    setState(() => _comfortNoise = cn);
    context.read<ComfortNoiseService>().updateConfig(cn);
  }

  Widget _buildComfortNoiseCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'COMFORT NOISE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textTertiary,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: _comfortNoise.enabled
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : AppColors.card,
                      ),
                      child: Icon(Icons.graphic_eq_rounded,
                          size: 17,
                          color: _comfortNoise.enabled
                              ? AppColors.accent
                              : AppColors.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Play comfort noise',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Loop audio into the call before the agent speaks',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: Switch.adaptive(
                        value: _comfortNoise.enabled,
                        onChanged: (v) => _updateComfortNoise(
                            _comfortNoise.copyWith(enabled: v)),
                        activeTrackColor: AppColors.accent,
                      ),
                    ),
                  ],
                ),
                if (_comfortNoise.enabled) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(Icons.volume_down,
                          size: 16, color: AppColors.textTertiary),
                      Expanded(
                        child: Slider(
                          value: _comfortNoise.volume,
                          min: 0.0,
                          max: 1.0,
                          divisions: 20,
                          activeColor: AppColors.accent,
                          inactiveColor:
                              AppColors.textTertiary.withValues(alpha: 0.2),
                          onChanged: (v) => _updateComfortNoise(
                              _comfortNoise.copyWith(volume: v)),
                        ),
                      ),
                      Icon(Icons.volume_up,
                          size: 16, color: AppColors.textTertiary),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(_comfortNoise.volume * 100).round()}%',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ComfortNoisePicker(
                    selectedPath: _comfortNoise.selectedPath,
                    onSelected: (path) => _updateComfortNoise(
                      path != null
                          ? _comfortNoise.copyWith(selectedPath: path)
                          : _comfortNoise.copyWith(clearPath: true),
                    ),
                  ),
                ],
            const SizedBox(height: 6),
            Text(
              'Can be overridden per job function.',
              style:
                  TextStyle(fontSize: 10, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionsField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Instructions',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _voiceInstructionsCtrl,
            maxLines: 3,
            style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'e.g. You are a helpful agent on a phone call...',
              hintStyle:
                  TextStyle(fontSize: 13, color: AppColors.textTertiary),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.accent, width: 1),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (val) =>
                _updateVoice(_voice.copyWith(instructions: val)),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildPromptField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('System Prompt',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _systemPromptCtrl,
            maxLines: 3,
            style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Instructions for the text agent...',
              hintStyle:
                  TextStyle(fontSize: 13, color: AppColors.textTertiary),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.accent, width: 1),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (val) =>
                _updateText(_text.copyWith(systemPrompt: val)),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildTtsProviderChips() {
    final providers = <TtsProvider, String>{
      TtsProvider.elevenlabs: 'ElevenLabs',
    };
    if (BuildConfig.onDeviceModelsSupported) {
      providers[TtsProvider.kokoro] = 'Kokoro (On-Device)';
      if (Platform.isLinux || Platform.isMacOS) {
        providers[TtsProvider.pocketTts] = 'Pocket TTS (On-Device)';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Provider',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: providers.entries.map((e) => ChoiceChip(
                    label: Text(e.value, style: const TextStyle(fontSize: 12)),
                    selected: _tts.provider == e.key,
                    onSelected: (_) => _updateTts(_tts.copyWith(provider: e.key)),
                    selectedColor: AppColors.accent.withValues(alpha: 0.2),
                    backgroundColor: AppColors.card,
                    side: BorderSide(
                      color: _tts.provider == e.key
                          ? AppColors.accent
                          : AppColors.border.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  )).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPocketTtsVoiceSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 100,
                child: Text('Voice',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
              ),
              if (_pocketVoiceListLoading)
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.textTertiary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('Loading voices...',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                )
              else
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.border.withValues(alpha: 0.5),
                          width: 0.5),
                    ),
                    child: DropdownButton<int>(
                      value: _pocketVoiceList.any(
                              (v) => v.id == _tts.pocketTtsVoiceId)
                          ? _tts.pocketTtsVoiceId
                          : null,
                      hint: Text('Default',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textTertiary)),
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppColors.card,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                      icon: Icon(Icons.unfold_more_rounded,
                          size: 16, color: AppColors.textTertiary),
                      items: _buildPocketVoiceDropdownItems(),
                      onChanged: (v) {
                        _updateTts(_tts.copyWith(
                          pocketTtsVoiceId: v,
                          clearPocketTtsVoiceId: v == null,
                          pocketTtsVoiceClonePath: '',
                        ));
                      },
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 100),
              SizedBox(
                height: 28,
                child: TextButton.icon(
                  onPressed: _openPocketVoiceUploadModal,
                  icon: Icon(Icons.add_rounded, size: 14,
                      color: AppColors.accent),
                  label: Text('Add Voice',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.accent)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(
                          color: AppColors.accent.withValues(alpha: 0.3)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 28,
                child: TextButton.icon(
                  onPressed: _fetchPocketVoiceList,
                  icon: Icon(Icons.refresh_rounded, size: 14,
                      color: AppColors.textTertiary),
                  label: Text('Refresh',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              if (_tts.pocketTtsVoiceId != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    onPressed: _playPocketPreview,
                    icon: _pocketPreviewPlaying
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.accent),
                            ),
                          )
                        : Icon(Icons.play_arrow_rounded,
                            size: 14, color: AppColors.accent),
                    label: Text(
                        _pocketPreviewPlaying ? 'Stop' : 'Preview',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.accent)),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(
                            color:
                                AppColors.accent.withValues(alpha: 0.3)),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<int>> _buildPocketVoiceDropdownItems() {
    final items = <DropdownMenuItem<int>>[];

    final defaults = _pocketVoiceList.where((v) => v.isDefault).toList();
    final custom = _pocketVoiceList.where((v) => !v.isDefault).toList();

    if (defaults.isNotEmpty) {
      items.add(DropdownMenuItem<int>(
        enabled: false,
        value: null,
        child: Text('On Device Voices',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textTertiary,
                letterSpacing: 0.3)),
      ));
      for (final v in defaults) {
        items.add(DropdownMenuItem<int>(
          value: v.id,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(v.name, overflow: TextOverflow.ellipsis),
                ),
                if (v.subtitle.isNotEmpty)
                  Text(v.subtitle,
                      style: TextStyle(
                          fontSize: 10, color: AppColors.textTertiary)),
              ],
            ),
          ),
        ));
      }
    }

    if (custom.isNotEmpty) {
      items.add(DropdownMenuItem<int>(
        enabled: false,
        value: null,
        child: Padding(
          padding: EdgeInsets.only(top: defaults.isNotEmpty ? 8 : 0),
          child: Text('My Voices',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  letterSpacing: 0.3)),
        ),
      ));
      for (final v in custom) {
        items.add(DropdownMenuItem<int>(
          value: v.id,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(v.name, overflow: TextOverflow.ellipsis),
                ),
                if (v.subtitle.isNotEmpty)
                  Text(v.subtitle,
                      style: TextStyle(
                          fontSize: 10, color: AppColors.textTertiary)),
                const SizedBox(width: 4),
                HoverButton(
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: AppColors.surface,
                        title: Text('Delete "${v.name}"?',
                            style: TextStyle(
                                fontSize: 15, color: AppColors.textPrimary)),
                        content: Text('This voice will be permanently removed.',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textSecondary)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text('Cancel',
                                style: TextStyle(
                                    color: AppColors.textTertiary)),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text('Delete',
                                style: TextStyle(color: AppColors.red)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && v.id != null) {
                      await PocketTtsVoiceDb.deleteVoice(v.id!);
                      if (_tts.pocketTtsVoiceId == v.id) {
                        _updateTts(_tts.copyWith(clearPocketTtsVoiceId: true));
                      }
                      _fetchPocketVoiceList();
                    }
                  },
                  child: Icon(Icons.close, size: 14,
                      color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ));
      }
    }

    return items;
  }

  Future<void> _openPocketVoiceUploadModal() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PocketVoiceUploadDialog(),
    );
    if (result == true) {
      _fetchPocketVoiceList();
    }
  }

  static String _formatKokoroVoiceName(String style) {
    // "af_heart" → "Heart (Female US)" ; "am_adam" → "Adam (Male US)"
    final parts = style.split('_');
    if (parts.length < 2) return style;
    final prefix = parts[0];
    final name = parts.sublist(1).map((s) =>
      s[0].toUpperCase() + s.substring(1)
    ).join(' ');
    final gender = prefix.startsWith('a')
        ? (prefix.contains('m') ? 'Male' : 'Female')
        : (prefix.contains('m') ? 'Male' : 'Female');
    final accent = prefix.startsWith('a') ? 'US' : 'UK';
    return '$name ($gender $accent)';
  }

  // ───── Speech-to-Text (STT) ─────

  void _updateStt(SttConfig s) {
    setState(() => _stt = s);
    AgentConfigService.saveSttConfig(s);
    _dirty = true;
  }

  Widget _buildVoiceSelector() {
    // Fall back to text field if no voice list loaded yet
    if (_voiceList == null && !_voiceListLoading) {
      return _buildTextField('Voice ID', _ttsVoiceIdCtrl,
          hint: 'e.g. 21m00Tcm4TlvDq8ikWAM', onChanged: (val) {
        _updateTts(_tts.copyWith(elevenLabsVoiceId: val));
      });
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 100,
                child: Text('Voice',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
              ),
              if (_voiceListLoading)
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.textTertiary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('Loading voices...',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textTertiary)),
                    ],
                  ),
                )
              else if (_voiceList != null)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.border.withValues(alpha: 0.5),
                          width: 0.5),
                    ),
                    child: DropdownButton<String>(
                      value: _voiceList!.any(
                              (v) => v.voiceId == _tts.elevenLabsVoiceId)
                          ? _tts.elevenLabsVoiceId
                          : null,
                      hint: Text('Select a voice',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textTertiary)),
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppColors.card,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textPrimary),
                      icon: Icon(Icons.unfold_more_rounded,
                          size: 16, color: AppColors.textTertiary),
                      items: _voiceList!
                          .map((v) => DropdownMenuItem<String>(
                                value: v.voiceId,
                                child: Text(
                                  '${v.name}  ',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          _ttsVoiceIdCtrl.text = v;
                          _updateTts(
                              _tts.copyWith(elevenLabsVoiceId: v));
                        }
                      },
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    _voiceListError ?? 'Enter API key to load voices',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 100),
              SizedBox(
                height: 28,
                child: TextButton.icon(
                  onPressed: _tts.elevenLabsApiKey.isEmpty
                      ? null
                      : _openVoiceCloneModal,
                  icon: Icon(Icons.add_rounded, size: 14,
                      color: AppColors.accent),
                  label: Text('Clone Voice',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.accent)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(
                          color: AppColors.accent.withValues(alpha: 0.3)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 28,
                child: TextButton.icon(
                  onPressed: _tts.elevenLabsApiKey.isEmpty
                      ? null
                      : _fetchVoiceList,
                  icon: Icon(Icons.refresh_rounded, size: 14,
                      color: AppColors.textTertiary),
                  label: Text('Refresh',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              if (_tts.elevenLabsVoiceId.isNotEmpty &&
                  _tts.elevenLabsApiKey.isNotEmpty) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    onPressed: _playElevenLabsPreview,
                    icon: _elevenLabsPreviewPlaying
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.accent),
                            ),
                          )
                        : Icon(Icons.play_arrow_rounded,
                            size: 14, color: AppColors.accent),
                    label: Text(
                        _elevenLabsPreviewPlaying ? 'Stop' : 'Preview',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.accent)),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(
                            color:
                                AppColors.accent.withValues(alpha: 0.3)),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openVoiceCloneModal() async {
    final result = await showVoiceCloneModal(
      context,
      apiKey: _tts.elevenLabsApiKey,
    );
    if (result != null && mounted) {
      _ttsVoiceIdCtrl.text = result.voiceId;
      _updateTts(_tts.copyWith(elevenLabsVoiceId: result.voiceId));
      _fetchVoiceList();
    }
  }

  // ───── Shared field builders ─────

  Widget _buildKeyField(
      String label, TextEditingController ctrl, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              obscureText: true,
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'sk-...',
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
      String label, TextEditingController ctrl,
      {String hint = '', required ValueChanged<String> onChanged}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              autocorrect: false,
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle:
                    TextStyle(fontSize: 13, color: AppColors.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown<T>(
      String label, T value, Map<T, String> options, ValueChanged<T> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style:
                    TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: AppColors.card,
                style: TextStyle(
                    fontSize: 13, color: AppColors.textPrimary),
                icon: Icon(Icons.unfold_more_rounded,
                    size: 16, color: AppColors.textTertiary),
                items: options.entries
                    .map((e) => DropdownMenuItem<T>(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Divider(
      height: 0.5, indent: 16, color: AppColors.border.withValues(alpha: 0.5));
}

// ───── Pocket TTS Voice Upload Dialog ─────

class _PocketVoiceUploadDialog extends StatefulWidget {
  const _PocketVoiceUploadDialog();

  @override
  State<_PocketVoiceUploadDialog> createState() =>
      _PocketVoiceUploadDialogState();
}

class _PocketVoiceUploadDialogState extends State<_PocketVoiceUploadDialog> {
  final _nameCtrl = TextEditingController();
  String? _filePath;
  String? _fileName;
  String? _accent;
  String? _gender;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'ogg', 'flac', 'aac'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final duration = await PocketTtsService.getAudioDurationSeconds(path);
    if (!mounted) return;
    if (duration > 30) {
      setState(
          () => _error = 'File too long — voice sample must be 30 seconds or less');
      return;
    }
    setState(() {
      _filePath = path;
      _fileName = p.basename(path);
      _error = null;
    });
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a voice name');
      return;
    }
    if (_filePath == null) {
      setState(() => _error = 'Please select an audio file');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await PocketTtsVoiceDb.addUserVoice(
        name: name,
        audioPath: _filePath!,
        accent: _accent,
        gender: _gender,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

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
            children: [
              Row(
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
                        Text('Add Voice',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text('Upload an audio sample for voice cloning',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textTertiary)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              TextField(
                controller: _nameCtrl,
                autocorrect: false,
                style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Voice name',
                  hintStyle: TextStyle(
                      fontSize: 13, color: AppColors.textTertiary),
                  filled: true,
                  fillColor: AppColors.card,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                        color: AppColors.border.withValues(alpha: 0.5),
                        width: 0.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.accent, width: 1),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _buildMiniDropdown<String>(
                      'Accent',
                      _accent,
                      const {
                        'American': 'American',
                        'British': 'British',
                        'UK': 'UK',
                        'Australian': 'Australian',
                        'Spanish': 'Spanish',
                        'Other': 'Other',
                      },
                      (v) => setState(() => _accent = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMiniDropdown<String>(
                      'Gender',
                      _gender,
                      const {
                        'Female': 'Female',
                        'Male': 'Male',
                        'Other': 'Other',
                      },
                      (v) => setState(() => _gender = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              HoverButton(
                onTap: _pickFile,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _filePath != null
                            ? AppColors.accent.withValues(alpha: 0.3)
                            : AppColors.border.withValues(alpha: 0.5),
                        width: _filePath != null ? 1 : 0.5),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _filePath != null
                            ? Icons.audio_file_rounded
                            : Icons.file_upload_outlined,
                        size: 28,
                        color: _filePath != null
                            ? AppColors.accent
                            : AppColors.textTertiary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _fileName ?? 'Click to select audio file',
                        style: TextStyle(
                          fontSize: 12,
                          color: _filePath != null
                              ? AppColors.textPrimary
                              : AppColors.textTertiary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (_filePath == null) ...[
                        const SizedBox(height: 4),
                        Text('WAV, MP3, M4A, OGG, FLAC, AAC — max 30s',
                            style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary)),
                      ],
                    ],
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.red.withValues(alpha: 0.2),
                        width: 0.5),
                  ),
                  child: Text(_error!,
                      style: TextStyle(fontSize: 12, color: AppColors.red)),
                ),
              ],

              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text('Cancel',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textTertiary)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 36,
                    child: ElevatedButton(
                      onPressed:
                          _submitting || _filePath == null ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.crtBlack,
                        disabledBackgroundColor:
                            AppColors.accent.withValues(alpha: 0.3),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 20),
                      ),
                      child: _submitting
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    AppColors.crtBlack),
                              ),
                            )
                          : const Text('Add Voice',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniDropdown<T>(
      String hint, T? value, Map<T, String> options, ValueChanged<T?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: DropdownButton<T>(
        value: value,
        hint: Text(hint,
            style:
                TextStyle(fontSize: 12, color: AppColors.textTertiary)),
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: AppColors.card,
        style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
        icon: Icon(Icons.unfold_more_rounded,
            size: 14, color: AppColors.textTertiary),
        items: options.entries
            .map((e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }
}
