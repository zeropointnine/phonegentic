import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent_config_service.dart';
import '../agent_service.dart';
import '../elevenlabs_api_service.dart';
import '../job_function_service.dart';
import '../models/job_function.dart';
import '../theme_provider.dart';

class JobFunctionEditor extends StatefulWidget {
  const JobFunctionEditor({super.key});

  @override
  State<JobFunctionEditor> createState() => _JobFunctionEditorState();
}

class _JobFunctionEditorState extends State<JobFunctionEditor> {
  final _nameController = TextEditingController();
  final _agentNameController = TextEditingController();
  final _roleController = TextEditingController();
  final _descController = TextEditingController();
  final _nameFocus = FocusNode();
  final _scrollController = ScrollController();

  List<_SpeakerRow> _speakers = [];
  List<TextEditingController> _guardrailControllers = [];

  bool _saving = false;
  bool _nameValid = false;
  bool _whisperByDefault = false;
  bool get _isEditing => _existing != null;
  JobFunction? _existing;

  // ElevenLabs voice selection
  TtsConfig? _ttsConfig;
  List<ElevenLabsVoice>? _voiceList;
  bool _voiceListLoading = false;
  String? _selectedVoiceId;

  // Mute policy override (null = use global, 0 = autoToggle, 1 = stayMuted)
  int? _mutePolicyOverride;

  @override
  void initState() {
    super.initState();
    final jfService = context.read<JobFunctionService>();
    _existing = jfService.editing;

    _loadVoiceConfig();

    if (_existing != null) {
      _nameController.text = _existing!.title;
      _agentNameController.text = _existing!.agentName ?? '';
      _roleController.text = _existing!.role;
      _descController.text = _existing!.jobDescription;
      _whisperByDefault = _existing!.whisperByDefault;
      _selectedVoiceId = _existing!.elevenLabsVoiceId;
      _mutePolicyOverride = _existing!.mutePolicyOverride;
      _speakers = _existing!.speakers
          .map((s) => _SpeakerRow(
                role: TextEditingController(text: s.role),
                source: s.source,
              ))
          .toList();
      _guardrailControllers = _existing!.guardrails
          .map((g) => TextEditingController(text: g))
          .toList();
    } else {
      _roleController.text =
          'You are a voice AI agent participating in a 3-party phone call.';
      _speakers = SpeakerDef.defaultSpeakers
          .map((s) => _SpeakerRow(
                role: TextEditingController(text: s.role),
                source: s.source,
              ))
          .toList();
    }

    _nameValid = _nameController.text.trim().isNotEmpty;
    _nameController.addListener(_onNameChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
    });
  }

  Future<void> _loadVoiceConfig() async {
    final tts = await AgentConfigService.loadTtsConfig();
    if (!mounted) return;
    setState(() => _ttsConfig = tts);
    if (tts.provider == TtsProvider.elevenlabs &&
        tts.elevenLabsApiKey.isNotEmpty) {
      _fetchVoiceList(tts.elevenLabsApiKey);
    }
  }

  Future<void> _fetchVoiceList(String apiKey) async {
    setState(() => _voiceListLoading = true);
    try {
      final voices = await ElevenLabsApiService.listVoices(apiKey);
      if (mounted) {
        setState(() {
          _voiceList = voices;
          _voiceListLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _voiceListLoading = false);
    }
  }

  void _onNameChanged() {
    final valid = _nameController.text.trim().isNotEmpty;
    if (valid != _nameValid) setState(() => _nameValid = valid);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _agentNameController.dispose();
    _roleController.dispose();
    _descController.dispose();
    _nameFocus.dispose();
    _scrollController.dispose();
    for (final s in _speakers) {
      s.role.dispose();
    }
    for (final c in _guardrailControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;

    setState(() => _saving = true);

    final speakers = _speakers
        .where((s) => s.role.text.trim().isNotEmpty)
        .map((s) => SpeakerDef(role: s.role.text.trim(), source: s.source))
        .toList();

    final guardrails = _guardrailControllers
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    final agentName = _agentNameController.text.trim();

    final jf = JobFunction(
      id: _existing?.id,
      title: name,
      agentName: agentName.isEmpty ? null : agentName,
      role: _roleController.text.trim(),
      jobDescription: _descController.text.trim(),
      speakers: speakers.isEmpty ? null : speakers,
      guardrails: guardrails.isEmpty ? null : guardrails,
      whisperByDefault: _whisperByDefault,
      elevenLabsVoiceId: _selectedVoiceId,
      mutePolicyOverride: _mutePolicyOverride,
      createdAt: _existing?.createdAt,
    );

    final service = context.read<JobFunctionService>();
    final isNew = jf.id == null;
    await service.save(jf);

    if (isNew && service.items.isNotEmpty) {
      await service.select(service.items.last.id!);
    }

    final agent = context.read<AgentService>();
    agent.reconnect();

    if (mounted) service.closeEditor();
  }

  Future<void> _delete() async {
    if (_existing?.id == null) return;
    final service = context.read<JobFunctionService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete "${_existing!.title}"?',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
        content: Text('This cannot be undone.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final deleted = await service.delete(_existing!.id!);
    if (!deleted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot delete the last job function.'),
          backgroundColor: AppColors.red,
        ),
      );
      return;
    }

    if (mounted) {
      final agent = context.read<AgentService>();
      agent.updateBootContext(
        service.buildBootContext(),
        jobFunctionName: service.selected?.title,
        whisperByDefault: service.selected?.whisperByDefault,
      );
      service.closeEditor();
    }
  }

  void _addSpeaker() {
    setState(() {
      _speakers.add(_SpeakerRow(
        role: TextEditingController(),
        source: 'remote',
      ));
    });
  }

  void _removeSpeaker(int index) {
    if (_speakers.length <= 1) return;
    setState(() {
      _speakers[index].role.dispose();
      _speakers.removeAt(index);
    });
  }

  void _addGuardrail() {
    setState(() {
      _guardrailControllers.add(TextEditingController());
    });
  }

  void _removeGuardrail(int index) {
    setState(() {
      _guardrailControllers[index].dispose();
      _guardrailControllers.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 460,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              Flexible(
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionLabel('Title'),
                        _buildTextField(
                          controller: _nameController,
                          focusNode: _nameFocus,
                          hint: 'e.g. Sales Assistant, Support Agent...',
                          maxLines: 1,
                        ),
                        const SizedBox(height: 14),
                        _buildSectionLabel('Agent Name'),
                        _buildTextField(
                          controller: _agentNameController,
                          hint: 'e.g. Sarah, Alex (persona name on calls)',
                          maxLines: 1,
                        ),
                        const SizedBox(height: 14),
                        _buildSectionLabel('Agent Identity'),
                        _buildTextField(
                          controller: _roleController,
                          hint:
                              'e.g. You are a friendly sales assistant on a phone call.',
                          maxLines: 2,
                        ),
                        const SizedBox(height: 14),
                        _buildSectionLabel('Job Description'),
                        _buildTextField(
                          controller: _descController,
                          hint:
                              'Describe what the agent should do on the call.\n\n'
                              'e.g. Qualify leads by asking about their budget, '
                              'timeline, and needs. Take notes on key details.',
                          maxLines: 6,
                          minLines: 4,
                        ),
                        const SizedBox(height: 14),
                        _buildWhisperToggle(),
                        const SizedBox(height: 14),
                        _buildMutePolicyOverride(),
                        if (_ttsConfig != null &&
                            _ttsConfig!.provider == TtsProvider.elevenlabs &&
                            _ttsConfig!.elevenLabsApiKey.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          _buildVoiceSelector(),
                        ],
                        const SizedBox(height: 14),
                        _buildSpeakersSection(),
                        const SizedBox(height: 14),
                        _buildGuardrailsSection(),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
              _buildActionBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final service = context.read<JobFunctionService>();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.work_outline_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isEditing ? 'Edit Job Function' : 'New Job Function',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          HoverButton(
            onTap: service.closeEditor,
            borderRadius: BorderRadius.circular(7),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: AppColors.card,
              ),
              child: Icon(Icons.close_rounded,
                  size: 14, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.textTertiary,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    FocusNode? focusNode,
    required String hint,
    int maxLines = 1,
    int? minLines,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        maxLines: maxLines,
        minLines: minLines ?? (maxLines > 1 ? maxLines : null),
        style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.5),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: AppColors.textTertiary, fontSize: 12),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  Widget _buildWhisperToggle() {
    return HoverButton(
      onTap: () => setState(() => _whisperByDefault = !_whisperByDefault),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _whisperByDefault
              ? AppColors.burntAmber.withValues(alpha: 0.08)
              : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _whisperByDefault
                ? AppColors.burntAmber.withValues(alpha: 0.3)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              _whisperByDefault
                  ? Icons.hearing_disabled_rounded
                  : Icons.record_voice_over_rounded,
              size: 16,
              color: _whisperByDefault
                  ? AppColors.burntAmber
                  : AppColors.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Text-Only Mode',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _whisperByDefault
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'Agent responds via text, never speaks aloud',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 36,
              height: 20,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _whisperByDefault
                    ? AppColors.burntAmber
                    : AppColors.border.withValues(alpha: 0.4),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 150),
                alignment: _whisperByDefault
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.onAccent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMutePolicyOverride() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('Agent Voice During Calls'),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          child: Column(
            children: [
              _mutePolicyTile(null, 'Use global setting'),
              _thinDivider(),
              _mutePolicyTile(0, 'Auto unmute on call'),
              _thinDivider(),
              _mutePolicyTile(1, 'Stay muted'),
              _thinDivider(),
              _mutePolicyTile(2, 'Stay unmuted'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mutePolicyTile(int? value, String label) {
    final selected = _mutePolicyOverride == value;
    return HoverButton(
      onTap: () => setState(() => _mutePolicyOverride = value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.accent : AppColors.border,
                  width: selected ? 4.5 : 1.5,
                ),
                color: selected ? AppColors.accent : Colors.transparent,
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.onAccent,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thinDivider() => Divider(
      height: 0.5, indent: 12, color: AppColors.border.withValues(alpha: 0.3));

  Widget _buildVoiceSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('ElevenLabs Voice'),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
          ),
          child: _voiceListLoading
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
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
                              fontSize: 12,
                              color: AppColors.textTertiary)),
                    ],
                  ),
                )
              : DropdownButton<String>(
                  value: _selectedVoiceId != null &&
                          (_voiceList ?? [])
                              .any((v) => v.voiceId == _selectedVoiceId)
                      ? _selectedVoiceId
                      : null,
                  hint: Text('Default (from settings)',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary)),
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  dropdownColor: AppColors.surface,
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textPrimary),
                  icon: Icon(Icons.unfold_more_rounded,
                      size: 14, color: AppColors.textTertiary),
                  items: [
                    DropdownMenuItem<String>(
                      value: null,
                      child: Text('Default (from settings)',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textTertiary)),
                    ),
                    ...(_voiceList ?? []).map((v) =>
                        DropdownMenuItem<String>(
                          value: v.voiceId,
                          child: Text(v.name,
                              overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (v) =>
                      setState(() => _selectedVoiceId = v),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          'Override the TTS voice for this job function. '
          'Leave as default to use the voice from settings.',
          style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildSpeakersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel('Speaker Roles'),
            const Spacer(),
            HoverButton(
              onTap: _addSpeaker,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 12, color: AppColors.accent),
                  const SizedBox(width: 2),
                  Text('Add',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
        for (int i = 0; i < _speakers.length; i++) _buildSpeakerTile(i),
      ],
    );
  }

  Widget _buildSpeakerTile(int index) {
    final s = _speakers[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: TextField(
                controller: s.role,
                style: TextStyle(
                    fontSize: 12, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Role name',
                  hintStyle: TextStyle(
                      color: AppColors.textTertiary, fontSize: 11),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            child: DropdownButton<String>(
              value: s.source,
              underline: const SizedBox(),
              isDense: true,
              dropdownColor: AppColors.surface,
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              icon: Icon(Icons.expand_more_rounded,
                  size: 14, color: AppColors.textTertiary),
              items: const [
                DropdownMenuItem(value: 'mic', child: Text('mic')),
                DropdownMenuItem(value: 'remote', child: Text('remote')),
              ],
              onChanged: (val) {
                if (val == null) return;
                setState(() => _speakers[index] =
                    _SpeakerRow(role: s.role, source: val));
              },
            ),
          ),
          const SizedBox(width: 4),
          if (_speakers.length > 1)
            HoverButton(
              onTap: () => _removeSpeaker(index),
              child: Icon(Icons.remove_circle_outline_rounded,
                  size: 16, color: AppColors.textTertiary),
            ),
        ],
      ),
    );
  }

  Widget _buildGuardrailsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel('Guardrails'),
            const Spacer(),
            HoverButton(
              onTap: _addGuardrail,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 12, color: AppColors.accent),
                  const SizedBox(width: 2),
                  Text('Add',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
        if (_guardrailControllers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'No guardrails yet. Add rules the agent must follow.',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ),
        for (int i = 0; i < _guardrailControllers.length; i++)
          _buildGuardrailTile(i),
      ],
    );
  }

  Widget _buildGuardrailTile(int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text('${index + 1}.',
              style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: TextField(
                controller: _guardrailControllers[index],
                style: TextStyle(
                    fontSize: 12, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'e.g. Never discuss pricing',
                  hintStyle: TextStyle(
                      color: AppColors.textTertiary, fontSize: 11),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          HoverButton(
            onTap: () => _removeGuardrail(index),
            child: Icon(Icons.remove_circle_outline_rounded,
                size: 16, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    final canSave = _nameValid;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (_isEditing)
            HoverButton(
              onTap: _delete,
              child: Text(
                'Delete',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.red,
                ),
              ),
            ),
          const Spacer(),
          HoverButton(
            onTap: context.read<JobFunctionService>().closeEditor,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: AppColors.card,
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: canSave ? _save : null,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: canSave
                    ? (_saving
                        ? AppColors.accent.withValues(alpha: 0.5)
                        : AppColors.accent)
                    : AppColors.accent.withValues(alpha: 0.3),
              ),
              child: Text(
                _saving ? 'Saving...' : 'Save',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: canSave
                      ? AppColors.crtBlack
                      : AppColors.crtBlack.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeakerRow {
  final TextEditingController role;
  String source;

  _SpeakerRow({required this.role, required this.source});
}
