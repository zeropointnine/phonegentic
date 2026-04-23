import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../agent_config_service.dart';
import '../agent_service.dart';
import '../call_history_service.dart';
import '../calendar_sync_service.dart';
import '../manager_presence_service.dart';
import '../db/call_history_db.dart';
import '../conference/conference_service.dart';
import '../demo_mode_service.dart';
import '../inbound_call_flow_service.dart';
import '../inbound_call_router.dart';
import '../job_function_service.dart';
import '../messaging/messaging_service.dart';
import '../models/agent_context.dart';
import '../models/job_function.dart';
import '../models/chat_message.dart';
import '../tear_sheet_service.dart';
import '../theme_provider.dart';
import '../transcript_exporter.dart';
import 'sms_thread_bubble.dart';
import 'streaming_typing_text.dart';
import 'waveform_bars.dart';

class AgentPanel extends StatefulWidget {
  final Widget? dragHandle;
  const AgentPanel({super.key, this.dragHandle});

  /// Registered by _InputBar so the dialpad can redirect letter keypresses.
  static FocusNode? inputFocusNode;
  static TextEditingController? inputController;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isDragging = false;

  // ── Slash-command menu state ─────────────────────────────────────────────
  //
  // When the input text starts with `/` and has no space yet we treat the
  // user as "command-hunting" and pop an in-panel overlay listing matching
  // commands. `_slashFilter` is the raw leading token (e.g. "/no"); `null`
  // means the menu is closed. `_slashIndex` is the highlighted row.
  String? _slashFilter;
  int _slashIndex = 0;

  // ── Command-history state ────────────────────────────────────────────────
  //
  // Terminal-style up-arrow recall of previously-sent inputs. Oldest entry
  // first, newest last. `_historyIdx == null` means we're editing a fresh
  // draft; otherwise it's the index into `_cmdHistory` currently shown.
  // `_historyDraft` stores the draft the user had typed before they
  // started navigating, so Escape (or ArrowDown past the tail) can restore
  // it verbatim.
  static const String _cmdHistoryKey = 'agent_command_history';
  static const int _cmdHistoryMax = 50;
  final List<String> _cmdHistory = [];
  int? _historyIdx;
  String? _historyDraft;
  bool _historyApplying = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onInputChangedForSlash);
    _controller.addListener(_onInputChangedForHistory);
    _loadCommandHistory();
  }

  @override
  void dispose() {
    _controller.removeListener(_onInputChangedForSlash);
    _controller.removeListener(_onInputChangedForHistory);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Command history
  // ---------------------------------------------------------------------------

  Future<void> _loadCommandHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cmdHistoryKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final loaded = decoded
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (!mounted) return;
      _cmdHistory
        ..clear()
        ..addAll(loaded.take(_cmdHistoryMax));
    } catch (e) {
      debugPrint('[AgentPanel] history load failed: $e');
    }
  }

  Future<void> _persistCommandHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cmdHistoryKey, jsonEncode(_cmdHistory));
    } catch (e) {
      debugPrint('[AgentPanel] history persist failed: $e');
    }
  }

  /// Push [entry] onto the history tail. If the exact same string already
  /// exists we remove the stale copy first so the newest position wins —
  /// this keeps the list from filling up with reruns of the same command
  /// and matches how bash HISTCONTROL=ignoredups behaves.
  void _pushHistory(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) return;
    _cmdHistory.removeWhere((e) => e == trimmed);
    _cmdHistory.add(trimmed);
    while (_cmdHistory.length > _cmdHistoryMax) {
      _cmdHistory.removeAt(0);
    }
    _persistCommandHistory();
  }

  void _onInputChangedForHistory() {
    // If the user types anything (or clears the field manually) while
    // mid-navigation, exit history mode so further arrow keys behave
    // normally. `_historyApplying` gates the listener while _we_ mutate
    // the controller from `_historyArrow`.
    if (_historyApplying) return;
    if (_historyIdx != null) {
      setState(() {
        _historyIdx = null;
        _historyDraft = null;
      });
    }
  }

  /// Called by `_InputBarState._handleKeyEvent` on ArrowUp / ArrowDown.
  /// Returns `true` when the event was consumed so the key doesn't also
  /// move the caret inside the TextField.
  bool _historyArrow(int delta) {
    if (_cmdHistory.isEmpty) return false;

    // Only claim up-arrow when the input is empty OR we're already
    // navigating; otherwise leave it alone so multi-line caret movement
    // still works.
    final currentText = _controller.text;
    if (delta < 0 && currentText.isNotEmpty && _historyIdx == null) {
      return false;
    }
    if (delta > 0 && _historyIdx == null) {
      // Down-arrow with no active navigation is just a caret move.
      return false;
    }

    // First step: save the live draft so Escape / tail-down can restore it.
    if (_historyIdx == null) {
      _historyDraft = currentText;
      _historyIdx = _cmdHistory.length;
    }

    final next = (_historyIdx! + delta).clamp(0, _cmdHistory.length);
    if (next == _historyIdx) {
      // Hit the boundary — swallow the key so it doesn't move the caret
      // to an unexpected spot.
      return true;
    }

    _historyApplying = true;
    try {
      final String value;
      if (next >= _cmdHistory.length) {
        value = _historyDraft ?? '';
        _historyIdx = null;
        _historyDraft = null;
      } else {
        value = _cmdHistory[next];
        _historyIdx = next;
      }
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    } finally {
      _historyApplying = false;
    }
    setState(() {});
    return true;
  }

  bool _historyEscape() {
    if (_historyIdx == null) return false;
    _historyApplying = true;
    try {
      final draft = _historyDraft ?? '';
      _controller.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
      _historyIdx = null;
      _historyDraft = null;
    } finally {
      _historyApplying = false;
    }
    setState(() {});
    return true;
  }

  // ---------------------------------------------------------------------------
  // Slash-menu plumbing
  // ---------------------------------------------------------------------------

  void _onInputChangedForSlash() {
    final text = _controller.text;
    final trimmedLeft = text.trimLeft();

    // Only "command-hunting" when the input begins with `/` and the user
    // hasn't started typing a body yet (no whitespace after the slash).
    if (!trimmedLeft.startsWith('/') ||
        RegExp(r'\s').hasMatch(trimmedLeft)) {
      if (_slashFilter != null) {
        setState(() {
          _slashFilter = null;
          _slashIndex = 0;
        });
      }
      return;
    }

    final nextMatches = _matchingCommands(trimmedLeft);
    setState(() {
      _slashFilter = trimmedLeft;
      if (nextMatches.isEmpty) {
        _slashIndex = 0;
      } else if (_slashIndex >= nextMatches.length) {
        _slashIndex = nextMatches.length - 1;
      }
    });
  }

  List<_SlashCommand> _matchingCommands(String filter) {
    if (filter.isEmpty || filter == '/') return _kSlashCommands;
    return _kSlashCommands.where((c) => c.matches(filter)).toList();
  }

  void _slashArrow(int delta) {
    final matches = _matchingCommands(_slashFilter ?? '');
    if (matches.isEmpty) return;
    setState(() {
      _slashIndex =
          (_slashIndex + delta).clamp(0, matches.length - 1).toInt();
    });
  }

  void _slashEscape() {
    if (_slashFilter == null) return;
    setState(() {
      _slashFilter = null;
      _slashIndex = 0;
    });
  }

  void _slashSelect(AgentService agent) {
    final matches = _matchingCommands(_slashFilter ?? '');
    if (matches.isEmpty) return;
    final cmd = matches[_slashIndex.clamp(0, matches.length - 1)];

    if (cmd.takesBody) {
      // Insert "/trigger " and keep focus so the manager types the body.
      final inserted = '${cmd.trigger} ';
      _controller.value = TextEditingValue(
        text: inserted,
        selection: TextSelection.collapsed(offset: inserted.length),
      );
      setState(() {
        _slashFilter = null;
        _slashIndex = 0;
      });
      AgentPanel.inputFocusNode?.requestFocus();
    } else {
      // Fire-and-forget command — set the input to the trigger and send
      // through the normal path so existing `_expandCommand` logic runs.
      _controller.text = cmd.trigger;
      setState(() {
        _slashFilter = null;
        _slashIndex = 0;
      });
      _send(agent);
    }
  }

  void _onDropDone(DropDoneDetails details, AgentService agent) {
    setState(() => _isDragging = false);
    for (final xFile in details.files) {
      final path = xFile.path;
      if (path.isEmpty) continue;
      final ext = path.split('.').last.toLowerCase();
      if (!{'txt', 'md', 'csv', 'log', 'json', 'xml'}.contains(ext)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Only text files are supported (got .$ext)'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        continue;
      }
      _readAndAttachFile(path, agent);
    }
  }

  Future<void> _readAndAttachFile(String path, AgentService agent) async {
    try {
      final file = File(path);
      final content = await file.readAsString();
      final fileName = path.split('/').last;
      agent.sendFileAttachment(fileName: fileName, content: content);
    } catch (e) {
      debugPrint('[AgentPanel] Failed to read file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read file: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _pickAndAttachFile(AgentService agent) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'csv', 'log', 'json', 'xml'],
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        _readAndAttachFile(path, agent);
      }
    }
  }

  Future<void> _downloadSessionTranscript(AgentService agent) async {
    final messages = agent.messages;
    if (messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No messages to export'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final content = TranscriptExporter.formatSessionTranscript(
      messages: messages,
      sessionLabel: agent.remoteDisplayName ?? agent.remoteIdentity,
    );

    await TranscriptExporter.saveToDownloads(
      content,
      filenamePrefix: 'session_transcript',
      context: context,
    );
  }

  void _send(AgentService agent) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _pushHistory(text);
    _historyIdx = null;
    _historyDraft = null;
    _controller.clear();

    if (text.toLowerCase() == '/ready') {
      agent.confirmPartyConnected();
      return;
    }

    // /note — private transcript annotation, never sent to the LLM.
    final lower = text.toLowerCase();
    if (lower.startsWith('/note ') || lower.startsWith('/note\n')) {
      final body = text.substring(5).trim();
      if (body.isNotEmpty) agent.addNote(body);
      return;
    }
    if (lower == '/note') {
      return;
    }

    // /search — contact-scoped recap card (calls + messages + calendar).
    if (lower.startsWith('/search ') || lower.startsWith('/search\n')) {
      final body = text.substring(7).trim();
      if (body.isNotEmpty) agent.startContactSearch(body);
      return;
    }
    if (lower == '/search') {
      return;
    }

    // /call — dial a contact or number directly. Accepts either a phone
    // number (digits/+/-/()) or a contact name; see
    // `AgentService.placeCallByInput` for resolution rules.
    if (lower.startsWith('/call ') || lower.startsWith('/call\n')) {
      final body = text.substring(5).trim();
      if (body.isNotEmpty) agent.placeCallByInput(body);
      return;
    }
    if (lower == '/call') {
      return;
    }

    // /recap — one-shot global recap: most recent calls, SMS, notes,
    // reminders → agent speaks a short brief aloud.
    if (lower == '/recap') {
      agent.startRecap();
      return;
    }

    if (agent.whisperMode) {
      agent.sendWhisperMessage(text);
      return;
    }

    if (lower.startsWith('/w ') || lower.startsWith('/whisper ')) {
      final body = text.substring(text.indexOf(' ') + 1).trim();
      if (body.isNotEmpty) agent.sendWhisperMessage(body);
      return;
    }
    if (lower == '/w' || lower == '/whisper') {
      agent.sendWhisperMessage(text);
      return;
    }

    if (text.startsWith('/')) {
      agent.sendUserMessage(_expandCommand(text));
    } else {
      agent.sendUserMessage(text);
    }
  }

  void _sendWhisperOneShot(AgentService agent) {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _pushHistory(text);
    _historyIdx = null;
    _historyDraft = null;
    _controller.clear();
    agent.sendWhisperMessage(text);
  }

  String _expandCommand(String cmd) {
    switch (cmd.toLowerCase()) {
      case '/trivia':
        return 'Let\'s start the trivia game! Ask the first question.';
      case '/speakers':
        return 'Can you tell me who is on the call? Please ask for names if you don\'t know them.';
      case '/score':
        return 'What\'s the current score?';
      case '/stttest':
        return 'We need to run a speech-to-text accuracy test. '
            'Say the following nursery rhyme clearly and at a natural pace: '
            '"Mary had a little lamb, its fleece was white as snow. '
            'And everywhere that Mary went, the lamb was sure to go." '
            'After you say it, ask the person on the line to repeat it back '
            'to you word for word. Once they finish, repeat back EXACTLY '
            'what you heard them say — word for word, including any mistakes, '
            'missing words, or extra words. Do not correct or clean up what '
            'they said. This is a diagnostic test.';
      default:
        return cmd;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, agent, _) {
        return DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: (details) => _onDropDone(details, agent),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              border:
                  Border(left: BorderSide(color: AppColors.border, width: 0.5)),
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    _AgentHeader(
                      agent: agent,
                      dragHandle: widget.dragHandle,
                      onDownloadTranscript: () =>
                          _downloadSessionTranscript(agent),
                    ),
                    if (agent.pipelineError != null)
                      _PipelineErrorBanner(
                        message: agent.pipelineError!,
                        onDismiss: agent.clearPipelineError,
                      ),
                    const _CalendarEventBanner(),
                    const _UpcomingReminderBanner(),
                    const _AwayCallSummaryBanner(),
                    Consumer<TearSheetService>(
                      builder: (context, tearSheet, _) {
                        if (!tearSheet.isActive) {
                          return const SizedBox.shrink();
                        }
                        return _PanelTearSheetBar(service: tearSheet);
                      },
                    ),
                    if (agent.hasActiveCall) _ConferenceCallBar(agent: agent),
                    Expanded(
                        child: _MessageList(
                      messages: agent.messages,
                      scrollController: _scrollController,
                      hasMore: agent.hasMoreSessionHistory,
                      onLoadMore: () => agent.loadMoreHistory(),
                      thinking: agent.thinking,
                      onAction: (action) {
                        _controller.text = action.value;
                        _send(agent);
                      },
                    )),
                    if (_slashFilter != null)
                      _SlashMenu(
                        commands: _matchingCommands(_slashFilter!),
                        highlightedIndex: _slashIndex,
                        onHover: (i) => setState(() => _slashIndex = i),
                        onSelect: (i) {
                          setState(() => _slashIndex = i);
                          _slashSelect(agent);
                        },
                      ),
                    _InputBar(
                      controller: _controller,
                      onSend: () => _send(agent),
                      onWhisperSend: () => _sendWhisperOneShot(agent),
                      onToggleWhisper: agent.canToggleWhisper
                          ? agent.toggleWhisperMode
                          : null,
                      onAttachFile: () => _pickAndAttachFile(agent),
                      active: agent.active,
                      whisperMode: agent.whisperMode,
                      hasActiveCall: agent.hasActiveCall,
                      slashMenuActive: _slashFilter != null &&
                          _matchingCommands(_slashFilter!).isNotEmpty,
                      onSlashArrow: _slashArrow,
                      onSlashSelect: () => _slashSelect(agent),
                      onSlashEscape: _slashEscape,
                      onHistoryArrow: _historyArrow,
                      onHistoryEscape: _historyEscape,
                    ),
                  ],
                ),
                if (_isDragging)
                  Positioned.fill(
                    child: Container(
                      color: AppColors.bg.withValues(alpha: 0.88),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.accent.withValues(alpha: 0.12),
                                border: Border.all(
                                  color:
                                      AppColors.accent.withValues(alpha: 0.4),
                                  width: 1.5,
                                ),
                              ),
                              child: Icon(Icons.attach_file_rounded,
                                  size: 28, color: AppColors.accent),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Drop text file to attach',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '.txt  .md  .csv  .log  .json  .xml',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textTertiary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Header with integrated waveform + status
// ---------------------------------------------------------------------------

class _AgentHeader extends StatefulWidget {
  final AgentService agent;
  final Widget? dragHandle;
  final VoidCallback? onDownloadTranscript;
  const _AgentHeader({
    required this.agent,
    this.dragHandle,
    this.onDownloadTranscript,
  });

  @override
  State<_AgentHeader> createState() => _AgentHeaderState();
}

class _AgentHeaderState extends State<_AgentHeader> {
  bool _wasSpeaking = false;
  bool _showSpeaking = false;
  Timer? _transitionTimer;

  AgentService get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _wasSpeaking = agent.speaking;
    _showSpeaking = agent.speaking;
    agent.addListener(_onAgentChanged);
  }

  @override
  void dispose() {
    agent.removeListener(_onAgentChanged);
    _transitionTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AgentHeader old) {
    super.didUpdateWidget(old);
    if (old.agent != widget.agent) {
      old.agent.removeListener(_onAgentChanged);
      widget.agent.addListener(_onAgentChanged);
    }
  }

  void _onAgentChanged() {
    final nowSpeaking = agent.speaking;
    if (_wasSpeaking && !nowSpeaking) {
      _transitionTimer?.cancel();
      _transitionTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _showSpeaking = false);
      });
    } else if (nowSpeaking && !_wasSpeaking) {
      _transitionTimer?.cancel();
      setState(() => _showSpeaking = true);
    }
    _wasSpeaking = nowSpeaking;
    if (mounted) setState(() {});
  }

  String get _statusLabel {
    if (!agent.active) return agent.statusText;
    if (_showSpeaking) return 'Speaking';
    if (agent.thinking) return 'Thinking...';
    if (agent.muted) return 'Not Listening...';
    return 'Listening';
  }

  Color get _statusColor {
    if (!agent.active) return AppColors.textTertiary;
    if (_showSpeaking) return AppColors.green;
    if (agent.thinking) return AppColors.burntAmber;
    return AppColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final jfService = context.watch<JobFunctionService>();
    final icfService = context.watch<InboundCallFlowService>();

    final selectedName = jfService.selected?.title ?? 'Phonegentic AI';
    final activeFlow = icfService.activeFlowName;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 21, 15, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (widget.dragHandle != null) ...[
            widget.dragHandle!,
            const SizedBox(width: 8)
          ],
          _WaveformPill(
            levels: agent.levels,
            color: _statusColor,
            active: agent.active,
            muted: agent.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _JobFunctionDropdown(
                  service: jfService,
                  agent: agent,
                  selectedName: selectedName,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    _StatusDot(color: _statusColor, active: agent.active),
                    const SizedBox(width: 5),
                    if (activeFlow != null) ...[
                      Icon(Icons.call_received_rounded,
                          size: 10, color: AppColors.accent),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          activeFlow,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.accent,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      _statusLabel,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _MuteButtonWithPolicy(agent: agent),
          const SizedBox(width: 6),
          if (agent.hasActiveCall || agent.whisperMode) ...[
            _HeaderButton(
              icon: agent.whisperMode
                  ? Icons.voice_over_off_rounded
                  : Icons.record_voice_over_rounded,
              color: agent.canToggleWhisper
                  ? (agent.whisperMode
                      ? AppColors.burntAmber
                      : AppColors.textSecondary)
                  : AppColors.textTertiary.withValues(alpha: 0.5),
              bgColor: agent.canToggleWhisper && agent.whisperMode
                  ? AppColors.burntAmber.withValues(alpha: 0.12)
                  : AppColors.card,
              onTap: agent.canToggleWhisper ? agent.toggleWhisperMode : null,
              tooltip: !agent.canToggleWhisper
                  ? 'Whisper locked (split pipeline)'
                  : agent.whisperMode
                      ? 'Exit Whisper'
                      : 'Whisper Mode',
            ),
            const SizedBox(width: 6),
          ],
          _HeaderButton(
            icon: Icons.download_rounded,
            color: AppColors.textTertiary,
            bgColor: AppColors.card,
            onTap: widget.onDownloadTranscript,
            tooltip: 'Download transcript',
          ),
          const SizedBox(width: 6),
          _HeaderButton(
            icon: Icons.refresh_rounded,
            color: AppColors.textTertiary,
            bgColor: AppColors.card,
            onTap: agent.reconnect,
            tooltip: 'Reconnect',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pipeline error banner
// ---------------------------------------------------------------------------

class _PipelineErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _PipelineErrorBanner({
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(
            color: AppColors.red.withValues(alpha: 0.25),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: AppColors.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.red,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onDismiss,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: AppColors.red.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mute button with long-press policy selector
// ---------------------------------------------------------------------------

class _MuteButtonWithPolicy extends StatelessWidget {
  final AgentService agent;
  const _MuteButtonWithPolicy({required this.agent});

  void _showPolicyMenu(BuildContext context) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset(0, box.size.height));

    showMenu<AgentMutePolicy>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx - 140,
        offset.dy + 4,
        offset.dx + box.size.width,
        0,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
      ),
      elevation: 8,
      items: [
        _policyItem(AgentMutePolicy.autoToggle, Icons.swap_horiz_rounded,
            'Auto unmute on call'),
        _policyItem(
            AgentMutePolicy.stayMuted, Icons.volume_off_rounded, 'Stay muted'),
        _policyItem(AgentMutePolicy.stayUnmuted, Icons.volume_up_rounded,
            'Stay unmuted'),
      ],
    ).then((selected) {
      if (selected != null) {
        agent.setGlobalMutePolicy(selected);
      }
    });
  }

  PopupMenuItem<AgentMutePolicy> _policyItem(
      AgentMutePolicy value, IconData icon, String label) {
    final current = agent.globalMutePolicy;
    final selected = current == value;
    return PopupMenuItem<AgentMutePolicy>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon,
              size: 14,
              color: selected ? AppColors.accent : AppColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color:
                    selected ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 14, color: AppColors.accent),
        ],
      ),
    );
  }

  String get _muteLabel => agent.muted ? 'Muted' : 'Mute';

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: agent.active ? agent.toggleMute : null,
      onLongPress: () => _showPolicyMenu(context),
      tooltip:
          agent.muted ? 'Unmute (hold for policy)' : 'Mute (hold for policy)',
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 30,
        constraints: const BoxConstraints(minWidth: 30),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: agent.muted
              ? AppColors.red.withValues(alpha: 0.12)
              : AppColors.card,
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              agent.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 14,
              color: agent.muted ? AppColors.red : AppColors.textSecondary,
            ),
            const SizedBox(width: 3),
            Text(
              _muteLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: agent.muted
                    ? AppColors.red.withValues(alpha: 0.7)
                    : AppColors.textTertiary,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tear sheet queue controls in the agent column (Play is visible next to chat).
class _PanelTearSheetBar extends StatelessWidget {
  final TearSheetService service;

  const _PanelTearSheetBar({required this.service});

  @override
  Widget build(BuildContext context) {
    final n = service.items.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.07),
        border: Border(
          bottom: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long_rounded, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Tear sheet',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  n == 0
                      ? 'Queue loaded'
                      : '${service.doneCount}/$n called — ${service.isPaused ? "paused" : "running"}',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          _HeaderButton(
            icon: service.isPaused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            color: service.isPaused ? AppColors.green : AppColors.burntAmber,
            bgColor: service.isPaused
                ? AppColors.green.withValues(alpha: 0.12)
                : AppColors.burntAmber.withValues(alpha: 0.12),
            onTap: service.isPaused ? service.play : service.pause,
            tooltip: service.isPaused ? 'Play' : 'Pause',
          ),
          const SizedBox(width: 4),
          _HeaderButton(
            icon: Icons.close_rounded,
            color: AppColors.textTertiary,
            bgColor: AppColors.card,
            onTap: service.dismissSheet,
            tooltip: 'Dismiss tear sheet',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Calendar Event Banner
// ---------------------------------------------------------------------------

class _CalendarEventBanner extends StatefulWidget {
  const _CalendarEventBanner();

  @override
  State<_CalendarEventBanner> createState() => _CalendarEventBannerState();
}

class _CalendarEventBannerState extends State<_CalendarEventBanner> {
  String? _lastPostedMessage;
  ReminderLevel? _lastNotifiedLevel;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<CalendarSyncService>();
    final event = sync.nextEvent;
    final level = sync.reminderLevel;

    final switchMsg = sync.lastSwitchMessage;
    if (switchMsg != null && switchMsg != _lastPostedMessage) {
      _lastPostedMessage = switchMsg;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final agent = context.read<AgentService>();
        agent.sendSystemEvent(switchMsg, requireResponse: true);
      });
    }

    if (event != null &&
        level != ReminderLevel.none &&
        level != _lastNotifiedLevel) {
      _lastNotifiedLevel = level;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final agent = context.read<AgentService>();
        final timeFmt = DateFormat.jm();
        final startLocal = event.startTime.toLocal();
        final mins = sync.minutesUntilNext ?? 0;

        String contextMsg;
        switch (level) {
          case ReminderLevel.upcoming:
            contextMsg = '[CALENDAR] Upcoming event "${event.title}" at '
                '${timeFmt.format(startLocal)} ($mins minutes from now).';
            break;
          case ReminderLevel.imminent:
            contextMsg =
                '[CALENDAR] Event "${event.title}" starts in $mins minutes '
                'at ${timeFmt.format(startLocal)}. Prepare now.';
            break;
          case ReminderLevel.active:
            contextMsg = '[CALENDAR] Event "${event.title}" is starting NOW. '
                'Follow your job function instructions.';
            break;
          case ReminderLevel.none:
            return;
        }
        if (event.inviteeName != null) {
          contextMsg += ' Invitee: ${event.inviteeName}.';
        }
        if (event.location != null) {
          contextMsg += ' Location: ${event.location}.';
        }
        agent.sendSystemEvent(contextMsg,
            requireResponse: level == ReminderLevel.active);
      });
    }

    if (event == null || level == ReminderLevel.none) {
      return const SizedBox.shrink();
    }

    final timeFmt = DateFormat.jm();
    final startLocal = event.startTime.toLocal();
    final minutesLeft = sync.minutesUntilNext ?? 0;

    Color bgColor;
    Color timeColor;
    Color iconColor;
    String prefix;

    switch (level) {
      case ReminderLevel.upcoming:
        bgColor = AppColors.surface;
        timeColor = AppColors.textTertiary;
        iconColor = AppColors.textTertiary;
        prefix = 'Next: ${timeFmt.format(startLocal)}';
        break;
      case ReminderLevel.imminent:
        bgColor = AppColors.accent.withValues(alpha: 0.06);
        timeColor = AppColors.accent;
        iconColor = AppColors.accent;
        prefix = minutesLeft <= 0 ? 'Starting now' : 'In $minutesLeft min';
        break;
      case ReminderLevel.active:
        bgColor = AppColors.accent.withValues(alpha: 0.08);
        timeColor = AppColors.accent;
        iconColor = AppColors.accent;
        prefix = 'Now';
        break;
      case ReminderLevel.none:
        return const SizedBox.shrink();
    }

    final jfService = context.read<JobFunctionService>();
    String? jfChipLabel;
    if (event.jobFunctionId != null) {
      final match = jfService.items.where((j) => j.id == event.jobFunctionId);
      if (match.isNotEmpty) jfChipLabel = match.first.title;
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_today_rounded, size: 12, color: iconColor),
          const SizedBox(width: 5),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.colorForSource(event.source),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            prefix,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: timeColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '–',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              event.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (jfChipLabel != null && level == ReminderLevel.imminent) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                jfChipLabel,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Upcoming Reminder Countdown Banner
// ---------------------------------------------------------------------------

class _UpcomingReminderBanner extends StatefulWidget {
  const _UpcomingReminderBanner();

  @override
  State<_UpcomingReminderBanner> createState() =>
      _UpcomingReminderBannerState();
}

class _UpcomingReminderBannerState extends State<_UpcomingReminderBanner>
    with SingleTickerProviderStateMixin {
  Timer? _ticker;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presence = context.watch<ManagerPresenceService>();
    final reminders = presence.upcomingReminders;
    if (reminders.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    final nearest = reminders.first;
    final title = (nearest['title'] as String?) ?? 'Reminder';
    final description = (nearest['description'] as String?)?.trim() ?? '';
    final reminderId = nearest['id'] as int?;
    final remindAt = DateTime.parse(nearest['remind_at'] as String).toLocal();
    final createdAtRaw = nearest['created_at'] as String?;
    final createdAt = createdAtRaw != null
        ? DateTime.tryParse(createdAtRaw)?.toLocal()
        : null;
    final diff = remindAt.difference(now);
    if (diff.isNegative) return const SizedBox.shrink();

    final secsTotal = diff.inSeconds;
    final mins = diff.inMinutes;
    final secs = secsTotal % 60;
    final isImminent = mins < 2;

    final timeText = mins >= 60
        ? '${mins ~/ 60}h ${mins % 60}m'
        : mins > 0
            ? '${mins}m ${secs.toString().padLeft(2, '0')}s'
            : '${secs}s';

    // Progress fraction along the (created_at → remind_at) span.
    double progress = 0;
    if (createdAt != null) {
      final span = remindAt.difference(createdAt).inSeconds;
      if (span > 0) {
        final elapsed = now.difference(createdAt).inSeconds;
        progress = (elapsed / span).clamp(0.0, 1.0);
      }
    } else {
      // Fallback: ease progress based on how close we are to fire.
      // Anchor span at 10 minutes so short reminders fill quickly.
      const anchor = 600; // seconds
      progress = (1 - (secsTotal / anchor)).clamp(0.0, 1.0);
    }

    final accent = AppColors.orange;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: isImminent ? 0.08 : 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: accent.withValues(alpha: isImminent ? 0.42 : 0.28),
            width: 0.5,
          ),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  final pulseAlpha = isImminent
                      ? 0.55 + 0.45 * _pulse.value
                      : 1.0;
                  return Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: pulseAlpha),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        bottomLeft: Radius.circular(10),
                      ),
                    ),
                  );
                },
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.notifications_active_rounded,
                            size: 12,
                            color: accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'UPCOMING',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.4),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'in $timeText',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              fontFamily: AppColors.timerFontFamily,
                              fontFamilyFallback:
                                  AppColors.timerFontFamilyFallback,
                              color: AppColors.textPrimary
                                  .withValues(alpha: 0.95),
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                          const Spacer(),
                          if (reminders.length > 1) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.3),
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                '+${reminders.length - 1}',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (reminderId != null)
                            HoverButton(
                              onTap: () async {
                                await CallHistoryDb.updateReminderStatus(
                                    reminderId, 'dismissed');
                                if (!mounted) return;
                                await context
                                    .read<ManagerPresenceService>()
                                    .onReminderCreatedOrChanged();
                              },
                              tooltip: 'Dismiss',
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 13,
                                  color: AppColors.textTertiary
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textTertiary
                                .withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Container(
                          height: 2,
                          color: AppColors.border.withValues(alpha: 0.35),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progress,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    accent.withValues(alpha: 0.55),
                                    accent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Away-return call summary banner
// ---------------------------------------------------------------------------

class _AwayCallSummaryBanner extends StatelessWidget {
  const _AwayCallSummaryBanner();

  @override
  Widget build(BuildContext context) {
    final presence = context.watch<ManagerPresenceService>();
    if (!presence.hasAwayCallSummary) return const SizedBox.shrink();

    final calls = presence.awayCallRecords;
    final mins = presence.awayMinutes;
    final inbound = calls.where((c) => c['direction'] == 'inbound').length;
    final outbound = calls.length - inbound;
    final timeFmt = DateFormat.jm();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.06),
        border: Border(
          bottom: BorderSide(
            color: AppColors.accent.withValues(alpha: 0.18),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
            child: Row(
              children: [
                Icon(Icons.summarize_rounded,
                    size: 14, color: AppColors.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'While you were away ($mins min) — '
                    '${calls.length} call${calls.length == 1 ? '' : 's'}'
                    '${inbound > 0 && outbound > 0 ? ' ($inbound in, $outbound out)' : inbound > 0 ? ' (inbound)' : ' (outbound)'}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: presence.dismissAwayCallSummary,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 14,
                          color: AppColors.accent.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...calls.take(5).map((call) {
            final direction = call['direction'] as String? ?? 'inbound';
            final isInbound = direction == 'inbound';
            final name = call['remote_display_name'] as String? ??
                call['remote_identity'] as String? ??
                'Unknown';
            final status = call['status'] as String? ?? '';
            final durationSec = call['duration_seconds'] as int? ?? 0;
            final startedAt = call['started_at'] as String?;

            String timeStr = '';
            if (startedAt != null) {
              try {
                timeStr = timeFmt.format(DateTime.parse(startedAt).toLocal());
              } catch (_) {}
            }

            String durationStr;
            if (status == 'missed') {
              durationStr = 'Missed';
            } else if (durationSec >= 3600) {
              durationStr =
                  '${durationSec ~/ 3600}h ${(durationSec % 3600) ~/ 60}m';
            } else if (durationSec >= 60) {
              durationStr = '${durationSec ~/ 60}m ${durationSec % 60}s';
            } else {
              durationStr = '${durationSec}s';
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Row(
                children: [
                  Icon(
                    isInbound
                        ? Icons.call_received_rounded
                        : Icons.call_made_rounded,
                    size: 12,
                    color: status == 'missed'
                        ? AppColors.red
                        : isInbound
                            ? AppColors.green
                            : AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    durationStr,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: status == 'missed'
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: status == 'missed'
                          ? AppColors.red
                          : AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    timeStr,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            );
          }),
          if (calls.length > 5)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Text(
                '+${calls.length - 5} more call${calls.length - 5 == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Job Function dropdown selector
// ---------------------------------------------------------------------------

class _JobFunctionDropdown extends StatelessWidget {
  final JobFunctionService service;
  final AgentService agent;
  final String selectedName;

  const _JobFunctionDropdown({
    required this.service,
    required this.agent,
    required this.selectedName,
  });

  void _onSelected(BuildContext context, int id) async {
    await service.select(id);
    agent.reconnect();
  }

  Future<void> _confirmDelete(BuildContext context, JobFunction jf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Delete "${jf.title}"?',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary)),
        content: Text('This cannot be undone.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text('Cancel', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final deleted = await service.delete(jf.id!);
    if (!deleted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot delete the last job function.'),
          backgroundColor: AppColors.red,
        ),
      );
      return;
    }

    if (context.mounted) {
      agent.updateBootContext(
        service.buildBootContext(),
        jobFunctionName: service.selected?.title,
        whisperByDefault: service.selected?.whisperByDefault,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: PopupMenuButton<int>(
            onSelected: (id) => _onSelected(context, id),
            offset: const Offset(0, 32),
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            itemBuilder: (_) => [
              ...service.items.map((jf) => PopupMenuItem<int>(
                    value: jf.id!,
                    height: 38,
                    child: Row(
                      children: [
                        Icon(
                          jf.id == service.selected?.id
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          size: 14,
                          color: jf.id == service.selected?.id
                              ? AppColors.accent
                              : AppColors.textTertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            jf.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: jf.id == service.selected?.id
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: jf.id == service.selected?.id
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                        HoverButton(
                          onTap: () {
                            Navigator.of(context).pop();
                            service.openEditor(jf);
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(Icons.edit_rounded,
                                size: 13, color: AppColors.textTertiary),
                          ),
                        ),
                        HoverButton(
                          onTap: () {
                            Navigator.of(context).pop();
                            _confirmDelete(context, jf);
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(Icons.delete_outline_rounded,
                                size: 13, color: AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  )),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<int>(
                value: -1,
                enabled: false,
                height: 36,
                child: HoverButton(
                  onTap: () {
                    Navigator.of(context).pop();
                    service.openEditor();
                  },
                  child: Row(
                    children: [
                      Icon(Icons.add_rounded,
                          size: 14, color: AppColors.accent),
                      const SizedBox(width: 8),
                      Text(
                        'New Job Function',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<int>(
                value: -2,
                enabled: false,
                height: 36,
                child: HoverButton(
                  onTap: () {
                    Navigator.of(context).pop();
                    context.read<InboundCallFlowService>().openEditor();
                  },
                  child: Row(
                    children: [
                      Icon(Icons.call_received_rounded,
                          size: 14, color: AppColors.accent),
                      const SizedBox(width: 8),
                      Text(
                        'Inbound Call Flow',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    selectedName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.expand_more_rounded,
                    size: 14, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        HoverButton(
          onTap: () => service.openEditor(),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: AppColors.card,
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
            ),
            child: Icon(Icons.add_rounded,
                size: 12, color: AppColors.textTertiary),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Call Info Bar — live call metadata between header and messages
// ---------------------------------------------------------------------------

class _CallInfoBar extends StatelessWidget {
  final AgentService agent;
  const _CallInfoBar({required this.agent});

  Color get _phaseColor {
    switch (agent.callPhase) {
      case CallPhase.ringing:
      case CallPhase.connecting:
      case CallPhase.initiating:
        return AppColors.burntAmber;
      case CallPhase.answered:
      case CallPhase.settling:
        return AppColors.burntAmber;
      case CallPhase.connected:
        return AppColors.green;
      case CallPhase.onHold:
        return AppColors.accent;
      case CallPhase.ended:
      case CallPhase.failed:
        return AppColors.red;
      case CallPhase.idle:
        return AppColors.textTertiary;
    }
  }

  IconData get _directionIcon =>
      agent.isOutbound ? Icons.call_made_rounded : Icons.call_received_rounded;

  String _remoteLabel(DemoModeService demo) {
    if (agent.remoteDisplayName != null &&
        agent.remoteDisplayName!.isNotEmpty) {
      return demo.maskDisplayName(agent.remoteDisplayName!);
    }
    final raw = agent.remoteIdentity ?? 'Unknown';
    return demo.maskPhone(raw);
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final phase = agent.callPhase;
    final color = _phaseColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.04),
        border: Border(
            bottom: BorderSide(
                color: AppColors.border.withValues(alpha: 0.4), width: 0.5)),
      ),
      child: Row(
        children: [
          // Phase indicator dot + icon
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: color.withValues(alpha: 0.12),
            ),
            child: Icon(
              phase.isActive
                  ? Icons.phone_in_talk_rounded
                  : Icons.phone_rounded,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          // Call details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_directionIcon,
                        size: 10, color: AppColors.textTertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _remoteLabel(demo),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      phase.displayLabel,
                      style: TextStyle(
                        fontSize: 10,
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${agent.partyCount} ${agent.partyCount == 1 ? 'party' : 'parties'}',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (phase.isSettling)
            HoverButton(
              onTap: agent.confirmPartyConnected,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.green.withValues(alpha: 0.15),
                  border: Border.all(
                      color: AppColors.green.withValues(alpha: 0.3),
                      width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_add_alt_1_rounded,
                        size: 12, color: AppColors.green),
                    const SizedBox(width: 4),
                    Text(
                      'Party On',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conference-aware call bar — shows all legs with merge/hold controls
// ---------------------------------------------------------------------------

class _ConferenceCallBar extends StatelessWidget {
  final AgentService agent;
  const _ConferenceCallBar({required this.agent});

  @override
  Widget build(BuildContext context) {
    final conf = context.watch<ConferenceService>();
    final demo = context.watch<DemoModeService>();
    final router = context.watch<InboundCallRouter>();

    // Fallback to original single-call bar when no conference service legs
    if (conf.legCount <= 1 && !conf.hasConference) {
      return _CallInfoBar(agent: agent);
    }

    final legs = conf.legs;
    final hasConference = conf.hasConference;
    final pendingInboundId = router.pendingInbound?.id;

    return Container(
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: AppColors.border.withValues(alpha: 0.4), width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: "(n) ongoing calls"
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Row(
              children: [
                Icon(
                  hasConference
                      ? Icons.groups_rounded
                      : Icons.call_split_rounded,
                  size: 14,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  hasConference
                      ? 'Conference (${legs.length}/${conf.config.effectiveMaxParticipants})'
                      : '${legs.length} ongoing calls',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                if (conf.isMerging)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: AppColors.accent,
                    ),
                  ),
                if (conf.mergeError != null)
                  Tooltip(
                    message: conf.mergeError!,
                    child: Icon(Icons.error_outline,
                        size: 14, color: AppColors.red),
                  ),
              ],
            ),
          ),
          if (hasConference)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4),
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < legs.length; i++)
                          _CallLegRow(
                            leg: legs[i],
                            isFocused: legs[i].sipCallId == conf.focusedLegId,
                            inMergedConference: true,
                            demo: demo,
                            onTap: () => conf.focusLeg(legs[i].sipCallId),
                            onHold: () {
                              if (legs[i].state == LegState.held) {
                                conf.unholdLeg(legs[i].sipCallId);
                              } else {
                                conf.holdLeg(legs[i].sipCallId);
                              }
                            },
                            isPendingInbound:
                                legs[i].sipCallId == pendingInboundId,
                            onHoldAndAnswer: legs[i].sipCallId ==
                                    pendingInboundId
                                ? router.holdCurrentAndAnswer
                                : null,
                            onHangupAndAnswer: legs[i].sipCallId ==
                                    pendingInboundId
                                ? router.hangupCurrentAndAnswer
                                : null,
                            onDeclinePending: legs[i].sipCallId ==
                                    pendingInboundId
                                ? router.decline
                                : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            // Not merged: leg rows with merge connectors between them
            for (int i = 0; i < legs.length; i++) ...[
              _CallLegRow(
                leg: legs[i],
                isFocused: legs[i].sipCallId == conf.focusedLegId,
                demo: demo,
                onTap: () => conf.focusLeg(legs[i].sipCallId),
                onHold: () {
                  if (legs[i].state == LegState.held) {
                    conf.unholdLeg(legs[i].sipCallId);
                  } else {
                    conf.holdLeg(legs[i].sipCallId);
                  }
                },
                isPendingInbound: legs[i].sipCallId == pendingInboundId,
                onHoldAndAnswer: legs[i].sipCallId == pendingInboundId
                    ? router.holdCurrentAndAnswer
                    : null,
                onHangupAndAnswer: legs[i].sipCallId == pendingInboundId
                    ? router.hangupCurrentAndAnswer
                    : null,
                onDeclinePending: legs[i].sipCallId == pendingInboundId
                    ? router.decline
                    : null,
              ),
              if (i < legs.length - 1)
                _MergeConnector(
                  canMerge: conf.canMerge && !conf.isMerging,
                  onMerge: conf.merge,
                ),
            ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _CallLegRow extends StatelessWidget {
  final ConferenceCallLeg leg;
  final bool isFocused;
  final bool inMergedConference;
  final DemoModeService demo;
  final VoidCallback onTap;
  final VoidCallback onHold;

  /// If true, this leg is the InboundCallRouter's pending inbound — render an
  /// accent outline and mini Hold+Answer / Hangup+Answer / Decline buttons.
  final bool isPendingInbound;
  final Future<void> Function()? onHoldAndAnswer;
  final Future<void> Function()? onHangupAndAnswer;
  final Future<void> Function()? onDeclinePending;

  const _CallLegRow({
    required this.leg,
    required this.isFocused,
    this.inMergedConference = false,
    required this.demo,
    required this.onTap,
    required this.onHold,
    this.isPendingInbound = false,
    this.onHoldAndAnswer,
    this.onHangupAndAnswer,
    this.onDeclinePending,
  });

  Color get _stateColor {
    switch (leg.state) {
      case LegState.ringing:
        return AppColors.burntAmber;
      case LegState.active:
      case LegState.merged:
        return AppColors.green;
      case LegState.held:
        return AppColors.accent;
    }
  }

  String get _stateLabel {
    switch (leg.state) {
      case LegState.ringing:
        return 'Ringing';
      case LegState.active:
        return 'Connected';
      case LegState.held:
        return 'On Hold';
      case LegState.merged:
        return 'In Conference';
    }
  }

  String get _displayName {
    if (leg.displayName != null && leg.displayName!.isNotEmpty) {
      return demo.maskDisplayName(leg.displayName!);
    }
    if (leg.remoteNumber.isNotEmpty) {
      return demo.maskPhone(leg.remoteNumber);
    }
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final color = _stateColor;

    return HoverButton(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        decoration: BoxDecoration(
          color: isPendingInbound
              ? AppColors.accent.withValues(alpha: 0.14)
              : isFocused
                  ? AppColors.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
          border: isPendingInbound
              ? Border(
                  left: BorderSide(color: AppColors.accent, width: 2),
                  top: BorderSide(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      width: 0.5),
                  bottom: BorderSide(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      width: 0.5),
                )
              : (isFocused && !inMergedConference
                  ? Border(left: BorderSide(color: AppColors.accent, width: 2))
                  : null),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: color.withValues(alpha: 0.12),
              ),
              child: Icon(
                leg.state == LegState.held
                    ? Icons.pause_rounded
                    : Icons.phone_in_talk_rounded,
                size: 12,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _stateLabel,
                        style: TextStyle(
                          fontSize: 9,
                          color: color,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isPendingInbound) ...[
              _PendingInboundMiniAction(
                icon: Icons.pause_rounded,
                tooltip: 'Hold current & answer',
                background: AppColors.accent,
                foreground: AppColors.onAccent,
                onTap: onHoldAndAnswer,
              ),
              const SizedBox(width: 4),
              _PendingInboundMiniAction(
                icon: Icons.call_end_rounded,
                tooltip: 'Hang up current & answer',
                background: AppColors.red,
                foreground: Colors.white,
                onTap: onHangupAndAnswer,
              ),
              const SizedBox(width: 4),
              HoverButton(
                onTap: onDeclinePending,
                tooltip: 'Decline',
                borderRadius: BorderRadius.circular(7),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: AppColors.surface,
                    border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.4),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(Icons.close_rounded,
                      size: 12, color: AppColors.textTertiary),
                ),
              ),
            ] else
              HoverButton(
                onTap: onHold,
                borderRadius: BorderRadius.circular(7),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: leg.state == LegState.held
                        ? AppColors.accent.withValues(alpha: 0.15)
                        : AppColors.surface,
                    border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.4),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    leg.state == LegState.held
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    size: 14,
                    color: leg.state == LegState.held
                        ? AppColors.accent
                        : AppColors.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingInboundMiniAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final Future<void> Function()? onTap;

  const _PendingInboundMiniAction({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap == null ? null : () => onTap!(),
      tooltip: tooltip,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: background,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 14, color: foreground),
      ),
    );
  }
}

class _MergeConnector extends StatelessWidget {
  final bool canMerge;
  final Future<void> Function() onMerge;

  const _MergeConnector({required this.canMerge, required this.onMerge});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const SizedBox(width: 24),
          // Vertical connecting line
          Container(
            width: 2,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.accent.withValues(alpha: 0.3),
                  AppColors.accent.withValues(alpha: 0.1),
                  AppColors.accent.withValues(alpha: 0.3),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Merge button
          HoverButton(
            onTap: canMerge ? () => onMerge() : null,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: canMerge
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.surface,
                border: Border.all(
                  color: canMerge
                      ? AppColors.accent.withValues(alpha: 0.4)
                      : AppColors.border.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.merge_type_rounded,
                      size: 12,
                      color:
                          canMerge ? AppColors.accent : AppColors.textTertiary),
                  const SizedBox(width: 4),
                  Text(
                    'Merge',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color:
                          canMerge ? AppColors.accent : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  final Color color;
  final bool active;
  const _StatusDot({required this.color, required this.active});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.active) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final glow = widget.active ? 2.0 + _ctrl.value * 4.0 : 0.0;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: glow > 0
                ? [
                    BoxShadow(
                        color: widget.color.withValues(alpha: 0.5),
                        blurRadius: glow,
                        spreadRadius: 0.5)
                  ]
                : null,
          ),
        );
      },
    );
  }
}

class _WaveformPill extends StatelessWidget {
  final List<double> levels;
  final Color color;
  final bool active;
  final bool muted;

  const _WaveformPill({
    required this.levels,
    required this.color,
    required this.active,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = muted ? color.withValues(alpha: 0.3) : color;

    return Container(
      width: 44,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: active
            ? LinearGradient(
                colors: [
                  color.withValues(alpha: 0.15),
                  color.withValues(alpha: 0.08),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: active ? null : AppColors.card,
        border: Border.all(
          color: active
              ? color.withValues(alpha: 0.3)
              : AppColors.border.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: WaveformBars(
        micLevels: levels,
        barCount: 9,
        height: 20,
        primaryColor: effectiveColor,
        secondaryColor: effectiveColor.withValues(alpha: 0.6),
        amplitude: active ? 0.35 : 0.08,
        liveMode: active && !muted,
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color bgColor;
  final VoidCallback? onTap;
  final String tooltip;

  const _HeaderButton({
    required this.icon,
    required this.color,
    required this.bgColor,
    this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap,
      tooltip: tooltip,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: bgColor,
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message List
// ---------------------------------------------------------------------------

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final bool hasMore;
  final Future<bool> Function() onLoadMore;
  final ValueChanged<MessageAction> onAction;
  final bool thinking;

  const _MessageList({
    required this.messages,
    required this.scrollController,
    required this.hasMore,
    required this.onLoadMore,
    required this.onAction,
    this.thinking = false,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  bool _loadingMore = false;
  static const _loadMoreThreshold = 300.0;

  bool _onScrollNotification(ScrollNotification notification) {
    if (!widget.hasMore || _loadingMore) return false;
    // In a reversed ListView, extentAfter is toward older messages (visual top).
    if (notification.metrics.extentAfter < _loadMoreThreshold) {
      _loadingMore = true;
      widget.onLoadMore().then((hasMore) {
        if (mounted) setState(() => _loadingMore = false);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty && !widget.thinking) {
      return Center(
        child: Text(
          'No messages yet',
          style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
        ),
      );
    }

    final thinkingItem = widget.thinking ? 1 : 0;
    final extraItem = (widget.hasMore || _loadingMore) ? 1 : 0;
    final totalItems = widget.messages.length + thinkingItem + extraItem;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        controller: widget.scrollController,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        itemCount: totalItems,
        itemBuilder: (context, index) {
          if (index == 0 && widget.thinking) {
            return const _ThinkingBubble();
          }
          final adjusted = index - thinkingItem;
          if (adjusted >= widget.messages.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final msgIdx = widget.messages.length - 1 - adjusted;
          final msg = widget.messages[msgIdx];
          final isLast = msgIdx == widget.messages.length - 1;
          return _MessageBubble(
            message: msg,
            showActions: isLast && msg.actions.isNotEmpty,
            onAction: widget.onAction,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick SMS from a reminder bubble
// ---------------------------------------------------------------------------

Future<void> _sendReminderSms(BuildContext ctx, ChatMessage message) async {
  final name = message.metadata?['contact_name'] as String? ?? '';
  if (name.isEmpty) {
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('No contact on this reminder')),
      );
    }
    return;
  }

  final results = await CallHistoryDb.searchContacts(name);
  final phone =
      results.isNotEmpty ? results.first['phone_number'] as String? ?? '' : '';
  if (phone.isEmpty) {
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('No phone number found for $name'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    return;
  }

  final contactFirst = name.split(' ').first;
  final body =
      'Hi $contactFirst, just a heads up about our upcoming appointment.';

  try {
    final messaging = ctx.read<MessagingService>();
    await messaging.sendMessage(to: phone, text: body);
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text('SMS sent to $name'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  } catch (_) {
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('Failed to send SMS')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Thinking Bubble (three-dot typing indicator)
// ---------------------------------------------------------------------------

class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble();

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8, right: 60),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.3),
              width: 0.5,
            ),
          ),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  final delay = i * 0.25;
                  final t = ((_ctrl.value - delay) % 1.0).clamp(0.0, 1.0);
                  final y = -3.0 * (1.0 - (2.0 * t - 1.0) * (2.0 * t - 1.0));
                  return Container(
                    margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
                    child: Transform.translate(
                      offset: Offset(0, y),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.textTertiary.withValues(
                            alpha: 0.4 + 0.6 * (1.0 - t),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message Bubble
// ---------------------------------------------------------------------------

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool showActions;
  final ValueChanged<MessageAction> onAction;

  const _MessageBubble({
    required this.message,
    required this.showActions,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isPrevious = message.metadata?['isPreviousCall'] == true ||
        message.metadata?['isPreviousCallHeader'] == true ||
        message.metadata?['isPreviousCallFooter'] == true;

    Widget child;
    if (message.metadata?['voice_capture'] == true) {
      child = _VoiceCaptureBubble(message: message);
    } else if (message.type == MessageType.sms) {
      child = SmsThreadBubble(message: message);
    } else if (message.type == MessageType.callState) {
      child = _CallStatePill(text: message.text);
    } else if (message.type == MessageType.whisper) {
      child = _WhisperBubble(message: message);
    } else if (message.type == MessageType.note) {
      if (message.metadata?['pending_attachment'] == true) {
        child = _PendingNoteBubble(message: message);
      } else {
        child = _NoteBubble(message: message);
      }
    } else if (message.type == MessageType.searchGuide) {
      child = _SearchGuideBubble(message: message);
    } else if (message.type == MessageType.attachment) {
      child = _AttachmentBubble(message: message);
    } else if (message.type == MessageType.reminder) {
      child = _ReminderBubble(
        message: message,
        onAction: (value) {
          final agent = context.read<AgentService>();
          if (value == 'dismiss_reminder') {
            final rid = message.metadata?['reminder_id'] as int?;
            if (rid != null) {
              CallHistoryDb.updateReminderStatus(rid, 'dismissed');
            }
            agent.removeMessage(message);
          } else if (value == 'snooze_reminder') {
            final rid = message.metadata?['reminder_id'] as int?;
            if (rid != null) {
              CallHistoryDb.updateReminderStatus(rid, 'pending');
              CallHistoryDb.insertReminder(
                title: message.text,
                remindAt: DateTime.now().add(const Duration(minutes: 15)),
              );
            }
            agent.removeMessage(message);
          } else if (value == 'confirm_missed_reminder') {
            final rid = message.metadata?['reminder_id'] as int?;
            if (rid != null) {
              CallHistoryDb.updateReminderStatus(rid, 'fired');
            }
            final cleanText =
                message.text.replaceFirst(RegExp(r'^Missed \([^)]+\):\s*'), '');
            agent.sendSystemEvent(
              '[MISSED REMINDER CONFIRMED] Manager wants to proceed with: $cleanText',
              requireResponse: true,
            );
            agent.removeMessage(message);
          } else if (value == 'sms_contact') {
            _sendReminderSms(context, message);
          } else if (value == 'tell_me_more') {
            agent.sendUserMessage('Tell me more about: ${message.text}');
            agent.removeMessage(message);
          }
        },
      );
    } else if (message.metadata?['recording_playback'] == true) {
      child = _InlineRecordingBubble(message: message);
    } else {
      switch (message.role) {
        case ChatRole.system:
          child = _SystemBubble(text: message.text);
          break;
        case ChatRole.user:
          child = _UserBubble(message: message);
          break;
        case ChatRole.agent:
          child = _AgentBubble(
            message: message,
            showActions: showActions,
            voiceSync: context.read<AgentService>().ttsActiveForUi,
            onAction: onAction,
          );
          break;
        case ChatRole.host:
        case ChatRole.remoteParty:
          child = _TranscriptBubble(message: message);
          break;
      }
    }

    if (isPrevious) {
      return Opacity(opacity: 0.5, child: child);
    }
    return child;
  }
}

class _SystemBubble extends StatelessWidget {
  final String text;
  const _SystemBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.card.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, color: AppColors.textTertiary, height: 1.4),
          ),
        ),
      ),
    );
  }
}

class _VoiceCaptureBubble extends StatefulWidget {
  final ChatMessage message;
  const _VoiceCaptureBubble({required this.message});

  @override
  State<_VoiceCaptureBubble> createState() => _VoiceCaptureBubbleState();
}

class _VoiceCaptureBubbleState extends State<_VoiceCaptureBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  Timer? _tickTimer;
  int _elapsedSeconds = 0;

  bool get _isLive => widget.message.isStreaming;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (_isLive) {
      _pulseCtrl.repeat(reverse: true);
      _startTick();
    }
  }

  void _startTick() {
    final agent = context.read<AgentService>();
    final start = agent.agentSamplingStartTime ?? widget.message.timestamp;
    _elapsedSeconds = DateTime.now().difference(start).inSeconds;
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isLive) {
        _tickTimer?.cancel();
        return;
      }
      setState(() {
        _elapsedSeconds = DateTime.now().difference(start).inSeconds;
      });
    });
  }

  @override
  void didUpdateWidget(covariant _VoiceCaptureBubble old) {
    super.didUpdateWidget(old);
    if (!_isLive && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _tickTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  String _fmtTime(int totalSec) {
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final party =
        widget.message.metadata?['capture_party'] as String? ?? 'remote';
    final label = _isLive ? 'Capturing voice ($party)' : widget.message.text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: _isLive ? 0.25 : 0.12),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLive)
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.red
                          .withValues(alpha: 0.5 + 0.5 * _pulseCtrl.value),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.red
                              .withValues(alpha: 0.3 * _pulseCtrl.value),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                )
              else
                Icon(Icons.mic_rounded,
                    size: 12, color: AppColors.textTertiary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: _isLive ? AppColors.accent : AppColors.textTertiary,
                  fontWeight: _isLive ? FontWeight.w500 : FontWeight.w400,
                  height: 1.4,
                ),
              ),
              if (_isLive) ...[
                const SizedBox(width: 8),
                Text(
                  _fmtTime(_elapsedSeconds),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.accent.withValues(alpha: 0.7),
                    fontFamily: AppColors.timerFontFamily,
                    fontFamilyFallback: AppColors.timerFontFamilyFallback,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CallStatePill extends StatelessWidget {
  final String text;
  const _CallStatePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
              child: Divider(
                  color: AppColors.border.withValues(alpha: 0.3), height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_in_talk_rounded,
                    size: 10,
                    color: AppColors.textTertiary.withValues(alpha: 0.7)),
                const SizedBox(width: 5),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textTertiary.withValues(alpha: 0.7),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
              child: Divider(
                  color: AppColors.border.withValues(alpha: 0.3), height: 1)),
        ],
      ),
    );
  }
}

class _AgentBubble extends StatelessWidget {
  final ChatMessage message;
  final bool showActions;
  final bool voiceSync;
  final ValueChanged<MessageAction> onAction;

  const _AgentBubble({
    required this.message,
    required this.showActions,
    this.voiceSync = false,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final String? agentName =
        context.read<JobFunctionService>().selected?.agentName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: AppColors.bg,
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            child: Icon(Icons.auto_awesome, size: 12, color: AppColors.accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(
                        color: AppColors.border.withValues(alpha: 0.5),
                        width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            agentName != null ? 'AI ($agentName)' : 'AI',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(_formatTime(message.timestamp),
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary
                                    .withValues(alpha: 0.7),
                              )),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: StreamingTypingText(
                              key: ValueKey(message.id),
                              fullText: message.text,
                              isStreaming: message.isStreaming,
                              voiceSync: voiceSync,
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                                height: 1.45,
                              ),
                            ),
                          ),
                          if (message.isStreaming) ...[
                            const SizedBox(width: 4),
                            _StreamingCursor(),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (showActions) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: message.actions
                        .map((a) => _ActionChip(
                              label: a.label,
                              onTap: () => onAction(a),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 40),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_formatTime(message.timestamp),
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textTertiary.withValues(alpha: 0.7),
                        )),
                    const SizedBox(width: 6),
                    Text('You',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textTertiary,
                        )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.12),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.2),
                        width: 0.5),
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width annotation bubble for `/w` / `/whisper` entries — sibling
/// of `_NoteBubble`. The same two-panel aesthetic (left accent bar +
/// header chip) so whispers read as a distinct channel at a glance,
/// themed via `AppColors.burntAmber` (amber on VT-100, purple on Miami).
class _WhisperBubble extends StatelessWidget {
  final ChatMessage message;
  const _WhisperBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final whisperColor = AppColors.burntAmber;
    final bodyColor = whisperColor.withValues(alpha: 0.07);
    final borderColor = whisperColor.withValues(alpha: 0.30);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Container(
        decoration: BoxDecoration(
          color: bodyColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: whisperColor,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.hearing_disabled_outlined,
                              size: 13, color: whisperColor),
                          const SizedBox(width: 6),
                          Text(
                            'WHISPER',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: whisperColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              color: whisperColor.withValues(alpha: 0.4),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(message.timestamp),
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary
                                  .withValues(alpha: 0.75),
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const Spacer(),
                          Icon(Icons.voice_over_off_rounded,
                              size: 11,
                              color: whisperColor.withValues(alpha: 0.55)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        message.text,
                        style: TextStyle(
                          fontSize: 12.5,
                          color:
                              AppColors.textPrimary.withValues(alpha: 0.88),
                          fontStyle: FontStyle.italic,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slick, full-width annotation bubble for `/note` entries — styled as a
/// warm sticky-note with a left accent bar, pin icon, and NOTE chip so it
/// reads as a first-class annotation rather than a chat turn.
class _NoteBubble extends StatelessWidget {
  final ChatMessage message;
  const _NoteBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final noteColor = AppColors.orange;
    final bodyColor = noteColor.withValues(alpha: 0.08);
    final borderColor = noteColor.withValues(alpha: 0.35);

    final attachedName = message.metadata?['attached_call_name'] as String?;
    final attachedId = message.metadata?['attached_call_id'] as int?;
    final attachedPhone = message.metadata?['attached_call_phone'] as String?;
    final attachedDirection =
        message.metadata?['attached_call_direction'] as String?;
    final attachedTime =
        message.metadata?['attached_call_time_label'] as String?;
    final attachedTranscriptId =
        message.metadata?['attached_call_transcript_id'] as int?;
    final hasAttachment = attachedId != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Container(
        decoration: BoxDecoration(
          color: bodyColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: noteColor,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.sticky_note_2_outlined,
                              size: 13, color: noteColor),
                          const SizedBox(width: 6),
                          Text(
                            'NOTE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: noteColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              color: noteColor.withValues(alpha: 0.4),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(message.timestamp),
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary
                                  .withValues(alpha: 0.75),
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const Spacer(),
                          Icon(Icons.push_pin_outlined,
                              size: 11,
                              color: noteColor.withValues(alpha: 0.55)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        message.text,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textPrimary.withValues(alpha: 0.9),
                          height: 1.45,
                        ),
                      ),
                      if (hasAttachment) ...[
                        const SizedBox(height: 8),
                        _NoteAttachmentFooter(
                          callId: attachedId,
                          transcriptId: attachedTranscriptId,
                          noteText: message.text,
                          name: attachedName,
                          phone: attachedPhone,
                          direction: attachedDirection,
                          timeLabel: attachedTime,
                          accent: noteColor,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Attached to a call to Patrick at 10:40 PM · [history icon]" — footer
/// shown on finalized notes with a call attachment. The history icon opens
/// the call-history panel and jumps to the attached call.
class _NoteAttachmentFooter extends StatelessWidget {
  final int? callId;
  final int? transcriptId;
  final String noteText;
  final String? name;
  final String? phone;
  final String? direction;
  final String? timeLabel;
  final Color accent;
  const _NoteAttachmentFooter({
    required this.callId,
    required this.transcriptId,
    required this.noteText,
    required this.name,
    required this.phone,
    required this.direction,
    required this.timeLabel,
    required this.accent,
  });

  String get _descriptor {
    final who = (name != null && name!.isNotEmpty)
        ? name!
        : (phone != null && phone!.isNotEmpty ? phone! : 'an unknown caller');
    final preposition = direction == 'outbound' ? 'to' : 'from';
    final atTime =
        (timeLabel != null && timeLabel!.isNotEmpty) ? ' at $timeLabel' : '';
    return 'Attached to a call $preposition $who$atTime';
  }

  Future<void> _openInHistory(BuildContext context) async {
    final id = callId;
    if (id == null) return;
    final history = context.read<CallHistoryService>();

    // Older notes (created before `attached_call_transcript_id` was
    // stored on metadata) may land here without a specific transcript
    // id. Fall back to a text-match lookup so the deep-link can still
    // land on the right row instead of just opening the call.
    int? tid = transcriptId;
    if (tid == null && noteText.isNotEmpty) {
      tid = await CallHistoryDb.resolveNoteTranscriptId(id, noteText);
      debugPrint('[NoteFooter] resolved tid=$tid for call=$id via text match');
    }

    await history.focusCall(
      id,
      phoneNumber: phone,
      transcriptId: tid,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canOpen = callId != null;
    final textStyle = TextStyle(
      fontSize: 10,
      fontStyle: FontStyle.italic,
      color: accent.withValues(alpha: 0.85),
    );

    return Row(
      children: [
        Icon(Icons.link_rounded, size: 11, color: accent.withValues(alpha: 0.7)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            _descriptor,
            style: textStyle,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        if (canOpen)
          HoverButton(
            onTap: () => _openInHistory(context),
            tooltip: 'Open this call in call history',
            borderRadius: BorderRadius.circular(4),
            hoverColor: accent.withValues(alpha: 0.18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.history_rounded,
                size: 13,
                color: accent.withValues(alpha: 0.85),
              ),
            ),
          ),
      ],
    );
  }
}

/// Inline "where should this note go?" card — shown when `/note` is typed
/// with no active call. Lists the most recent calls so the manager can tag
/// the note to one with a single tap, or finalize it as a free-floating
/// session note.
class _PendingNoteBubble extends StatelessWidget {
  final ChatMessage message;
  const _PendingNoteBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final noteColor = AppColors.orange;
    final rawCandidates =
        (message.metadata?['candidates'] as List?) ?? const [];
    final candidates = rawCandidates
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Container(
        decoration: BoxDecoration(
          color: noteColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: noteColor.withValues(alpha: 0.35), width: 0.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: noteColor,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.sticky_note_2_outlined,
                              size: 13, color: noteColor),
                          const SizedBox(width: 6),
                          Text(
                            'NEW NOTE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: noteColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              color: noteColor.withValues(alpha: 0.4),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(message.timestamp),
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary
                                  .withValues(alpha: 0.75),
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const Spacer(),
                          HoverButton(
                            onTap: () => context
                                .read<AgentService>()
                                .removeMessage(message),
                            tooltip: 'Discard note',
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(Icons.close_rounded,
                                  size: 13,
                                  color: AppColors.textTertiary
                                      .withValues(alpha: 0.7)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        message.text,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textPrimary.withValues(alpha: 0.9),
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _NoteCandidateDivider(label: 'Attach to a recent call?'),
                      const SizedBox(height: 4),
                      ...candidates.map((c) => _NoteCandidateRow(
                            pending: message,
                            candidate: c,
                            accent: noteColor,
                          )),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: HoverButton(
                          onTap: () => context
                              .read<AgentService>()
                              .confirmNoteAsSession(message),
                          tooltip: 'Keep as a free-floating session note',
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bookmark_border_rounded,
                                    size: 11,
                                    color: AppColors.textTertiary
                                        .withValues(alpha: 0.85)),
                                const SizedBox(width: 4),
                                Text(
                                  'Keep as session note',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textTertiary
                                        .withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteCandidateDivider extends StatelessWidget {
  final String label;
  const _NoteCandidateDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 0.5,
            color: AppColors.border.withValues(alpha: 0.5),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: AppColors.textTertiary.withValues(alpha: 0.85),
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 0.5,
            color: AppColors.border.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }
}

class _NoteCandidateRow extends StatelessWidget {
  final ChatMessage pending;
  final Map<String, dynamic> candidate;
  final Color accent;
  const _NoteCandidateRow({
    required this.pending,
    required this.candidate,
    required this.accent,
  });

  String get _name => (candidate['name'] as String?)?.trim().isNotEmpty == true
      ? candidate['name'] as String
      : (candidate['phone'] as String? ?? 'Unknown');

  bool get _isOutbound => candidate['direction'] == 'outbound';
  bool get _isMissed => (candidate['status'] as String?) == 'missed';

  String get _subline {
    final parts = <String>[];
    final dur = (candidate['duration_seconds'] ?? 0) as int;
    if (_isMissed) {
      parts.add('missed');
    } else if (dur > 0) {
      final m = dur ~/ 60;
      final s = dur % 60;
      parts.add(m > 0 ? '${m}m ${s}s' : '${s}s');
    }
    parts.add(_isOutbound ? 'outbound' : 'inbound');
    final started = candidate['started_at'] as String? ?? '';
    final rel = _relativeTime(started);
    if (rel.isNotEmpty) parts.add(rel);
    return parts.join(' · ');
  }

  static String _relativeTime(String iso) {
    if (iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final agent = context.read<AgentService>();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: HoverButton(
        onTap: () => agent.attachNoteToCall(pending, candidate),
        tooltip: 'Attach note to call with $_name',
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.card.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.border.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _isMissed
                      ? Icons.call_missed_rounded
                      : _isOutbound
                          ? Icons.call_made_rounded
                          : Icons.call_received_rounded,
                  size: 12,
                  color: _isMissed ? AppColors.red : accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary.withValues(alpha: 0.92),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _subline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textTertiary.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.link_rounded,
                  size: 13, color: accent.withValues(alpha: 0.65)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search-guide bubble (/search command)
// ---------------------------------------------------------------------------

/// Inline recap card produced by `/search <name>`. Renders as a compact
/// themed panel with:
///
///   1. a header row (search icon + SEARCH label + query + timestamp + ×),
///   2. one row of contact chips when multiple contacts matched,
///   3. three check-toggle chips (Calls / Messages / Calendar) that feed
///      into `AgentService.executeSearchGuide`, and
///   4. a trailing action button ("Search" → "Searching…" → a compact
///      results summary once the work finishes).
///
/// Visually parallels `_PendingNoteBubble` (left accent bar, full-width
/// rounded panel) so it reads as "first-class inline action" rather
/// than a chat turn.
class _SearchGuideBubble extends StatelessWidget {
  final ChatMessage message;
  const _SearchGuideBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final meta = message.metadata ?? const {};
    final query = (meta['query'] as String?) ?? message.text;
    final stage = (meta['stage'] as String?) ?? 'pending';

    final rawContacts = (meta['contacts'] as List?) ?? const [];
    final contacts = rawContacts
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    // Phase 2: multi-select. Support legacy selected_index for old bubbles
    // that were persisted under the single-select schema.
    final rawSel = meta['selected_indices'];
    Set<int> selectedIndices;
    if (rawSel is List) {
      selectedIndices = rawSel.whereType<int>().toSet();
    } else {
      final legacy = meta['selected_index'] as int?;
      selectedIndices = legacy != null ? {legacy} : {0};
    }
    // Clamp to valid range.
    selectedIndices = selectedIndices
        .where((i) => i >= 0 && i < contacts.length)
        .toSet();
    if (selectedIndices.isEmpty && contacts.isNotEmpty) {
      selectedIndices = {0};
    }

    final includeCalls = (meta['include_calls'] as bool?) ?? true;
    final includeMessages = (meta['include_messages'] as bool?) ?? true;
    final includeCalendar = (meta['include_calendar'] as bool?) ?? true;
    final includeNotes = (meta['include_notes'] as bool?) ?? true;

    final resultSummary = meta['result_summary'] as String?;

    final callRows = ((meta['call_rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final messageRows = ((meta['message_rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final noteRows = ((meta['note_rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final calendarRows = ((meta['calendar_rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: accent.withValues(alpha: 0.30), width: 0.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SearchGuideHeader(
                        query: query,
                        stage: stage,
                        timestamp: message.timestamp,
                        accent: accent,
                        onClose: () => context
                            .read<AgentService>()
                            .dismissSearchGuide(message),
                      ),
                      if (contacts.length > 1) ...[
                        const SizedBox(height: 8),
                        _SearchContactChipRow(
                          contacts: contacts,
                          selectedIndices: selectedIndices,
                          accent: accent,
                          disabled: stage != 'pending',
                          onToggle: (i) => context
                              .read<AgentService>()
                              .toggleSearchContact(message, i),
                        ),
                      ] else if (contacts.length == 1) ...[
                        const SizedBox(height: 6),
                        _SearchContactLine(
                          contact: contacts.first,
                          accent: accent,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _SearchOptionChip(
                            label: 'Calls',
                            icon: Icons.call_outlined,
                            checked: includeCalls,
                            accent: accent,
                            disabled: stage != 'pending',
                            onTap: () => context
                                .read<AgentService>()
                                .toggleSearchOption(message, 'include_calls'),
                          ),
                          _SearchOptionChip(
                            label: 'Messages',
                            icon: Icons.chat_bubble_outline,
                            checked: includeMessages,
                            accent: accent,
                            disabled: stage != 'pending',
                            onTap: () => context
                                .read<AgentService>()
                                .toggleSearchOption(
                                    message, 'include_messages'),
                          ),
                          _SearchOptionChip(
                            label: 'Calendar',
                            icon: Icons.calendar_today_outlined,
                            checked: includeCalendar,
                            accent: accent,
                            disabled: stage != 'pending',
                            onTap: () => context
                                .read<AgentService>()
                                .toggleSearchOption(
                                    message, 'include_calendar'),
                          ),
                          _SearchOptionChip(
                            label: 'Notes',
                            icon: Icons.sticky_note_2_outlined,
                            checked: includeNotes,
                            accent: accent,
                            disabled: stage != 'pending',
                            onTap: () => context
                                .read<AgentService>()
                                .toggleSearchOption(message, 'include_notes'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (stage == 'done') ...[
                        _SearchGuideResultList(
                          accent: accent,
                          includeCalls: includeCalls,
                          includeMessages: includeMessages,
                          includeCalendar: includeCalendar,
                          includeNotes: includeNotes,
                          callRows: callRows,
                          messageRows: messageRows,
                          noteRows: noteRows,
                          calendarRows: calendarRows,
                        ),
                        if (resultSummary != null) ...[
                          const SizedBox(height: 10),
                          _SearchGuideResultFooter(
                            summary: resultSummary,
                            accent: accent,
                          ),
                        ],
                      ] else
                        _SearchGuideActionButton(
                          stage: stage,
                          accent: accent,
                          enabled: contacts.isNotEmpty &&
                              selectedIndices.isNotEmpty &&
                              (includeCalls ||
                                  includeMessages ||
                                  includeCalendar ||
                                  includeNotes),
                          onTap: () => context
                              .read<AgentService>()
                              .executeSearchGuide(message),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchGuideHeader extends StatelessWidget {
  final String query;
  final String stage;
  final DateTime timestamp;
  final Color accent;
  final VoidCallback onClose;

  const _SearchGuideHeader({
    required this.query,
    required this.stage,
    required this.timestamp,
    required this.accent,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final label = stage == 'done' ? 'SEARCH · DONE' : 'SEARCH';
    return Row(
      children: [
        Icon(Icons.search_rounded, size: 14, color: accent),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: accent,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 3,
          height: 3,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            query,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textPrimary.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatTime(timestamp),
          style: TextStyle(
            fontSize: 10,
            color: AppColors.textTertiary.withValues(alpha: 0.75),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        HoverButton(
          onTap: onClose,
          tooltip: 'Dismiss',
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.close_rounded,
              size: 13,
              color: AppColors.textTertiary.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
}

/// Horizontal chip row for the `/search` guide. Shares a scroll
/// controller with a right-edge fade so overflow is obvious even
/// without a scrollbar (the row is only 26px tall, so showing a
/// scrollbar would feel clunky).
///
/// The fade is driven by the scroll position: fully visible on the
/// right when there's more content off-screen, and also appears on
/// the left once the user has scrolled past the start.
class _SearchContactChipRow extends StatefulWidget {
  final List<Map<String, dynamic>> contacts;
  final Set<int> selectedIndices;
  final Color accent;
  final bool disabled;
  final ValueChanged<int> onToggle;

  const _SearchContactChipRow({
    required this.contacts,
    required this.selectedIndices,
    required this.accent,
    required this.disabled,
    required this.onToggle,
  });

  @override
  State<_SearchContactChipRow> createState() => _SearchContactChipRowState();
}

class _SearchContactChipRowState extends State<_SearchContactChipRow> {
  final ScrollController _controller = ScrollController();
  bool _hasLeft = false;
  bool _hasRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEdges());
  }

  @override
  void didUpdateWidget(covariant _SearchContactChipRow old) {
    super.didUpdateWidget(old);
    // Chip counts / labels may have changed; recalc after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEdges());
  }

  void _updateEdges() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final left = pos.pixels > 0.5;
    final right = pos.pixels < pos.maxScrollExtent - 0.5;
    if (left != _hasLeft || right != _hasRight) {
      setState(() {
        _hasLeft = left;
        _hasRight = right;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEdges);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      // ShaderMask in `dstIn` mode multiplies the child's alpha by the
      // gradient alpha, so an opaque-in-the-middle / transparent-at-the-
      // edges gradient becomes an edge fade over whatever's inside.
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          const fadeWidth = 18.0;
          final w = rect.width;
          if (w <= fadeWidth * 2) {
            return const LinearGradient(
              colors: [Colors.white, Colors.white],
            ).createShader(rect);
          }
          final leftStop = _hasLeft ? fadeWidth / w : 0.0;
          final rightStop = _hasRight ? 1.0 - fadeWidth / w : 1.0;
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              _hasLeft ? Colors.transparent : Colors.white,
              Colors.white,
              Colors.white,
              _hasRight ? Colors.transparent : Colors.white,
            ],
            stops: [0.0, leftStop, rightStop, 1.0],
          ).createShader(rect);
        },
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          itemCount: widget.contacts.length,
          clipBehavior: Clip.hardEdge,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.only(right: 8),
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, i) => _SearchContactChip(
            contact: widget.contacts[i],
            selected: widget.selectedIndices.contains(i),
            accent: widget.accent,
            disabled: widget.disabled,
            onTap: () => widget.onToggle(i),
          ),
        ),
      ),
    );
  }
}

class _SearchContactChip extends StatelessWidget {
  final Map<String, dynamic> contact;
  final bool selected;
  final Color accent;
  final bool disabled;
  final VoidCallback onTap;

  const _SearchContactChip({
    required this.contact,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = (contact['name'] as String?)?.trim().isNotEmpty == true
        ? contact['name'] as String
        : (contact['phone'] as String? ?? 'Unknown');

    final fg = disabled
        ? AppColors.textTertiary.withValues(alpha: 0.55)
        : (selected ? accent : AppColors.textSecondary);

    return HoverButton(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.18)
              : AppColors.card.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.55)
                : AppColors.border.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.check_rounded
                  : Icons.person_outline_rounded,
              size: 12,
              color: fg,
            ),
            const SizedBox(width: 5),
            Text(
              name,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchContactLine extends StatelessWidget {
  final Map<String, dynamic> contact;
  final Color accent;
  const _SearchContactLine({required this.contact, required this.accent});

  @override
  Widget build(BuildContext context) {
    final name = (contact['name'] as String?)?.trim().isNotEmpty == true
        ? contact['name'] as String
        : (contact['phone'] as String? ?? 'Unknown');
    final phone = contact['phone'] as String? ?? '';
    return Row(
      children: [
        Icon(Icons.person_rounded, size: 12, color: accent),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            phone.isNotEmpty && phone != name ? '$name · $phone' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary.withValues(alpha: 0.9),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchOptionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool checked;
  final Color accent;
  final bool disabled;
  final VoidCallback onTap;

  const _SearchOptionChip({
    required this.label,
    required this.icon,
    required this.checked,
    required this.accent,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = checked
        ? accent.withValues(alpha: 0.15)
        : AppColors.card.withValues(alpha: 0.5);
    final borderColor = checked
        ? accent.withValues(alpha: 0.5)
        : AppColors.border.withValues(alpha: 0.5);
    final fg = disabled
        ? AppColors.textTertiary.withValues(alpha: 0.5)
        : (checked ? accent : AppColors.textSecondary);

    return HoverButton(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 13,
              color: fg,
            ),
            const SizedBox(width: 5),
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: checked ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchGuideActionButton extends StatelessWidget {
  final String stage;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  const _SearchGuideActionButton({
    required this.stage,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final running = stage == 'running';
    final active = enabled && !running;
    final bg = active
        ? accent
        : accent.withValues(alpha: 0.20);
    final fg = active
        ? AppColors.onAccent
        : AppColors.textTertiary.withValues(alpha: 0.8);

    return Align(
      alignment: Alignment.centerLeft,
      child: HoverButton(
        onTap: active ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? accent
                  : accent.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                  ),
                )
              else
                Icon(Icons.search_rounded, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(
                running ? 'Searching…' : 'Search',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchGuideResultFooter extends StatelessWidget {
  final String summary;
  final Color accent;
  const _SearchGuideResultFooter({
    required this.summary,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.check_circle_rounded,
          size: 13,
          color: accent.withValues(alpha: 0.85),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// /search — inline result list + row widgets
// ---------------------------------------------------------------------------

const int _kSearchResultRowLimit = 5;

class _SearchGuideResultList extends StatelessWidget {
  final Color accent;
  final bool includeCalls;
  final bool includeMessages;
  final bool includeCalendar;
  final bool includeNotes;
  final List<Map<String, dynamic>> callRows;
  final List<Map<String, dynamic>> messageRows;
  final List<Map<String, dynamic>> noteRows;
  final List<Map<String, dynamic>> calendarRows;

  const _SearchGuideResultList({
    required this.accent,
    required this.includeCalls,
    required this.includeMessages,
    required this.includeCalendar,
    required this.includeNotes,
    required this.callRows,
    required this.messageRows,
    required this.noteRows,
    required this.calendarRows,
  });

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[];

    if (includeCalls && callRows.isNotEmpty) {
      sections.add(_buildSection(
        icon: Icons.call_outlined,
        label: 'Calls',
        total: callRows.length,
        rows: callRows
            .take(_kSearchResultRowLimit)
            .map((r) => _SearchResultCallRow(row: r, accent: accent))
            .toList(),
        extra: callRows.length - _kSearchResultRowLimit,
      ));
    }
    if (includeMessages && messageRows.isNotEmpty) {
      sections.add(_buildSection(
        icon: Icons.chat_bubble_outline,
        label: 'Messages',
        total: messageRows.length,
        rows: messageRows
            .take(_kSearchResultRowLimit)
            .map((r) => _SearchResultMessageRow(row: r, accent: accent))
            .toList(),
        extra: messageRows.length - _kSearchResultRowLimit,
      ));
    }
    if (includeNotes && noteRows.isNotEmpty) {
      sections.add(_buildSection(
        icon: Icons.sticky_note_2_outlined,
        label: 'Notes',
        total: noteRows.length,
        rows: noteRows
            .take(_kSearchResultRowLimit)
            .map((r) => _SearchResultNoteRow(row: r, accent: accent))
            .toList(),
        extra: noteRows.length - _kSearchResultRowLimit,
      ));
    }
    if (includeCalendar && calendarRows.isNotEmpty) {
      sections.add(_buildSection(
        icon: Icons.calendar_today_outlined,
        label: 'Calendar',
        total: calendarRows.length,
        rows: calendarRows
            .take(_kSearchResultRowLimit)
            .map((r) => _SearchResultCalendarRow(row: r, accent: accent))
            .toList(),
        extra: calendarRows.length - _kSearchResultRowLimit,
      ));
    }

    if (sections.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 13,
                color: AppColors.textTertiary.withValues(alpha: 0.7)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'No results for the selected contacts.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          sections[i],
        ],
      ],
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String label,
    required int total,
    required List<Widget> rows,
    required int extra,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 5),
          child: Row(
            children: [
              Icon(icon,
                  size: 11, color: accent.withValues(alpha: 0.85)),
              const SizedBox(width: 5),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: accent.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$total',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          rows[i],
        ],
        if (extra > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              '… and $extra more',
              style: TextStyle(
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
                color: AppColors.textTertiary.withValues(alpha: 0.7),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared row shell: left icon column + body + trailing metadata.
// ---------------------------------------------------------------------------

class _SearchResultRowShell extends StatelessWidget {
  final Widget leading;
  final Widget body;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SearchResultRowShell({
    required this.leading,
    required this.body,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 22, child: Center(child: leading)),
            const SizedBox(width: 8),
            Expanded(child: body),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

String _searchRowRelative(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final local = dt.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${local.month}/${local.day}';
}

class _SearchResultCallRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final Color accent;
  const _SearchResultCallRow({required this.row, required this.accent});

  @override
  Widget build(BuildContext context) {
    final dir = (row['direction'] as String?) ?? '';
    final status = (row['status'] as String?) ?? '';
    final duration = (row['duration_seconds'] ?? 0) as int;
    final isMissed = status == 'missed' ||
        (dir == 'inbound' && duration == 0 && status != 'answered');
    final name = (row['contact_name'] as String?)?.trim().isNotEmpty == true
        ? row['contact_name'] as String
        : (row['remote_display_name'] as String?)?.trim().isNotEmpty == true
            ? row['remote_display_name'] as String
            : (row['remote_identity'] as String? ?? 'Unknown');

    final dirIcon = isMissed
        ? Icons.phone_missed_rounded
        : (dir == 'outbound'
            ? Icons.call_made_rounded
            : Icons.call_received_rounded);
    final dirColor = isMissed
        ? AppColors.orange
        : (dir == 'outbound'
            ? accent
            : AppColors.textSecondary);

    final durStr = duration > 0
        ? (duration >= 60
            ? '${duration ~/ 60}m ${duration % 60}s'
            : '${duration}s')
        : (isMissed ? 'missed' : '');

    final time = _searchRowRelative(row['started_at'] as String?);
    final recordingPath =
        (row['recording_path'] as String?)?.trim() ?? '';
    final hasRecording = recordingPath.isNotEmpty;

    return _SearchResultRowShell(
      leading: Icon(dirIcon, size: 13, color: dirColor),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary.withValues(alpha: 0.9),
                  ),
                ),
              ),
              if (hasRecording) ...[
                const SizedBox(width: 5),
                Tooltip(
                  message: 'Call was recorded — tap to play',
                  child: SvgPicture.asset(
                    'assets/tape_reel.svg',
                    width: 12,
                    height: 12,
                    colorFilter: ColorFilter.mode(
                      accent.withValues(alpha: 0.9),
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (durStr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                durStr,
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textTertiary.withValues(alpha: 0.75),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
      trailing: time.isEmpty
          ? null
          : Text(
              time,
              style: TextStyle(
                fontSize: 10,
                color: AppColors.textTertiary.withValues(alpha: 0.7),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
      onTap: () {
        final rawId = row['id'];
        final id = rawId is int
            ? rawId
            : (rawId is num ? rawId.toInt() : null);
        debugPrint('[SearchRecap] call-row tap id=$rawId (${rawId.runtimeType}) '
            '→ ${id ?? "invalid"}');
        if (id == null) return;
        try {
          Provider.of<CallHistoryService>(context, listen: false).focusCall(
            id,
            phoneNumber: row['remote_identity'] as String?,
            preloadedRecord: row,
          );
        } catch (e) {
          debugPrint('[SearchRecap] call-row focusCall failed: $e');
        }
      },
    );
  }
}

class _SearchResultMessageRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final Color accent;
  const _SearchResultMessageRow({required this.row, required this.accent});

  @override
  Widget build(BuildContext context) {
    final dir = (row['direction'] as String?) ?? '';
    final isOutbound = dir == 'outbound';
    final body = (row['body'] as String? ?? '').trim();
    final time = _searchRowRelative(row['created_at'] as String?);
    final remotePhone = (row['remote_phone'] as String? ??
            row['remote_identity'] as String? ??
            row['phone_number'] as String? ??
            '')
        .trim();

    // Inline mini bubble — rounded rect tinted per direction.
    final bubbleColor = isOutbound
        ? accent.withValues(alpha: 0.18)
        : AppColors.card.withValues(alpha: 0.9);
    final textColor = isOutbound
        ? AppColors.textPrimary
        : AppColors.textPrimary.withValues(alpha: 0.9);

    return _SearchResultRowShell(
      leading: Icon(
        isOutbound
            ? Icons.arrow_upward_rounded
            : Icons.arrow_downward_rounded,
        size: 13,
        color: isOutbound ? accent : AppColors.textSecondary,
      ),
      body: Align(
        alignment:
            isOutbound ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(10),
              topRight: const Radius.circular(10),
              bottomLeft: Radius.circular(isOutbound ? 10 : 3),
              bottomRight: Radius.circular(isOutbound ? 3 : 10),
            ),
            border: Border.all(
              color: isOutbound
                  ? accent.withValues(alpha: 0.35)
                  : AppColors.border.withValues(alpha: 0.4),
              width: 0.5,
            ),
          ),
          child: Text(
            body.isEmpty ? '(empty)' : body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: textColor,
            ),
          ),
        ),
      ),
      trailing: time.isEmpty
          ? null
          : Text(
              time,
              style: TextStyle(
                fontSize: 10,
                color: AppColors.textTertiary.withValues(alpha: 0.7),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
      onTap: remotePhone.isEmpty
          ? null
          : () {
              try {
                Provider.of<MessagingService>(context, listen: false)
                    .openToConversation(remotePhone);
              } catch (_) {}
            },
    );
  }
}

class _SearchResultNoteRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final Color accent;
  const _SearchResultNoteRow({required this.row, required this.accent});

  @override
  Widget build(BuildContext context) {
    final text = (row['text'] as String? ?? '').trim();
    final contactName =
        (row['contact_name'] as String?)?.trim().isNotEmpty == true
            ? row['contact_name'] as String
            : (row['remote_display_name'] as String?)?.trim().isNotEmpty ==
                    true
                ? row['remote_display_name'] as String
                : (row['remote_identity'] as String? ?? 'contact');
    final rel = _searchRowRelative(row['timestamp'] as String?);

    return _SearchResultRowShell(
      leading: Icon(
        Icons.sticky_note_2_outlined,
        size: 13,
        color: AppColors.orange.withValues(alpha: 0.85),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.isEmpty ? '(empty note)' : text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              fontStyle: FontStyle.italic,
              color: AppColors.textPrimary.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            rel.isNotEmpty
                ? 'from call with $contactName · $rel'
                : 'from call with $contactName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textTertiary.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
      onTap: () {
        final callId = row['call_record_id'];
        final tid = row['transcript_id'];
        if (callId is int) {
          try {
            Provider.of<CallHistoryService>(context, listen: false).focusCall(
              callId,
              phoneNumber: row['remote_identity'] as String?,
              transcriptId: tid is int ? tid : null,
            );
          } catch (_) {}
        }
      },
    );
  }
}

class _SearchResultCalendarRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final Color accent;
  const _SearchResultCalendarRow({required this.row, required this.accent});

  /// Build a Google Calendar day-view URL for the given YYYY-MM-DD.
  /// Falls back to today's calendar root if the date can't be parsed.
  static String _calendarUrlFor(String ymd) {
    final dt = DateTime.tryParse(ymd);
    if (dt == null) return 'https://calendar.google.com/calendar/u/0/r/day';
    return 'https://calendar.google.com/calendar/u/0/r/day/'
        '${dt.year}/${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    final title = (row['title'] as String? ?? '').trim();
    final startTime = (row['startTime'] as String? ?? '').trim();
    final location = (row['location'] as String? ?? '').trim();
    final day = (row['day'] as String? ?? '').trim();
    final date = (row['date'] as String? ?? '').trim();

    final dayLabel = day.isEmpty
        ? ''
        : '${day[0].toUpperCase()}${day.substring(1)}';

    return _SearchResultRowShell(
      leading: Icon(
        Icons.event_outlined,
        size: 13,
        color: accent.withValues(alpha: 0.85),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.isEmpty ? '(untitled event)' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary.withValues(alpha: 0.9),
            ),
          ),
          if (dayLabel.isNotEmpty ||
              startTime.isNotEmpty ||
              location.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                [
                  if (dayLabel.isNotEmpty) dayLabel,
                  if (startTime.isNotEmpty) startTime,
                  if (location.isNotEmpty) location,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textTertiary.withValues(alpha: 0.75),
                ),
              ),
            ),
        ],
      ),
      trailing: Icon(
        Icons.open_in_new_rounded,
        size: 11,
        color: accent.withValues(alpha: 0.6),
      ),
      onTap: () {
        final url = _calendarUrlFor(date);
        try {
          Provider.of<AgentService>(context, listen: false)
              .openUrlInBrowser(url);
        } catch (_) {}
      },
    );
  }
}

class _AttachmentBubble extends StatelessWidget {
  final ChatMessage message;
  const _AttachmentBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final fileName = message.metadata?['fileName'] as String? ?? 'file';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 40),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_formatTime(message.timestamp),
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textTertiary.withValues(alpha: 0.5),
                        )),
                    const SizedBox(width: 6),
                    Icon(Icons.attach_file_rounded,
                        size: 10,
                        color: AppColors.accent.withValues(alpha: 0.6)),
                    const SizedBox(width: 3),
                    Text('File',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent.withValues(alpha: 0.6),
                        )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.06),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.15),
                        width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.accent.withValues(alpha: 0.12),
                        ),
                        child: Icon(Icons.description_outlined,
                            size: 14, color: AppColors.accent),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fileName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              'Sent to agent (silent)',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textTertiary,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptBubble extends StatelessWidget {
  final ChatMessage message;
  const _TranscriptBubble({required this.message});

  Color get _pillColor {
    return message.role == ChatRole.host
        ? AppColors.hotSignal
        : AppColors.burntAmber;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _pillColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              message.speakerName ??
                  (message.role == ChatRole.host ? 'Host' : 'RP1'),
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: _pillColor,
                  height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary.withValues(alpha: 0.85),
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _formatTime(message.timestamp),
            style: TextStyle(
                fontSize: 9,
                color: AppColors.textTertiary.withValues(alpha: 0.6),
                height: 1.4),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Streaming cursor
// ---------------------------------------------------------------------------

class _StreamingCursor extends StatefulWidget {
  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Opacity(
        opacity: 0.3 + _ctrl.value * 0.7,
        child: Container(
          width: 2,
          height: 14,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Action chips
// ---------------------------------------------------------------------------

class _ActionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ActionChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: AppColors.card,
          border: Border.all(
              color: AppColors.border.withValues(alpha: 0.6), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.accent,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Input Bar
// ---------------------------------------------------------------------------

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onWhisperSend;
  final VoidCallback? onToggleWhisper;
  final VoidCallback? onAttachFile;
  final bool active;
  final bool whisperMode;
  final bool hasActiveCall;

  // Slash-menu delegation. When [slashMenuActive] is true, arrow-up/down,
  // enter, and escape are intercepted and routed to the parent's menu
  // handlers instead of the normal send-on-enter path.
  final bool slashMenuActive;
  final void Function(int delta)? onSlashArrow;
  final VoidCallback? onSlashSelect;
  final VoidCallback? onSlashEscape;

  // Command-history delegation. When the slash menu is NOT open and the
  // user presses ArrowUp / ArrowDown, the parent decides whether to
  // consume the key (history mode) or let it fall through to the text
  // field for normal caret movement. Return `true` to consume.
  final bool Function(int delta)? onHistoryArrow;
  final bool Function()? onHistoryEscape;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onWhisperSend,
    this.onToggleWhisper,
    this.onAttachFile,
    required this.active,
    this.whisperMode = false,
    this.hasActiveCall = false,
    this.slashMenuActive = false,
    this.onSlashArrow,
    this.onSlashSelect,
    this.onSlashEscape,
    this.onHistoryArrow,
    this.onHistoryEscape,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.onKeyEvent = _handleKeyEvent;
    AgentPanel.inputFocusNode = _focusNode;
    AgentPanel.inputController = widget.controller;
  }

  @override
  void dispose() {
    if (AgentPanel.inputFocusNode == _focusNode) {
      AgentPanel.inputFocusNode = null;
    }
    if (AgentPanel.inputController == widget.controller) {
      AgentPanel.inputController = null;
    }
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // When the slash menu is open, intercept navigation keys so the user
    // can pick a command without the keystrokes reaching the TextField or
    // firing the normal send-on-enter path.
    if (widget.slashMenuActive && event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onSlashArrow?.call(1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        widget.onSlashArrow?.call(-1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        widget.onSlashSelect?.call();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onSlashEscape?.call();
        return KeyEventResult.handled;
      }
    }

    // Command-history recall — only consulted when the slash menu isn't
    // capturing keys. The parent decides whether to consume: ArrowUp on
    // a non-empty draft (not yet navigating) falls through to caret
    // movement; ArrowUp on an empty field starts recall.
    if (event is KeyDownEvent && !widget.slashMenuActive) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (widget.onHistoryArrow?.call(-1) == true) {
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (widget.onHistoryArrow?.call(1) == true) {
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (widget.onHistoryEscape?.call() == true) {
          return KeyEventResult.handled;
        }
      }
    }

    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_hasText) widget.onSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  String get _hint {
    if (!widget.active) return 'Agent offline...';
    if (widget.whisperMode) return 'Whisper to agent...';
    return 'Type a message...';
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.whisperMode;
    final accentColor = w ? AppColors.burntAmber : AppColors.accent;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: w ? AppColors.bg : AppColors.surface,
        border: Border(
            top: BorderSide(
          color: w
              ? AppColors.burntAmber.withValues(alpha: 0.3)
              : AppColors.border,
          width: 0.5,
        )),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color:
                    w ? AppColors.card.withValues(alpha: 0.5) : AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _hasText
                      ? accentColor.withValues(alpha: 0.4)
                      : (w
                          ? AppColors.burntAmber.withValues(alpha: 0.2)
                          : AppColors.border),
                  width: 0.5,
                ),
              ),
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontSize: 13,
                  color: w ? AppColors.textSecondary : AppColors.textPrimary,
                  fontStyle: w ? FontStyle.italic : FontStyle.normal,
                ),
                decoration: InputDecoration(
                  hintText: _hint,
                  hintStyle: TextStyle(
                    color: w
                        ? AppColors.burntAmber.withValues(alpha: 0.4)
                        : AppColors.textTertiary,
                    fontSize: 13,
                    fontStyle: w ? FontStyle.italic : FontStyle.normal,
                  ),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          HoverButton(
            onTap: widget.onAttachFile,
            tooltip: 'Attach text file',
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: AppColors.card,
                border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              child: Icon(
                Icons.attach_file_rounded,
                size: 15,
                color: AppColors.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Whisper toggle — only shown during active call
          if (widget.hasActiveCall)
            Padding(
              padding: const EdgeInsets.only(bottom: 0),
              child: HoverButton(
                onTap: widget.onToggleWhisper,
                tooltip: widget.onToggleWhisper == null
                    ? 'Whisper locked (split pipeline)'
                    : w
                        ? 'Exit Whisper'
                        : 'Whisper Mode',
                borderRadius: BorderRadius.circular(10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: widget.onToggleWhisper == null
                        ? AppColors.card.withValues(alpha: 0.5)
                        : w
                            ? AppColors.burntAmber.withValues(alpha: 0.15)
                            : AppColors.card,
                    border: Border.all(
                      color: widget.onToggleWhisper == null
                          ? AppColors.border.withValues(alpha: 0.2)
                          : w
                              ? AppColors.burntAmber.withValues(alpha: 0.4)
                              : AppColors.border.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    w
                        ? Icons.voice_over_off_rounded
                        : Icons.record_voice_over_rounded,
                    size: 15,
                    color: widget.onToggleWhisper == null
                        ? AppColors.textTertiary.withValues(alpha: 0.4)
                        : w
                            ? AppColors.burntAmber
                            : AppColors.textTertiary,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 4),
          // Send button — long press for one-shot whisper
          HoverButton(
            onTap: _hasText ? widget.onSend : null,
            onLongPress: (_hasText && widget.hasActiveCall && !w)
                ? widget.onWhisperSend
                : null,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _hasText ? accentColor : AppColors.card,
                border: Border.all(
                  color: _hasText
                      ? accentColor
                      : AppColors.border.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: _hasText ? AppColors.onAccent : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reminder Bubble
// ---------------------------------------------------------------------------

class _ReminderBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String)? onAction;
  const _ReminderBubble({required this.message, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.accent.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.notifications_active_rounded,
                  size: 14,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            if (message.actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: message.actions.map((action) {
                  if (action.value == 'sms_contact') {
                    return _ReminderChip(
                      label: action.label,
                      icon: Icons.sms_rounded,
                      onTap: () => onAction?.call(action.value),
                    );
                  }
                  return _ReminderChip(
                    label: action.label,
                    onTap: () => onAction?.call(action.value),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReminderChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _ReminderChip({required this.label, this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 11, color: AppColors.accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.accent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline Recording Playback Bubble
// ---------------------------------------------------------------------------

class _InlineRecordingBubble extends StatefulWidget {
  final ChatMessage message;
  const _InlineRecordingBubble({required this.message});

  @override
  State<_InlineRecordingBubble> createState() => _InlineRecordingBubbleState();
}

class _InlineRecordingBubbleState extends State<_InlineRecordingBubble> {
  late AudioPlayer _player;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _dragging = false;
  double _dragValue = 0.0;

  String get _filePath => widget.message.metadata?['filePath'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      if (_filePath.isNotEmpty && File(_filePath).existsSync()) {
        await _player.setFilePath(_filePath);
      }
    } catch (e) {
      debugPrint('[InlineRecordingBubble] Failed to load: $e');
    }

    _player.positionStream.listen((pos) {
      if (mounted && !_dragging) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _playing = state.playing);
      if (state.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;
    final sliderValue = _dragging ? _dragValue : progress.clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.mic_rounded,
                  size: 14,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.message.text,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (_playing) {
                      _player.pause();
                    } else {
                      _player.play();
                    }
                  },
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent,
                    ),
                    child: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 16,
                      color: AppColors.crtBlack,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor:
                          AppColors.border.withValues(alpha: 0.3),
                      thumbColor: AppColors.accent,
                      overlayColor: AppColors.accent.withValues(alpha: 0.12),
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      trackShape: const RoundedRectSliderTrackShape(),
                    ),
                    child: Slider(
                      value: sliderValue,
                      onChangeStart: (v) {
                        setState(() {
                          _dragging = true;
                          _dragValue = v;
                        });
                      },
                      onChanged: (v) {
                        setState(() => _dragValue = v);
                      },
                      onChangeEnd: (v) {
                        final target = Duration(
                          milliseconds: (v * _duration.inMilliseconds).round(),
                        );
                        _player.seek(target);
                        setState(() => _dragging = false);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_fmt(_position)} / ${_fmt(_duration)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                    fontFamily: AppColors.timerFontFamily,
                    fontFamilyFallback: AppColors.timerFontFamilyFallback,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Slash-command catalog & overlay
// ---------------------------------------------------------------------------

/// A single slash-command registered in the agent panel menu.
///
/// The menu is the only surface that enumerates commands — actual
/// dispatch still flows through `_AgentPanelState._send` so the command
/// strings here must match the branches there exactly.
class _SlashCommand {
  final String trigger;
  final String label;
  final String description;
  final IconData icon;

  /// Theme-aware accent for the row's leading glyph. A callback (rather
  /// than a `Color`) so the row adapts when the user switches theme.
  final Color Function() colorFn;

  /// `true` → selecting the command inserts `"$trigger "` and keeps focus
  /// in the input for the manager to type the body.
  /// `false` → selecting the command fills the input with `trigger` and
  /// immediately fires send, running through the existing `_expandCommand`
  /// path in `_AgentPanelState._send`.
  final bool takesBody;

  /// Extra triggers that also match (case-insensitive, prefix).
  final List<String> aliases;

  const _SlashCommand({
    required this.trigger,
    required this.label,
    required this.description,
    required this.icon,
    required this.colorFn,
    this.takesBody = false,
    this.aliases = const [],
  });

  bool matches(String filter) {
    if (filter.isEmpty) return true;
    final f = filter.toLowerCase();
    if (trigger.toLowerCase().startsWith(f)) return true;
    for (final a in aliases) {
      if (a.toLowerCase().startsWith(f)) return true;
    }
    return false;
  }
}

final List<_SlashCommand> _kSlashCommands = [
  _SlashCommand(
    trigger: '/note',
    label: 'Note',
    description: 'Private annotation. Never sent to the LLM, never spoken.',
    icon: Icons.sticky_note_2_outlined,
    colorFn: () => AppColors.orange,
    takesBody: true,
  ),
  _SlashCommand(
    trigger: '/whisper',
    label: 'Whisper',
    description:
        'Discreetly guide the agent — nudges behavior without speaking.',
    icon: Icons.hearing_disabled_outlined,
    colorFn: () => AppColors.burntAmber,
    takesBody: true,
    aliases: ['/w'],
  ),
  _SlashCommand(
    trigger: '/search',
    label: 'Search a contact',
    description:
        'Pull up recent calls, messages, and calendar entries for someone.',
    icon: Icons.search_rounded,
    colorFn: () => AppColors.accent,
    takesBody: true,
  ),
  _SlashCommand(
    trigger: '/call',
    label: 'Call someone',
    description: 'Dial a contact name or phone number.',
    icon: Icons.call_rounded,
    colorFn: () => AppColors.green,
    takesBody: true,
  ),
  _SlashCommand(
    trigger: '/recap',
    label: 'Recap',
    description:
        'Brief agent on recent calls, messages, notes, and reminders.',
    icon: Icons.history_rounded,
    colorFn: () => AppColors.accent,
  ),
  _SlashCommand(
    trigger: '/ready',
    label: 'Ready',
    description: 'Tell the agent the remote party is on the line now.',
    icon: Icons.check_circle_outline,
    colorFn: () => AppColors.green,
  ),
  _SlashCommand(
    trigger: '/speakers',
    label: 'Identify speakers',
    description: 'Ask the agent who is on the call right now.',
    icon: Icons.groups_2_outlined,
    colorFn: () => AppColors.accent,
  ),
  _SlashCommand(
    trigger: '/trivia',
    label: 'Trivia',
    description: 'Kick off a trivia game with the caller.',
    icon: Icons.quiz_outlined,
    colorFn: () => AppColors.accent,
  ),
  _SlashCommand(
    trigger: '/score',
    label: 'Score',
    description: 'Ask for the current trivia score.',
    icon: Icons.scoreboard_outlined,
    colorFn: () => AppColors.accent,
  ),
  _SlashCommand(
    trigger: '/stttest',
    label: 'STT accuracy test',
    description: 'Run the nursery-rhyme speech-to-text diagnostic.',
    icon: Icons.record_voice_over_outlined,
    colorFn: () => AppColors.accentLight,
  ),
];

/// Themed dropdown that sits directly above the input bar and shows the
/// list of slash commands matching the current filter. Matches the visual
/// language of the rest of the panel (AppColors tokens, 0.5px borders,
/// HoverButton-style hover tint) so it feels native rather than bolted on.
class _SlashMenu extends StatelessWidget {
  final List<_SlashCommand> commands;
  final int highlightedIndex;
  final void Function(int index) onHover;
  final void Function(int index) onSelect;

  const _SlashMenu({
    required this.commands,
    required this.highlightedIndex,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
              ),
              border: Border(
                bottom: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.6),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.bolt_outlined,
                    size: 12,
                    color: AppColors.textTertiary.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                Text(
                  'Skills',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${commands.length}',
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary.withValues(alpha: 0.7),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: commands.length,
              itemBuilder: (context, i) {
                return _SlashMenuRow(
                  command: commands[i],
                  highlighted: i == highlightedIndex,
                  onHover: () => onHover(i),
                  onTap: () => onSelect(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SlashMenuRow extends StatelessWidget {
  final _SlashCommand command;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _SlashMenuRow({
    required this.command,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rowColor = command.colorFn();
    final bg = highlighted
        ? AppColors.accent.withValues(alpha: 0.10)
        : Colors.transparent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: rowColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: rowColor.withValues(alpha: 0.28),
                    width: 0.5,
                  ),
                ),
                child: Icon(command.icon, size: 13, color: rowColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: command.trigger,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          TextSpan(
                            text: '  ${command.label}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textTertiary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      command.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textTertiary.withValues(alpha: 0.9),
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (highlighted) ...[
                const SizedBox(width: 8),
                Icon(Icons.subdirectory_arrow_left_rounded,
                    size: 13,
                    color:
                        AppColors.textTertiary.withValues(alpha: 0.65)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _formatTime(DateTime dt) {
  final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
  final m = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$h:$m $ampm';
}
