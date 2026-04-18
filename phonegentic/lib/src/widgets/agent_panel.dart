import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:intl/intl.dart';

import '../agent_config_service.dart';
import '../agent_service.dart';
import '../calendar_sync_service.dart';
import '../conference/conference_service.dart';
import '../demo_mode_service.dart';
import '../inbound_call_flow_service.dart';
import '../job_function_service.dart';
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

    if (agent.whisperMode) {
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
                      onAction: (action) {
                        _controller.text = action.value;
                        _send(agent);
                      },
                    )),
                    _InputBar(
                      controller: _controller,
                      onSend: () => _send(agent),
                      onWhisperSend: () => _sendWhisperOneShot(agent),
                      onToggleWhisper:
                          agent.canToggleWhisper ? agent.toggleWhisperMode : null,
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
                                  color: AppColors.accent.withValues(alpha: 0.4),
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

class _AgentHeader extends StatelessWidget {
  final AgentService agent;
  final Widget? dragHandle;
  final VoidCallback? onDownloadTranscript;
  const _AgentHeader({
    required this.agent,
    this.dragHandle,
    this.onDownloadTranscript,
  });

  String get _statusLabel {
    if (!agent.active) return agent.statusText;
    if (agent.speaking) return 'Speaking';
    if (agent.muted) return 'Not Listening...';
    return 'Listening';
  }

  Color get _statusColor {
    if (!agent.active) return AppColors.textTertiary;
    if (agent.speaking) return AppColors.green;
    return AppColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final jfService = context.watch<JobFunctionService>();
    final icfService = context.watch<InboundCallFlowService>();

    final selectedName = jfService.selected?.title ?? 'Phonegentic AI';
    final activeFlow = icfService.activeFlowName;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (dragHandle != null) ...[dragHandle!, const SizedBox(width: 8)],
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
            onTap: onDownloadTranscript,
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
          const SizedBox(width: 8),
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
                      ? 'Conference (${legs.length} parties)'
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
          // Leg rows with merge connector
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
            // Merge connector between legs (only when not yet merged)
            if (i < legs.length - 1 && !hasConference)
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
  final DemoModeService demo;
  final VoidCallback onTap;
  final VoidCallback onHold;

  const _CallLegRow({
    required this.leg,
    required this.isFocused,
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
              ? AppColors.accent.withValues(alpha: 0.06)
              : Colors.transparent,
          border: isFocused
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

class _MessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final ScrollController scrollController;
  final ValueChanged<MessageAction> onAction;

  const _MessageList({
    required this.messages,
    required this.scrollController,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet',
          style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msgIdx = messages.length - 1 - index;
        final msg = messages[msgIdx];
        final isLast = msgIdx == messages.length - 1;
        return _MessageBubble(
          message: msg,
          showActions: isLast && msg.actions.isNotEmpty,
          onAction: onAction,
        );
      },
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
    } else if (message.type == MessageType.attachment) {
      child = _AttachmentBubble(message: message);
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
                      color: AppColors.red.withValues(
                          alpha: 0.5 + 0.5 * _pulseCtrl.value),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.red.withValues(
                              alpha: 0.3 * _pulseCtrl.value),
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
// Helpers
// ---------------------------------------------------------------------------

String _formatTime(DateTime dt) {
  final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
  final m = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  return '$h:$m $ampm';
}
