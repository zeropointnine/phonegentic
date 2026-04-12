import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme_provider.dart';

/// Animated waveform visualiser driven by real-time audio levels.
///
/// Works in two modes:
/// * **live** (`liveMode: true`) – bars are primarily driven by [micLevels]
///   with a gentle sine overlay.
/// * **idle** (`liveMode: false`) – decorative sine-wave animation whose
///   intensity is controlled by [amplitude].
class WaveformBars extends StatefulWidget {
  const WaveformBars({
    super.key,
    required this.micLevels,
    this.barCount = 45,
    this.height = 48,
    this.primaryColor,
    this.secondaryColor,
    this.amplitude = 0.45,
    this.liveMode = true,
  });

  final List<double> micLevels;
  final int barCount;
  final double height;
  final Color? primaryColor;
  final Color? secondaryColor;
  final double amplitude;
  final bool liveMode;

  @override
  State<WaveformBars> createState() => _WaveformBarsState();
}

class _WaveformBarsState extends State<WaveformBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phaseCtrl;

  @override
  void initState() {
    super.initState();
    _phaseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _phaseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.primaryColor ?? AppColors.accent;
    final secondary = widget.secondaryColor ?? AppColors.accentLight;

    return AnimatedBuilder(
      animation: _phaseCtrl,
      builder: (BuildContext context, Widget? child) {
        return CustomPaint(
          size: Size(double.infinity, widget.height),
          painter: _WaveformBarsPainter(
            phase: _phaseCtrl.value,
            amplitude: widget.amplitude,
            primaryColor: primary,
            secondaryColor: secondary,
            barCount: widget.barCount,
            micLevels: widget.micLevels,
            liveMode: widget.liveMode,
          ),
        );
      },
    );
  }
}

class _WaveformBarsPainter extends CustomPainter {
  _WaveformBarsPainter({
    required this.phase,
    required this.amplitude,
    required this.primaryColor,
    required this.secondaryColor,
    required this.barCount,
    required this.micLevels,
    this.liveMode = false,
  });

  final double phase;
  final double amplitude;
  final Color primaryColor;
  final Color secondaryColor;
  final int barCount;
  final List<double> micLevels;
  final bool liveMode;

  @override
  void paint(Canvas canvas, Size size) {
    const double gapRatio = 0.4;
    final double barWidth =
        size.width / (barCount + (barCount - 1) * gapRatio);
    final double gap = barWidth * gapRatio;
    final double maxHeight = size.height;
    final double centerY = size.height / 2;

    for (int i = 0; i < barCount; i++) {
      final double x = i * (barWidth + gap);
      final double t = i / (barCount - 1);

      final double w1 =
          math.sin(t * math.pi * 3.0 + phase * math.pi * 2.0);
      final double w2 =
          math.sin(t * math.pi * 5.5 + phase * math.pi * 2.0 * 1.3) * 0.6;
      final double w3 =
          math.sin(t * math.pi * 8.0 + phase * math.pi * 2.0 * 0.7) * 0.3;
      final double combined = (w1 + w2 + w3) / 1.9;
      final double sineNorm = (combined + 1.0) / 2.0;

      const double minRatio = 0.06;
      double ratio;

      if (liveMode && i < micLevels.length) {
        final double mic = micLevels[i].clamp(0.0, 1.0);
        ratio = minRatio + mic * 0.80 + sineNorm * amplitude * 0.20;
      } else {
        ratio = minRatio + sineNorm * amplitude * (1.0 - minRatio);
      }

      final double barHeight = ratio.clamp(minRatio, 1.0) * maxHeight;
      final double top = centerY - barHeight / 2;

      final Color barColor =
          Color.lerp(primaryColor, secondaryColor, t) ?? primaryColor;
      final double barAlpha =
          liveMode ? (0.45 + ratio * 0.55) : (0.5 + sineNorm * 0.5);

      final Paint barPaint = Paint()
        ..color = barColor.withValues(alpha: barAlpha)
        ..style = PaintingStyle.fill;

      final RRect rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rr, barPaint);

      final double effectiveAmp = liveMode
          ? (i < micLevels.length ? micLevels[i] : 0.0)
          : amplitude;
      if (effectiveAmp > 0.25) {
        final Paint glow = Paint()
          ..color = barColor.withValues(alpha: 0.15 * effectiveAmp)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        canvas.drawRRect(rr, glow);
      }
    }
  }

  @override
  bool shouldRepaint(_WaveformBarsPainter old) => true;
}
