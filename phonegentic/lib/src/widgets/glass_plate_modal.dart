import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme_provider.dart';

/// Reusable circular glass-plate modal overlay.
///
/// Renders [child] inside a frosted-glass circle, with a 40 % scrim
/// revealing content underneath. Appears/disappears with a smooth fade.
class GlassPlateModal extends StatelessWidget {
  const GlassPlateModal({
    super.key,
    required this.child,
    this.diameter,
    this.alignment = Alignment.center,
    this.onScrimTap,
    this.onClose,
  });

  final Widget child;

  /// Fixed diameter. When `null` the modal picks a responsive size.
  final double? diameter;

  /// Where to place the glass plate within the overlay.
  final Alignment alignment;

  /// Called when the user taps the scrim outside the glass plate.
  final VoidCallback? onScrimTap;

  /// When non-null a floating close button is rendered on the plate edge.
  final VoidCallback? onClose;

  // ---------------------------------------------------------------------------
  // Convenience: show as a dialog with fade transition
  // ---------------------------------------------------------------------------

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double? diameter,
    Alignment alignment = Alignment.center,
    bool barrierDismissible = true,
    VoidCallback? onClose,
    Duration transitionDuration = const Duration(milliseconds: 300),
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: transitionDuration,
      pageBuilder: (
        BuildContext dialogCtx,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) {
        void dismiss() => Navigator.of(dialogCtx).pop();
        return GlassPlateModal(
          diameter: diameter,
          alignment: alignment,
          onScrimTap: barrierDismissible ? dismiss : null,
          onClose: onClose ?? dismiss,
          child: builder(dialogCtx),
        );
      },
      transitionBuilder: (
        BuildContext transitionCtx,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
        Widget page,
      ) {
        return FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
          child: page,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    final double d =
        diameter ?? (screen.shortestSide * 0.82).clamp(360.0, 620.0);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onTap: onScrimTap,
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.40),
              ),
            ),
          ),
          Align(
            alignment: alignment,
            child: _buildPlateWithClose(d),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Glass plate + optional floating close button
  // ---------------------------------------------------------------------------

  Widget _buildPlateWithClose(double d) {
    if (onClose == null) return _buildPlate(d);

    // Place the close button centered on the circle edge at ~45°.
    // cos(45°) ≈ 0.707, so offset from corner = r * (1 - 0.707) = d * 0.146
    const double btnSize = 34;
    final double edgeOffset = d * 0.146 - btnSize / 2;

    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          _buildPlate(d),
          Positioned(
            top: edgeOffset,
            right: edgeOffset,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onClose,
                child: Container(
                  width: btnSize,
                  height: btnSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surface.withValues(alpha: 0.90),
                    border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlate(double d) {
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.09),
            blurRadius: 2,
            offset: const Offset(-2, -2),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 4,
            offset: const Offset(2.5, 2.5),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 36,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 64,
            spreadRadius: 8,
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Colors.white.withValues(alpha: 0.14),
              Colors.white.withValues(alpha: 0.05),
              Colors.transparent,
              Colors.black.withValues(alpha: 0.12),
            ],
            stops: const <double>[0.0, 0.25, 0.65, 1.0],
          ),
        ),
        padding: const EdgeInsets.all(1.5),
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface.withValues(alpha: 0.60),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
