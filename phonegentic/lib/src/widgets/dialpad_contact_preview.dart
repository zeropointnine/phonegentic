import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../demo_mode_service.dart';
import '../theme_provider.dart';

/// A compact contact card that fades in above the dialpad when the typed
/// digits match a stored contact.  Shows a photo if available, otherwise
/// renders a deterministic "identicon" grid derived from the contact name.
class DialpadContactPreview extends StatelessWidget {
  final Map<String, dynamic> contact;

  const DialpadContactPreview({super.key, required this.contact});

  String get _rawName => contact['display_name'] as String? ?? 'Unknown';
  String get _company => contact['company'] as String? ?? '';

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final displayName = demo.maskDisplayName(_rawName);

    return Container(
      width: 260,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.18),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.06),
            blurRadius: 24,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ContactIdenticon(seed: _rawName, size: 56),
          const SizedBox(height: 10),
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          if (_company.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              _company,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
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

/// Generates a symmetric 5x5 identicon grid from [seed], styled to look like
/// a miniature QR-code / data-matrix pattern.  The pattern is mirrored
/// horizontally so it always feels "designed".
class _ContactIdenticon extends StatelessWidget {
  final String seed;
  final double size;

  const _ContactIdenticon({required this.seed, required this.size});

  @override
  Widget build(BuildContext context) {
    final hash = _hashSeed(seed);
    const gridSize = 5;
    final cellSize = size / gridSize;

    final filled = List.generate(gridSize, (_) => List.filled(gridSize, false));

    // Fill left half + center column, then mirror.
    int bit = 0;
    for (int row = 0; row < gridSize; row++) {
      for (int col = 0; col <= gridSize ~/ 2; col++) {
        filled[row][col] = (hash >> (bit % 32)) & 1 == 1;
        filled[row][gridSize - 1 - col] = filled[row][col];
        bit++;
      }
    }

    // Always fill the center cell for visual balance.
    filled[gridSize ~/ 2][gridSize ~/ 2] = true;

    final accentHue = (hash % 360).toDouble();
    final baseColor = HSLColor.fromAHSL(1, accentHue, 0.55, 0.50).toColor();
    final dimColor = baseColor.withValues(alpha: 0.12);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        color: AppColors.surface,
        border: Border.all(
          color: baseColor.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        size: Size(size, size),
        painter: _IdenticonPainter(
          filled: filled,
          cellSize: cellSize,
          fillColor: baseColor,
          dimColor: dimColor,
          borderRadius: cellSize * 0.25,
        ),
      ),
    );
  }

  static int _hashSeed(String s) {
    int h = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }
}

class _IdenticonPainter extends CustomPainter {
  final List<List<bool>> filled;
  final double cellSize;
  final Color fillColor;
  final Color dimColor;
  final double borderRadius;

  _IdenticonPainter({
    required this.filled,
    required this.cellSize,
    required this.fillColor,
    required this.dimColor,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..color = fillColor;
    final dimPaint = Paint()..color = dimColor;
    final gap = cellSize * 0.12;

    for (int row = 0; row < filled.length; row++) {
      for (int col = 0; col < filled[row].length; col++) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            col * cellSize + gap,
            row * cellSize + gap,
            cellSize - gap * 2,
            cellSize - gap * 2,
          ),
          Radius.circular(borderRadius),
        );
        canvas.drawRRect(rect, filled[row][col] ? fillPaint : dimPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) =>
      old.fillColor != fillColor || old.filled != filled;
}
