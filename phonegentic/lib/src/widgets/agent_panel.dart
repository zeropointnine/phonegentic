import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../agent_service.dart';
import '../models/agent_context.dart';
import '../models/chat_message.dart';
import '../theme_provider.dart';

class AgentPanel extends StatefulWidget {
  final Widget? dragHandle;
  const AgentPanel({Key? key, this.dragHandle}) : super(key: key);

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
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
        if (agent.messages.length != _lastMessageCount) {
          _lastMessageCount = agent.messages.length;
          _scrollToBottom();
        }

        return Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            border: Border(left: BorderSide(color: AppColors.border, width: 0.5)),
          ),
          child: Column(
            children: [
              _AgentHeader(agent: agent, dragHandle: widget.dragHandle),
              if (agent.hasActiveCall) _CallInfoBar(agent: agent),
              Expanded(child: _MessageList(
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
                onToggleWhisper: agent.toggleWhisperMode,
                active: agent.active,
                whisperMode: agent.whisperMode,
                hasActiveCall: agent.hasActiveCall,
              ),
            ],
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
  const _AgentHeader({required this.agent, this.dragHandle});

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
                Text(
                  'Phonegentic AI',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    _StatusDot(color: _statusColor, active: agent.active),
                    const SizedBox(width: 5),
                    Text(
                      _statusLabel,
                      style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _HeaderButton(
            icon: agent.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            color: agent.muted ? AppColors.red : AppColors.textSecondary,
            bgColor: agent.muted ? AppColors.red.withOpacity(0.12) : AppColors.card,
            onTap: agent.active ? agent.toggleMute : null,
            tooltip: agent.muted ? 'Unmute' : 'Mute',
          ),
          const SizedBox(width: 6),
          if (agent.hasActiveCall) ...[
            _HeaderButton(
              icon: agent.whisperMode
                  ? Icons.voice_over_off_rounded
                  : Icons.record_voice_over_rounded,
              color: agent.whisperMode
                  ? AppColors.burntAmber
                  : AppColors.textSecondary,
              bgColor: agent.whisperMode
                  ? AppColors.burntAmber.withOpacity(0.12)
                  : AppColors.card,
              onTap: agent.toggleWhisperMode,
              tooltip: agent.whisperMode ? 'Exit Whisper' : 'Whisper Mode',
            ),
            const SizedBox(width: 6),
          ],
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

  String get _remoteLabel {
    if (agent.remoteDisplayName != null && agent.remoteDisplayName!.isNotEmpty) {
      return agent.remoteDisplayName!;
    }
    return agent.remoteIdentity ?? 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final phase = agent.callPhase;
    final color = _phaseColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.04),
        border: Border(bottom: BorderSide(color: AppColors.border.withOpacity(0.4), width: 0.5)),
      ),
      child: Row(
        children: [
          // Phase indicator dot + icon
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: color.withOpacity(0.12),
            ),
            child: Icon(
              phase.isActive ? Icons.phone_in_talk_rounded : Icons.phone_rounded,
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
                    Icon(_directionIcon, size: 10, color: AppColors.textTertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _remoteLabel,
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
            GestureDetector(
              onTap: agent.confirmPartyConnected,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.green.withOpacity(0.15),
                  border: Border.all(color: AppColors.green.withOpacity(0.3), width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_add_alt_1_rounded, size: 12, color: AppColors.green),
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

class _StatusDot extends StatefulWidget {
  final Color color;
  final bool active;
  const _StatusDot({required this.color, required this.active});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
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
                ? [BoxShadow(color: widget.color.withOpacity(0.5), blurRadius: glow, spreadRadius: 0.5)]
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
    return Container(
      width: 44,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: active
            ? LinearGradient(
                colors: [
                  color.withOpacity(0.15),
                  color.withOpacity(0.08),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: active ? null : AppColors.card,
        border: Border.all(
          color: active ? color.withOpacity(0.3) : AppColors.border.withOpacity(0.5),
          width: 0.5,
        ),
      ),
      child: CustomPaint(
        painter: _MiniWaveformPainter(
          levels: levels,
          color: muted ? color.withOpacity(0.3) : color,
          barCount: 7,
        ),
      ),
    );
  }
}

class _MiniWaveformPainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  final int barCount;

  _MiniWaveformPainter({required this.levels, required this.color, required this.barCount});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.0;

    final spacing = size.width / barCount;
    final maxH = size.height * 0.85;
    final minH = 2.5;
    final cy = size.height / 2;

    for (int i = 0; i < barCount; i++) {
      final idx = levels.length > barCount
          ? levels.length - barCount + i
          : i;
      final level = (idx >= 0 && idx < levels.length) ? levels[idx] : 0.0;
      final h = minH + (maxH - minH) * level;
      final x = spacing * i + spacing / 2;
      canvas.drawLine(Offset(x, cy - h / 2), Offset(x, cy + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniWaveformPainter old) =>
      old.levels != levels || old.color != color;
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
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: bgColor,
            border: Border.all(color: AppColors.border.withOpacity(0.4), width: 0.5),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
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
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final isLast = index == messages.length - 1;
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
    if (message.type == MessageType.callState) {
      return _CallStatePill(text: message.text);
    }
    if (message.type == MessageType.whisper) {
      return _WhisperBubble(message: message);
    }
    switch (message.role) {
      case ChatRole.system:
        return _SystemBubble(text: message.text);
      case ChatRole.user:
        return _UserBubble(message: message);
      case ChatRole.agent:
        return _AgentBubble(
          message: message,
          showActions: showActions,
          onAction: onAction,
        );
      case ChatRole.host:
      case ChatRole.remoteParty:
        return _TranscriptBubble(message: message);
    }
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
            color: AppColors.card.withOpacity(0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary, height: 1.4),
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
          Expanded(child: Divider(color: AppColors.border.withOpacity(0.3), height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_in_talk_rounded, size: 10, color: AppColors.textTertiary.withOpacity(0.7)),
                const SizedBox(width: 5),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textTertiary.withOpacity(0.7),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: AppColors.border.withOpacity(0.3), height: 1)),
        ],
      ),
    );
  }
}

class _AgentBubble extends StatelessWidget {
  final ChatMessage message;
  final bool showActions;
  final ValueChanged<MessageAction> onAction;

  const _AgentBubble({
    required this.message,
    required this.showActions,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: AppColors.bg,
              border: Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
            ),
            child: Icon(Icons.auto_awesome, size: 12, color: AppColors.accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('AI', style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textTertiary,
                    )),
                    const SizedBox(width: 6),
                    Text(_formatTime(message.timestamp), style: TextStyle(
                      fontSize: 10, color: AppColors.textTertiary.withOpacity(0.7),
                    )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(color: AppColors.border.withOpacity(0.5), width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          message.text,
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
                ),
                if (showActions) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: message.actions.map((a) => _ActionChip(
                      label: a.label,
                      onTap: () => onAction(a),
                    )).toList(),
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
                    Text(_formatTime(message.timestamp), style: TextStyle(
                      fontSize: 10, color: AppColors.textTertiary.withOpacity(0.7),
                    )),
                    const SizedBox(width: 6),
                    Text('You', style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textTertiary,
                    )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.12),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(color: AppColors.accent.withOpacity(0.2), width: 0.5),
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
                    Text(_formatTime(message.timestamp), style: TextStyle(
                      fontSize: 10, color: AppColors.textTertiary.withOpacity(0.5),
                    )),
                    const SizedBox(width: 6),
                    Icon(Icons.hearing_disabled, size: 10, color: AppColors.burntAmber.withOpacity(0.6)),
                    const SizedBox(width: 3),
                    Text('W', style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: AppColors.burntAmber.withOpacity(0.6),
                    )),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.bg.withOpacity(0.6),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                    border: Border.all(
                      color: AppColors.burntAmber.withOpacity(0.15), width: 0.5),
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
            margin: const EdgeInsets.only(top: 3),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _pillColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              message.speakerName ?? (message.role == ChatRole.host ? 'Host' : 'RP1'),
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: _pillColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary.withOpacity(0.85),
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _formatTime(message.timestamp),
            style: TextStyle(fontSize: 9, color: AppColors.textTertiary.withOpacity(0.6)),
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
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: AppColors.card,
          border: Border.all(color: AppColors.border.withOpacity(0.6), width: 0.5),
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
  final VoidCallback onToggleWhisper;
  final bool active;
  final bool whisperMode;
  final bool hasActiveCall;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onWhisperSend,
    required this.onToggleWhisper,
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
  }

  @override
  void dispose() {
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
        border: Border(top: BorderSide(
          color: w ? AppColors.burntAmber.withOpacity(0.3) : AppColors.border,
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
                color: w ? AppColors.card.withOpacity(0.5) : AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _hasText
                      ? accentColor.withOpacity(0.4)
                      : (w ? AppColors.burntAmber.withOpacity(0.2) : AppColors.border),
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
                    color: w ? AppColors.burntAmber.withOpacity(0.4) : AppColors.textTertiary,
                    fontSize: 13,
                    fontStyle: w ? FontStyle.italic : FontStyle.normal,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Whisper toggle — only shown during active call
          if (widget.hasActiveCall)
            Padding(
              padding: const EdgeInsets.only(bottom: 0),
              child: GestureDetector(
                onTap: widget.onToggleWhisper,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: w
                        ? AppColors.burntAmber.withOpacity(0.15)
                        : AppColors.card,
                    border: Border.all(
                      color: w
                          ? AppColors.burntAmber.withOpacity(0.4)
                          : AppColors.border.withOpacity(0.5),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    w
                        ? Icons.voice_over_off_rounded
                        : Icons.record_voice_over_rounded,
                    size: 15,
                    color: w
                        ? AppColors.burntAmber
                        : AppColors.textTertiary,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 4),
          // Send button — long press for one-shot whisper
          GestureDetector(
            onTap: _hasText ? widget.onSend : null,
            onLongPress: (_hasText && widget.hasActiveCall && !w)
                ? widget.onWhisperSend
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _hasText ? accentColor : AppColors.card,
                border: Border.all(
                  color: _hasText ? accentColor : AppColors.border.withOpacity(0.5),
                  width: 0.5,
                ),
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: _hasText ? Colors.white : AppColors.textTertiary,
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
