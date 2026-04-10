import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../agent_service.dart';
import '../theme_provider.dart';

class VoiceAgentOverlay extends StatelessWidget {
  const VoiceAgentOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (context, agent, _) {
        return _VoiceAgentIndicator(agent: agent);
      },
    );
  }
}

class _VoiceAgentIndicator extends StatelessWidget {
  final AgentService agent;

  const _VoiceAgentIndicator({required this.agent});

  Color get _statusColor {
    if (!agent.active) return Colors.grey;
    if (agent.speaking) return AppColors.green;
    return AppColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _statusColor,
              boxShadow: [
                BoxShadow(
                  color: _statusColor.withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Waveform
          SizedBox(
            width: 56,
            height: 24,
            child: CustomPaint(
              painter: _WaveformPainter(
                levels: agent.levels,
                barCount: AgentService.waveformBars,
                color: agent.speaking
                    ? AppColors.green
                    : (agent.active ? AppColors.accent : AppColors.textTertiary),
                muted: agent.muted,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Mute button
          HoverButton(
            onTap: agent.active ? agent.toggleMute : null,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: agent.muted
                    ? AppColors.red.withValues(alpha: 0.15)
                    : AppColors.card,
              ),
              child: Icon(
                agent.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                size: 14,
                color: agent.muted ? AppColors.red : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> levels;
  final int barCount;
  final Color color;
  final bool muted;

  _WaveformPainter({
    required this.levels,
    required this.barCount,
    required this.color,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = muted ? color.withValues(alpha: 0.3) : color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.5;

    final barSpacing = size.width / barCount;
    final maxHeight = size.height * 0.9;
    final minHeight = 3.0;
    final centerY = size.height / 2;

    for (int i = 0; i < barCount; i++) {
      final level = i < levels.length ? levels[i] : 0.0;
      final barHeight = minHeight + (maxHeight - minHeight) * level;
      final x = barSpacing * i + barSpacing / 2;
      final halfBar = barHeight / 2;

      canvas.drawLine(
        Offset(x, centerY - halfBar),
        Offset(x, centerY + halfBar),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.color != color ||
        oldDelegate.muted != muted;
  }
}
