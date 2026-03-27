import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../tear_sheet_service.dart';
import '../theme_provider.dart';

class TearSheetStrip extends StatelessWidget {
  const TearSheetStrip({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<TearSheetService>(
      builder: (context, service, _) {
        if (!service.isActive) return const SizedBox.shrink();
        return _TearSheetStripContent(service: service);
      },
    );
  }
}

class _TearSheetStripContent extends StatelessWidget {
  final TearSheetService service;
  const _TearSheetStripContent({required this.service});

  @override
  Widget build(BuildContext context) {
    final items = service.items;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Torn paper edge
        CustomPaint(
          painter: _TornEdgePainter(color: AppColors.surface),
          size: const Size(double.infinity, 6),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(
              bottom: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row
              Row(
                children: [
                  Icon(Icons.receipt_long_rounded,
                      size: 16, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Tear Sheet',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${service.doneCount}/${items.length}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Play / Pause button
                  _PillButton(
                    icon: service.isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    label: service.isPaused ? 'Play' : 'Pause',
                    color: service.isPaused
                        ? AppColors.green
                        : AppColors.burntAmber,
                    onTap: service.isPaused
                        ? service.play
                        : service.pause,
                  ),
                  const SizedBox(width: 6),
                  // Skip button
                  _PillButton(
                    icon: Icons.skip_next_rounded,
                    label: 'Skip',
                    color: AppColors.textTertiary,
                    onTap: service.skip,
                  ),
                  const SizedBox(width: 6),
                  // Close / dismiss
                  GestureDetector(
                    onTap: service.dismissSheet,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        color: AppColors.card,
                        border: Border.all(
                          color: AppColors.border.withOpacity(0.5),
                          width: 0.5,
                        ),
                      ),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: AppColors.textTertiary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Queue items preview
              SizedBox(
                height: 32,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isCurrent = index == service.currentIndex;
                    return _QueueChip(
                      item: item,
                      isCurrent: isCurrent,
                      onSkip: () async {
                        if (item['status'] == 'pending') {
                          await service.removeItem(item['id'] as int);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _PillButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: color.withOpacity(0.12),
          border: Border.all(color: color.withOpacity(0.3), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueChip extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isCurrent;
  final VoidCallback onSkip;

  const _QueueChip({
    required this.item,
    required this.isCurrent,
    required this.onSkip,
  });

  String get _label {
    final name = item['contact_name'] as String? ?? '';
    if (name.isNotEmpty) return name;
    return item['phone_number'] as String? ?? '?';
  }

  Color get _statusColor {
    switch (item['status']) {
      case 'done':
        return AppColors.green;
      case 'calling':
        return AppColors.accent;
      case 'flagged':
        return AppColors.red;
      case 'skipped':
        return AppColors.textTertiary;
      default:
        return AppColors.textTertiary;
    }
  }

  IconData? get _statusIcon {
    switch (item['status']) {
      case 'done':
        return Icons.check_rounded;
      case 'calling':
        return Icons.phone_in_talk_rounded;
      case 'flagged':
        return Icons.flag_rounded;
      case 'skipped':
        return Icons.skip_next_rounded;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDone = item['status'] == 'done' ||
        item['status'] == 'skipped';

    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isCurrent
            ? AppColors.accent.withOpacity(0.15)
            : (isDone ? AppColors.bg.withOpacity(0.5) : AppColors.card),
        border: Border.all(
          color: isCurrent
              ? AppColors.accent.withOpacity(0.4)
              : AppColors.border.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_statusIcon != null) ...[
            Icon(_statusIcon, size: 12, color: _statusColor),
            const SizedBox(width: 4),
          ],
          Text(
            _label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              color: isDone
                  ? AppColors.textTertiary.withOpacity(0.5)
                  : AppColors.textPrimary,
              decoration: isDone ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for a torn/jagged paper edge at the top of the strip.
class _TornEdgePainter extends CustomPainter {
  final Color color;
  _TornEdgePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    path.moveTo(0, size.height);

    const teethWidth = 8.0;
    final count = (size.width / teethWidth).ceil();
    for (int i = 0; i < count; i++) {
      final x = i * teethWidth;
      final peakY = (i % 2 == 0) ? 0.0 : size.height * 0.6;
      path.lineTo(x + teethWidth / 2, peakY);
      path.lineTo(x + teethWidth, size.height);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TornEdgePainter old) => old.color != color;
}
