import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../agent_config_service.dart';
import '../agent_service.dart';
import '../elevenlabs_api_service.dart';
import '../theme_provider.dart';
import 'voice_clone_modal.dart';

class AgentSettingsTab extends StatefulWidget {
  const AgentSettingsTab({Key? key}) : super(key: key);

  @override
  State<AgentSettingsTab> createState() => _AgentSettingsTabState();
}

class _AgentSettingsTabState extends State<AgentSettingsTab> {
  VoiceAgentConfig _voice = const VoiceAgentConfig();
  TextAgentConfig _text = const TextAgentConfig();
  CallRecordingConfig _recording = const CallRecordingConfig();
  TtsConfig _tts = const TtsConfig();
  AgentMutePolicy _mutePolicy = AgentMutePolicy.autoToggle;
  bool _loaded = false;
  bool _dirty = false;
  AgentService? _agent;

  final _voiceKeyCtrl = TextEditingController();
  final _voiceInstructionsCtrl = TextEditingController();
  final _textOpenaiKeyCtrl = TextEditingController();
  final _textClaudeKeyCtrl = TextEditingController();
  final _systemPromptCtrl = TextEditingController();
  final _ttsApiKeyCtrl = TextEditingController();
  final _ttsVoiceIdCtrl = TextEditingController();


  List<ElevenLabsVoice>? _voiceList;
  bool _voiceListLoading = false;
  String? _voiceListError;

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
    _systemPromptCtrl.dispose();
    _ttsApiKeyCtrl.dispose();
    _ttsVoiceIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final v = await AgentConfigService.loadVoiceConfig();
    final t = await AgentConfigService.loadTextConfig();
    final r = await AgentConfigService.loadCallRecordingConfig();
    final tts = await AgentConfigService.loadTtsConfig();
    final mp = await AgentConfigService.loadMutePolicy();
    if (!mounted) return;
    setState(() {
      _voice = v;
      _text = t;
      _recording = r;
      _tts = tts;
      _mutePolicy = mp;
      _voiceKeyCtrl.text = v.apiKey;
      _voiceInstructionsCtrl.text = v.instructions;
      _textOpenaiKeyCtrl.text = t.openaiApiKey;
      _textClaudeKeyCtrl.text = t.claudeApiKey;
      _systemPromptCtrl.text = t.systemPrompt;
      _ttsApiKeyCtrl.text = tts.elevenLabsApiKey;
      _ttsVoiceIdCtrl.text = tts.elevenLabsVoiceId;
      _loaded = true;
    });
    if (tts.elevenLabsApiKey.isNotEmpty) {
      _fetchVoiceList();
    }
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          children: [
            _buildVoiceAgentCard(),
            const SizedBox(height: 16),
            _buildCallRecordingCard(),
            const SizedBox(height: 16),
            _buildMutePolicyCard(),
            const SizedBox(height: 16),
            _buildTextAgentCard(),
            if (_text.enabled &&
                _text.provider != TextAgentProvider.openai) ...[
              const SizedBox(height: 16),
              _buildTtsCard(),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _updateRecording(CallRecordingConfig r) {
    setState(() => _recording = r);
    AgentConfigService.saveCallRecordingConfig(r);
    _dirty = true;
  }

  // ───── Call Recording ─────

  Widget _buildCallRecordingCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CALL RECORDING',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: _recording.autoRecord
                        ? AppColors.red.withOpacity(0.12)
                        : AppColors.card,
                  ),
                  child: Icon(Icons.fiber_manual_record,
                      size: 17,
                      color: _recording.autoRecord
                          ? AppColors.red
                          : AppColors.textTertiary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-record calls',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Automatically start recording when a call connects',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: Switch.adaptive(
                    value: _recording.autoRecord,
                    onChanged: (v) =>
                        _updateRecording(_recording.copyWith(autoRecord: v)),
                    activeColor: AppColors.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ───── Agent Mute Policy ─────

  void _updateMutePolicy(AgentMutePolicy p) {
    setState(() => _mutePolicy = p);
    _agent?.setGlobalMutePolicy(p);
  }

  Widget _buildMutePolicyCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AGENT VOICE BEHAVIOR',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _mutePolicyOption(
                AgentMutePolicy.autoToggle,
                Icons.swap_horiz_rounded,
                'Auto unmute on call',
                'Agent speaks when a call starts, goes silent when it ends',
              ),
              Divider(
                  height: 0.5,
                  indent: 16,
                  color: AppColors.border.withOpacity(0.5)),
              _mutePolicyOption(
                AgentMutePolicy.stayMuted,
                Icons.volume_off_rounded,
                'Stay muted',
                'Agent stays text-only unless you manually unmute',
              ),
              Divider(
                  height: 0.5,
                  indent: 16,
                  color: AppColors.border.withOpacity(0.5)),
              _mutePolicyOption(
                AgentMutePolicy.stayUnmuted,
                Icons.volume_up_rounded,
                'Stay unmuted',
                'Agent always speaks, even when not on a call',
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            'Can be overridden per job function.',
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _mutePolicyOption(
    AgentMutePolicy value,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final selected = _mutePolicy == value;
    return GestureDetector(
      onTap: () => _updateMutePolicy(value),
      behavior: HitTestBehavior.opaque,
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
                    ? AppColors.accent.withOpacity(0.12)
                    : AppColors.card,
              ),
              child: Icon(icon,
                  size: 17,
                  color: selected ? AppColors.accent : AppColors.textTertiary),
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
                    style:
                        TextStyle(fontSize: 10, color: AppColors.textTertiary),
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
                        decoration: const BoxDecoration(
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

  // ───── Voice Agent ─────

  Widget _buildVoiceAgentCard() {
    return _AgentCard(
      icon: Icons.graphic_eq_rounded,
      title: 'Voice Agent',
      subtitle: 'OpenAI Realtime',
      enabled: _voice.enabled,
      configured: _voice.isConfigured,
      onToggle: (v) => _updateVoice(_voice.copyWith(enabled: v)),
      children: [
        _buildKeyField('API Key', _voiceKeyCtrl, (val) {
          _updateVoice(_voice.copyWith(apiKey: val));
        }),
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
      ],
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
                    BorderSide(color: AppColors.border.withOpacity(0.5)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withOpacity(0.5)),
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

  // ───── Text Agent ─────

  Widget _buildTextAgentCard() {
    final isOpenai = _text.provider == TextAgentProvider.openai;

    return _AgentCard(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'Text Agent',
      subtitle: isOpenai ? 'OpenAI' : 'Claude',
      enabled: _text.enabled,
      configured: _text.isConfigured,
      onToggle: (v) => _updateText(_text.copyWith(enabled: v)),
      children: [
        _buildProviderSelector(),
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
        ] else ...[
          _buildKeyField('API Key', _textClaudeKeyCtrl, (val) {
            _updateText(_text.copyWith(claudeApiKey: val));
          }),
          _divider(),
          _buildDropdown<String>(
            'Model',
            _text.claudeModel,
            const {
              'claude-sonnet-4-20250514': 'Claude Sonnet 4',
              'claude-haiku': 'Claude Haiku',
            },
            (v) => _updateText(_text.copyWith(claudeModel: v)),
          ),
        ],
        _divider(),
        _buildPromptField(),
      ],
    );
  }

  Widget _buildProviderSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text('Provider',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Row(
                children: [
                  _providerChip('OpenAI', TextAgentProvider.openai),
                  _providerChip('Claude', TextAgentProvider.claude),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _providerChip(String label, TextAgentProvider provider) {
    final selected = _text.provider == provider;
    return Expanded(
      child: GestureDetector(
        onTap: () => _updateText(_text.copyWith(provider: provider)),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: selected ? AppColors.onAccent : AppColors.textTertiary,
              ),
            ),
          ),
        ),
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
                    BorderSide(color: AppColors.border.withOpacity(0.5)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.border.withOpacity(0.5)),
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

  // ───── Voice Output (TTS) ─────

  Widget _buildTtsCard() {
    final isElevenlabs = _tts.provider == TtsProvider.elevenlabs;

    return _AgentCard(
      icon: Icons.record_voice_over_rounded,
      title: 'Voice Output',
      subtitle: isElevenlabs ? 'ElevenLabs' : 'None',
      enabled: isElevenlabs,
      configured: _tts.isConfigured,
      onToggle: (v) => _updateTts(_tts.copyWith(
        provider: v ? TtsProvider.elevenlabs : TtsProvider.none,
      )),
      children: [
        if (isElevenlabs) ...[
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
      ],
    );
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
                          color: AppColors.border.withOpacity(0.5),
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
                          color: AppColors.accent.withOpacity(0.3)),
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
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
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
      height: 0.5, indent: 16, color: AppColors.border.withOpacity(0.5));
}

// ───── Reusable Agent Card ─────

class _AgentCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool configured;
  final ValueChanged<bool> onToggle;
  final List<Widget> children;

  const _AgentCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.configured,
    required this.onToggle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textTertiary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: enabled
                            ? AppColors.accent.withOpacity(0.12)
                            : AppColors.card,
                      ),
                      child: Icon(icon,
                          size: 17,
                          color: enabled
                              ? AppColors.accent
                              : AppColors.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Text(
                                subtitle,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textTertiary),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: configured
                                      ? AppColors.green.withOpacity(0.12)
                                      : AppColors.orange.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  configured ? 'Configured' : 'Not Set',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: configured
                                        ? AppColors.green
                                        : AppColors.orange,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: Switch.adaptive(
                        value: enabled,
                        onChanged: onToggle,
                        activeColor: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                  height: 0.5,
                  color: AppColors.border.withOpacity(0.5)),
              ...children,
            ],
          ),
        ),
      ],
    );
  }
}
