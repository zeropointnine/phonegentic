import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../agent_config_service.dart';
import '../agent_service.dart';
import '../calendar_sync_service.dart';
import '../manager_presence_service.dart';
import '../db/call_history_db.dart';
import '../conference/conference_service.dart';
import '../demo_mode_service.dart';
import '../inbound_call_flow_service.dart';
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

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
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

class _UpcomingReminderBannerState extends State<_UpcomingReminderBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presence = context.watch<ManagerPresenceService>();
    final reminders = presence.upcomingReminders;
    if (reminders.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    final nearest = reminders.first;
    final title = nearest['title'] as String? ?? 'Reminder';
    final remindAt = DateTime.parse(nearest['remind_at'] as String).toLocal();
    final diff = remindAt.difference(now);

    if (diff.isNegative) return const SizedBox.shrink();

    final mins = diff.inMinutes;
    final secs = diff.inSeconds % 60;
    final isImminent = mins < 2;

    final timeText = mins >= 60
        ? '${mins ~/ 60}h ${mins % 60}m'
        : mins > 0
            ? '${mins}m ${secs.toString().padLeft(2, '0')}s'
            : '${secs}s';

    final bgColor = isImminent
        ? AppColors.accent.withValues(alpha: 0.08)
        : AppColors.surface;
    final highlightColor =
        isImminent ? AppColors.accent : AppColors.textTertiary;

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
          Icon(Icons.notifications_active_rounded,
              size: 12, color: highlightColor),
          const SizedBox(width: 8),
          Text(
            'In $timeText',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: AppColors.timerFontFamily,
              fontFamilyFallback: AppColors.timerFontFamilyFallback,
              color: highlightColor,
            ),
          ),
          const SizedBox(width: 6),
          Text('–',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (reminders.length > 1) ...[
            const SizedBox(width: 6),
            Text(
              '+${reminders.length - 1} more',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ],
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

    // Fallback to original single-call bar when no conference service legs
    if (conf.legCount <= 1 && !conf.hasConference) {
      return _CallInfoBar(agent: agent);
    }

    final legs = conf.legs;
    final hasConference = conf.hasConference;

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

  const _CallLegRow({
    required this.leg,
    required this.isFocused,
    this.inMergedConference = false,
    required this.demo,
    required this.onTap,
    required this.onHold,
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
          color: isFocused
              ? AppColors.accent.withValues(alpha: 0.10)
              : Colors.transparent,
          border: isFocused && !inMergedConference
              ? Border(left: BorderSide(color: AppColors.accent, width: 2))
              : null,
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

class _WhisperBubble extends StatelessWidget {
  final ChatMessage message;
  const _WhisperBubble({required this.message});

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
                          color: AppColors.textTertiary.withValues(alpha: 0.5),
                        )),
                    const SizedBox(width: 6),
                    Icon(Icons.hearing_disabled,
                        size: 10,
                        color: AppColors.burntAmber.withValues(alpha: 0.6)),
                    const SizedBox(width: 3),
                    Text('W',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.burntAmber.withValues(alpha: 0.6),
                        )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.bg.withValues(alpha: 0.6),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(
                        color: AppColors.burntAmber.withValues(alpha: 0.15),
                        width: 0.5),
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                      fontStyle: FontStyle.italic,
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
                        Row(
                          children: [
                            Icon(Icons.link_rounded,
                                size: 11,
                                color: noteColor.withValues(alpha: 0.7)),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                attachedName != null && attachedName.isNotEmpty
                                    ? 'Attached to $attachedName'
                                    : 'Attached to this call',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic,
                                  color: noteColor.withValues(alpha: 0.8),
                                ),
                              ),
                            ),
                          ],
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
    final id = candidate['id'] as int;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: HoverButton(
        onTap: () => agent.attachNoteToCall(pending, id, _name),
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

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onWhisperSend,
    this.onToggleWhisper,
    this.onAttachFile,
    required this.active,
    this.whisperMode = false,
    this.hasActiveCall = false,
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
// Helpers
// ---------------------------------------------------------------------------

String _formatTime(DateTime dt) {
  final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
  final m = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$h:$m $ampm';
}
