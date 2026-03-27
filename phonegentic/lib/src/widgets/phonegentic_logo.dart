import 'package:flutter/material.dart';
import '../theme_provider.dart';

class PhonegenticLogo extends StatelessWidget {
  static const _defaultColors = [
    AppColors.hotSignal,
    AppColors.phosphor,
    AppColors.burntAmber,
  ];

  final double size;
  final List<Color>? colors;

  const PhonegenticLogo({Key? key, this.size = 32, this.colors})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SparklePainter(colors: colors ?? _defaultColors),
      ),
    );
  }
}

/// Draws a dual-sparkle AI icon (one large + one small 4-pointed star)
/// filled with the CRT amber gradient. Mirrors the Material `auto_awesome`
/// silhouette but rendered as a gradient-masked vector.
class _SparklePainter extends CustomPainter {
  final List<Color> colors;

  _SparklePainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;

    final main = _sparkle(s * 0.38, s * 0.52, s * 0.34, s * 0.46, s * 0.06);
    final small = _sparkle(s * 0.78, s * 0.20, s * 0.16, s * 0.18, s * 0.03);
    final combined = Path()
      ..addPath(main, Offset.zero)
      ..addPath(small, Offset.zero);

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: colors,
      ).createShader(Rect.fromLTWH(0, 0, s, s));

    canvas.drawPath(combined, paint);
  }

  Path _sparkle(double cx, double cy, double rx, double ry, double p) {
    return Path()
      ..moveTo(cx, cy - ry)
      ..quadraticBezierTo(cx + p, cy - p, cx + rx, cy)
      ..quadraticBezierTo(cx + p, cy + p, cx, cy + ry)
      ..quadraticBezierTo(cx - p, cy + p, cx - rx, cy)
      ..quadraticBezierTo(cx - p, cy - p, cx, cy - ry)
      ..close();
  }

  @override
  bool shouldRepaint(covariant _SparklePainter old) => old.colors != colors;
}
