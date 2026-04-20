import 'dart:io';

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

  static bool _looksLikePhone(String s) {
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    return digits.length >= 7 && RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(s);
  }

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoModeService>();
    final displayName = demo.maskDisplayName(_rawName);
    final nameIsPhone = _looksLikePhone(_rawName);

    final hasText = !nameIsPhone || _company.isNotEmpty;

    final thumb = contact['thumbnail_path'] as String?;

    if (!hasText) {
      return ContactIdenticon(seed: _rawName, size: 48, thumbnailPath: thumb);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ContactIdenticon(seed: _rawName, size: 44, thumbnailPath: thumb),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!nameIsPhone)
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
              if (_company.isNotEmpty) ...[
                if (!nameIsPhone) const SizedBox(height: 2),
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
        ),
      ],
    );
  }
}

/// Circular contact avatar. Shows the real photo when [thumbnailPath] points
/// to a file on disk; falls back to a deterministic identicon grid derived
/// from [seed].
class ContactIdenticon extends StatelessWidget {
  final String seed;
  final double size;
  final String? thumbnailPath;

  const ContactIdenticon({
    super.key,
    required this.seed,
    required this.size,
    this.thumbnailPath,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;

    if (thumbnailPath != null && thumbnailPath!.isNotEmpty) {
      final file = File(thumbnailPath!);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: accent.withValues(alpha: 0.2),
            width: 0.5,
          ),
          image: DecorationImage(
            image: FileImage(file),
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    final hash = _hashSeed(seed);
    const gridSize = 7;
    final cellSize = size / gridSize;

    final filled =
        List.generate(gridSize, (_) => List.filled(gridSize, false));

    int bit = 0;
    for (int row = 0; row < gridSize; row++) {
      for (int col = 0; col <= gridSize ~/ 2; col++) {
        filled[row][col] = (hash >> (bit % 32)) & 1 == 1;
        filled[row][gridSize - 1 - col] = filled[row][col];
        bit++;
      }
    }
    filled[gridSize ~/ 2][gridSize ~/ 2] = true;

    final fillColor = accent.withValues(alpha: 0.7);
    final dimColor = accent.withValues(alpha: 0.08);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surface,
        border: Border.all(
          color: accent.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        size: Size(size, size),
        painter: _IdenticonPainter(
          filled: filled,
          cellSize: cellSize,
          fillColor: fillColor,
          dimColor: dimColor,
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

  _IdenticonPainter({
    required this.filled,
    required this.cellSize,
    required this.fillColor,
    required this.dimColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..color = fillColor;
    final dimPaint = Paint()..color = dimColor;
    final gap = cellSize * 0.1;

    for (int row = 0; row < filled.length; row++) {
      for (int col = 0; col < filled[row].length; col++) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            col * cellSize + gap,
            row * cellSize + gap,
            cellSize - gap * 2,
            cellSize - gap * 2,
          ),
          Radius.circular(cellSize * 0.2),
        );
        canvas.drawRRect(rect, filled[row][col] ? fillPaint : dimPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) =>
      old.fillColor != fillColor || old.filled != filled;
}
