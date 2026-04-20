import 'package:flutter/material.dart';
import '../theme_provider.dart';

class ActionButton extends StatefulWidget {
  final String? title;
  final String subTitle;
  final IconData? icon;
  final Widget? iconWidget;
  final bool checked;
  final bool number;
  final Color? fillColor;
  final TextStyle? titleStyle;
  final Function()? onPressed;
  final Function()? onLongPress;

  const ActionButton({
    super.key,
    this.title,
    this.subTitle = '',
    this.icon,
    this.iconWidget,
    this.onPressed,
    this.onLongPress,
    this.checked = false,
    this.number = false,
    this.fillColor,
    this.titleStyle,
  });

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _pressed = false;
  bool _hovered = false;

  void _onDown(TapDownDetails _) => setState(() => _pressed = true);
  void _onUp(TapUpDetails _) => setState(() => _pressed = false);
  void _onCancel() => setState(() => _pressed = false);

  @override
  Widget build(BuildContext context) {
    if (widget.number) return _buildNumButton(context);
    return _buildIconButton(context);
  }

  Widget _buildNumButton(BuildContext context) {
    final scale = _pressed ? 0.90 : (_hovered ? 1.05 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        onTapDown: _onDown,
        onTapUp: _onUp,
        onTapCancel: _onCancel,
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _pressed
                    ? [AppColors.surface, AppColors.bg]
                    : _hovered
                        ? [
                            AppColors.card,
                            AppColors.surface,
                            AppColors.bg,
                          ]
                        : [AppColors.card, AppColors.surface],
              ),
              border: Border.all(
                color: _hovered
                    ? AppColors.burntAmber.withValues(alpha: 0.45)
                    : AppColors.burntAmber.withValues(alpha: 0.22),
                width: 0.8,
              ),
              boxShadow: [
                if (_hovered && !_pressed)
                  BoxShadow(
                    color: AppColors.phosphor.withValues(alpha: 0.15),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                BoxShadow(
                  color: AppColors.phosphor.withValues(alpha: _pressed ? 0.02 : 0.05),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title ?? '',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                    color: _pressed
                        ? AppColors.burntAmber
                        : AppColors.accent,
                    height: 1.1,
                  ),
                ),
                if (widget.subTitle.isNotEmpty)
                  Text(
                    widget.subTitle.toUpperCase(),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.burntAmber,
                      letterSpacing: 1.5,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconButton(BuildContext context) {
    final bool hasFill = widget.fillColor != null;
    final bgColor = hasFill
        ? widget.fillColor!
        : (widget.checked
            ? AppColors.accent.withValues(alpha: 0.15)
            : AppColors.card);
    final iconColor = hasFill
        ? AppColors.onAccent
        : (widget.checked ? AppColors.accent : AppColors.textSecondary);
    final scale = _pressed ? 0.88 : (_hovered ? 1.06 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: widget.onPressed,
            onLongPress: widget.onLongPress,
            onTapDown: _onDown,
            onTapUp: _onUp,
            onTapCancel: _onCancel,
            child: AnimatedScale(
              scale: scale,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _pressed ? bgColor.withValues(alpha: 0.6) : bgColor,
                  border: hasFill
                      ? null
                      : Border.all(
                          color: widget.checked
                              ? AppColors.accent.withValues(alpha: 0.3)
                              : (_hovered
                                  ? AppColors.border
                                  : AppColors.border.withValues(alpha: 0.5)),
                          width: 0.5,
                        ),
                  boxShadow: widget.checked
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.2),
                            blurRadius: 8,
                          ),
                        ]
                      : (_hovered
                          ? [
                              BoxShadow(
                                color: AppColors.phosphor.withValues(alpha: 0.1),
                                blurRadius: 12,
                              ),
                            ]
                          : null),
                ),
                child: widget.iconWidget ?? Icon(widget.icon, size: 24, color: iconColor),
              ),
            ),
          ),
          if (widget.title != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.title!,
              style: TextStyle(
                fontSize: 11,
                color:
                    hasFill ? widget.fillColor : AppColors.textTertiary,
                fontWeight: FontWeight.w500,
              ).merge(widget.titleStyle),
            ),
          ],
        ],
      ),
    );
  }
}
