import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../messaging/models/sms_message.dart';
import '../messaging/reaction_reply_parser.dart';
import '../theme_provider.dart';

/// Action chosen by the user from the overlay's action menu.
enum MessageContextAction {
  reply,
  copy,
  delete,
}

/// Presents an iOS-style context overlay above the source bubble:
/// blurred backdrop, cloned focused bubble, floating reaction bar,
/// and an action menu. Selections are delivered via the callbacks;
/// the overlay never mutates [MessagingService] directly.
class MessageContextOverlay {
  MessageContextOverlay._();

  /// Show the overlay. [sourceKey] must be attached to the actual bubble
  /// container in the list so we can measure and clone its rect.
  ///
  /// [onReaction] fires with the chosen emoji.
  /// [onAction] fires with the chosen menu action.
  static Future<void> show({
    required BuildContext context,
    required GlobalKey sourceKey,
    required SmsMessage message,
    required bool isOutbound,
    required ValueChanged<String> onReaction,
    required ValueChanged<MessageContextAction> onAction,
    GlobalKey? panelKey,
  }) async {
    final ctx = sourceKey.currentContext;
    if (ctx == null) return;
    final renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final rect = Rect.fromLTWH(topLeft.dx, topLeft.dy, size.width, size.height);

    // Measure the host panel so the backdrop blur / scrim can be scoped
    // to it instead of blurring the entire window.
    Rect? panelRect;
    final pctx = panelKey?.currentContext;
    if (pctx != null) {
      final pRo = pctx.findRenderObject();
      if (pRo is RenderBox && pRo.attached) {
        final pTopLeft = pRo.localToGlobal(Offset.zero);
        panelRect =
            Rect.fromLTWH(pTopLeft.dx, pTopLeft.dy, pRo.size.width, pRo.size.height);
      }
    }

    // Snapshot the bubble's visual as a widget we can re-render above the
    // blur. We keep the same widget subtree by wrapping the live bubble in
    // a RepaintBoundary/IgnorePointer clone — simpler: take an `image`
    // snapshot using RenderRepaintBoundary if present; otherwise fall back
    // to rendering `sourceBuilder` directly.
    ui.Image? snapshot;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    try {
      if (renderObject is RenderRepaintBoundary) {
        snapshot = await renderObject.toImage(pixelRatio: pixelRatio);
      }
    } catch (_) {
      snapshot = null;
    }

    if (!context.mounted) return;

    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, animation, __) => _MessageContextOverlayScaffold(
          bubbleRect: rect,
          panelRect: panelRect,
          message: message,
          isOutbound: isOutbound,
          bubbleSnapshot: snapshot,
          snapshotScale: pixelRatio,
          animation: animation,
          onReaction: onReaction,
          onAction: onAction,
        ),
      ),
    );
  }
}

class _MessageContextOverlayScaffold extends StatefulWidget {
  final Rect bubbleRect;
  final Rect? panelRect;
  final SmsMessage message;
  final bool isOutbound;
  final ui.Image? bubbleSnapshot;
  final double snapshotScale;
  final Animation<double> animation;
  final ValueChanged<String> onReaction;
  final ValueChanged<MessageContextAction> onAction;

  const _MessageContextOverlayScaffold({
    required this.bubbleRect,
    required this.panelRect,
    required this.message,
    required this.isOutbound,
    required this.bubbleSnapshot,
    required this.snapshotScale,
    required this.animation,
    required this.onReaction,
    required this.onAction,
  });

  @override
  State<_MessageContextOverlayScaffold> createState() =>
      _MessageContextOverlayScaffoldState();
}

class _MessageContextOverlayScaffoldState
    extends State<_MessageContextOverlayScaffold> {
  // ---- Layout constants (iOS-ish) ----
  static const double _menuWidth = 220;
  static const double _menuHeight = 184; // ~4 rows @ ~44 + padding
  static const double _menuVerticalGap = 10;
  static const double _reactionBarHeight = 52;
  static const double _reactionBarGap = 10;
  static const double _sideMargin = 16;
  static const double _edgeMargin = 12;
  static const List<String> _tapbacks = [
    '❤️',
    '👍',
    '👎',
    '😂',
    '‼️',
    '❓',
  ];

  late final double _scale;
  late final double _opacity;

  @override
  void initState() {
    super.initState();
    _scale = 1.0;
    _opacity = 1.0;
  }

  bool _exiting = false;

  void _dismissWith(VoidCallback action) {
    if (_exiting) return;
    _exiting = true;
    // Fire the action first so the caller's state mutation happens before
    // the route pops (no lost selections on quick taps).
    action();
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final bubble = widget.bubbleRect;

    // --- Compute where the reaction bar + menu land ---
    //
    // Layout priority (iOS-style):
    //   1) Prefer bar above the bubble and menu below the bubble.
    //   2) If the menu won't fit below, flip: menu above the bubble, bar
    //      above the menu.
    //   3) Last-resort fallback: stack both below the bubble (bar first).
    //
    // The three placements never overlap, which was the bug: the previous
    // "bar always above, menu wherever" layout collided when the bubble
    // sat near the bottom of the panel.
    final safeTop = media.padding.top + _edgeMargin;
    final safeBottom = screen.height - media.padding.bottom - _edgeMargin;

    final roomBelow = safeBottom - bubble.bottom - _menuVerticalGap;
    final roomAbove = bubble.top - safeTop - _reactionBarGap;

    double barTop;
    double menuTop;
    if (roomBelow >= _menuHeight) {
      barTop = bubble.top - _reactionBarHeight - _reactionBarGap;
      menuTop = bubble.bottom + _menuVerticalGap;
    } else if (roomAbove >=
        _reactionBarHeight + _reactionBarGap + _menuHeight + _menuVerticalGap) {
      menuTop = bubble.top - _menuVerticalGap - _menuHeight;
      barTop = menuTop - _reactionBarGap - _reactionBarHeight;
    } else {
      barTop = bubble.bottom + _reactionBarGap;
      menuTop = barTop + _reactionBarHeight + _menuVerticalGap;
    }

    barTop = barTop.clamp(safeTop, safeBottom - _reactionBarHeight);
    menuTop = menuTop.clamp(safeTop, safeBottom - _menuHeight);

    // Reaction bar: horizontally aligned to the bubble's aligned edge.
    final barWidth = _tapbacks.length * 44.0 + 20; // emoji + padding
    double barLeft =
        widget.isOutbound ? bubble.right - barWidth : bubble.left;
    barLeft = barLeft.clamp(_sideMargin, screen.width - barWidth - _sideMargin);

    // Menu: on the outbound edge (right for outbound, left for inbound).
    double menuLeft = widget.isOutbound ? bubble.right - _menuWidth : bubble.left;
    menuLeft = menuLeft.clamp(
        _sideMargin, screen.width - _menuWidth - _sideMargin);

    // Scope the backdrop blur + scrim to the host panel when we were given
    // one; otherwise fall back to the full screen. Either way the rect also
    // doubles as the click-barrier area.
    final backdropRect = widget.panelRect ?? Offset.zero & screen;

    final backdrop = FadeTransition(
      opacity: widget.animation,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context, rootNavigator: true).maybePop(),
        child: ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ---- Layer 1: blurred backdrop (also acts as the click barrier)
          Positioned.fromRect(
            rect: backdropRect,
            child: backdrop,
          ),

        // ---- Layer 2: focused bubble clone (scale-in elastic) ----
        Positioned(
          left: bubble.left,
          top: bubble.top,
          width: bubble.width,
          height: bubble.height,
          child: IgnorePointer(
            child: _ElasticScaleIn(
              animation: widget.animation,
              alignment: widget.isOutbound
                  ? Alignment.topRight
                  : Alignment.topLeft,
              scaleTo: _scale,
              child: Opacity(
                opacity: _opacity,
                child: widget.bubbleSnapshot != null
                    ? RawImage(
                        image: widget.bubbleSnapshot,
                        scale: widget.snapshotScale,
                        width: bubble.width,
                        height: bubble.height,
                        fit: BoxFit.fill,
                      )
                    : _FallbackBubble(
                        message: widget.message,
                        isOutbound: widget.isOutbound,
                      ),
              ),
            ),
          ),
        ),

        // ---- Layer 3: reaction bar ----
        Positioned(
          left: barLeft,
          top: barTop,
          child: _ElasticScaleIn(
            animation: widget.animation,
            alignment: widget.isOutbound
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            child: _ReactionBar(
              tapbacks: _tapbacks,
              activeReactions: widget.message.reactions.keys.toSet(),
              onPick: (emoji) =>
                  _dismissWith(() => widget.onReaction(emoji)),
            ),
          ),
        ),

          // ---- Layer 4: action menu ----
          Positioned(
            left: menuLeft,
            top: menuTop,
            width: _menuWidth,
            child: _ElasticScaleIn(
              animation: widget.animation,
              alignment: widget.isOutbound
                  ? Alignment.topRight
                  : Alignment.topLeft,
              child: _ActionMenu(
                onAction: (a) => _dismissWith(() => widget.onAction(a)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Elastic scale-in for entrance, linear 150ms reverse.
class _ElasticScaleIn extends StatelessWidget {
  final Animation<double> animation;
  final Alignment alignment;
  final double scaleTo;
  final Widget child;

  const _ElasticScaleIn({
    required this.animation,
    required this.alignment,
    required this.child,
    this.scaleTo = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.elasticOut.transform(animation.value.clamp(0.0, 1.0));
        // elasticOut can overshoot past 1.0; that's desired for the pop-in.
        final s = 0.6 + (scaleTo - 0.6) * t;
        return Transform.scale(
          alignment: alignment,
          scale: s,
          child: Opacity(
            opacity: animation.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Horizontal pill with the six canonical tapback emojis.
class _ReactionBar extends StatelessWidget {
  final List<String> tapbacks;
  final Set<String> activeReactions;
  final ValueChanged<String> onPick;

  const _ReactionBar({
    required this.tapbacks,
    required this.activeReactions,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    // Fully opaque pill so emoji glyphs render at 100% against the blurred
    // backdrop with no transparency bleed.
    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(horizontal: 4.5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Color.alphaBlend(
            AppColors.border.withValues(alpha: 0.6),
            AppColors.surface,
          ),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: tapbacks
            .map((e) => _TapbackButton(
                  emoji: e,
                  active: activeReactions.contains(e),
                  onTap: () => onPick(e),
                ))
            .toList(),
      ),
    );
  }
}

class _TapbackButton extends StatefulWidget {
  final String emoji;
  final bool active;
  final VoidCallback onTap;

  const _TapbackButton({
    required this.emoji,
    required this.active,
    required this.onTap,
  });

  @override
  State<_TapbackButton> createState() => _TapbackButtonState();
}

class _TapbackButtonState extends State<_TapbackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Use onTapUp so the tap fires BEFORE any ambient dismiss gesture.
        onTapUp: (_) => widget.onTap(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.active
                ? AppColors.accent.withValues(alpha: 0.18)
                : _hovered
                    ? AppColors.accent.withValues(alpha: 0.10)
                    : Colors.transparent,
          ),
          alignment: Alignment.center,
          child: Text(
            widget.emoji,
            style: const TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }
}

/// Vertical menu with Reply / Copy / Delete. "Delete" opens multi-select
/// mode on the source conversation (bubbles reveal their round checkboxes).
class _ActionMenu extends StatelessWidget {
  final ValueChanged<MessageContextAction> onAction;

  const _ActionMenu({required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.border.withValues(alpha: 0.6), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MenuRow(
            icon: Icons.reply_rounded,
            label: 'Reply',
            onTap: () => onAction(MessageContextAction.reply),
          ),
          _MenuDivider(),
          _MenuRow(
            icon: Icons.copy_rounded,
            label: 'Copy',
            onTap: () => onAction(MessageContextAction.copy),
          ),
          _MenuDivider(),
          _MenuRow(
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
            destructive: true,
            onTap: () => onAction(MessageContextAction.delete),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.destructive ? AppColors.red : AppColors.textPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (_) => widget.onTap(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          color: _hovered
              ? AppColors.accent.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(widget.icon, size: 17, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      color: AppColors.border.withValues(alpha: 0.5),
    );
  }
}

/// Rendered only when we couldn't snapshot the source bubble. Gives the
/// user a visually-close clone of their message so the focused layer still
/// reads as "this message".
class _FallbackBubble extends StatelessWidget {
  final SmsMessage message;
  final bool isOutbound;

  const _FallbackBubble({required this.message, required this.isOutbound});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final bubbleColor =
        isOutbound ? accent.withValues(alpha: 0.18) : AppColors.card;
    return Align(
      alignment: isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.textPrimary,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

/// Utility bundle available to callers for Copy.
class MessageContextActions {
  MessageContextActions._();

  static void copy(SmsMessage msg) {
    Clipboard.setData(ClipboardData(text: msg.text));
  }

  /// Exposes the canonical tapback set to any caller that wants to render
  /// the same palette elsewhere.
  static List<String> canonicalTapbacks =
      ReactionReplyParser.canonicalTapbacks.toList(growable: false);
}
