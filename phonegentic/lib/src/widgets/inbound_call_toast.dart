import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../inbound_call_router.dart';
import '../phone_formatter.dart';
import '../theme_provider.dart';

/// Top-of-screen overlay that appears when a second inbound call arrives
/// while the user is already on a call (or when a caller that hung up while
/// on hold is ready for a callback prompt).
///
/// Two visual variants share a common shell so placement and entry animation
/// match.
class InboundCallToast extends StatelessWidget {
  const InboundCallToast({super.key});

  @override
  Widget build(BuildContext context) {
    final router = context.watch<InboundCallRouter>();
    final pending = router.pendingInbound;
    final cb = router.activeCallbackPrompt;

    final showPending = pending != null;
    final showCallback = !showPending && cb != null;
    final visible = showPending || showCallback;

    // Drop the toast ~8% down from the top of the screen so it sits below
    // the window chrome / status bar rather than hugging the very top edge.
    final screenHeight = MediaQuery.of(context).size.height;
    final topOffset = screenHeight * 0.08;

    return IgnorePointer(
      ignoring: !visible,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, -1.2),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, topOffset, 16, 0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: showPending
                      ? _PendingInboundCard(router: router)
                      : showCallback
                          ? _CallbackPromptCard(
                              router: router,
                              record: cb,
                            )
                          : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pending inbound (ringing) card
// ─────────────────────────────────────────────────────────────────────────────

class _PendingInboundCard extends StatelessWidget {
  final InboundCallRouter router;
  const _PendingInboundCard({required this.router});

  @override
  Widget build(BuildContext context) {
    final call = router.pendingInbound!;
    final displayName = (call.remote_display_name ?? '').trim();
    final number = (call.remote_identity ?? '').trim();
    final title = displayName.isNotEmpty
        ? displayName
        : (number.isNotEmpty ? PhoneFormatter.format(number) : 'Unknown');
    final subtitle = displayName.isNotEmpty && number.isNotEmpty
        ? PhoneFormatter.format(number)
        : 'Incoming call';

    return _ToastShell(
      leading: const _PulsingPhoneIcon(),
      title: title,
      subtitle: subtitle,
      dismissTooltip: 'Decline',
      onDismiss: router.decline,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToastIconButton(
            icon: Icons.call_rounded,
            tooltip: 'Answer',
            background: AppColors.green,
            foreground: Colors.white,
            onTap: router.answerDefault,
          ),
          const SizedBox(width: 6),
          _ToastIconButton(
            icon: Icons.pause_rounded,
            tooltip: 'Hold current & answer',
            background: AppColors.accent,
            foreground: AppColors.onAccent,
            onTap: router.holdCurrentAndAnswer,
          ),
          const SizedBox(width: 6),
          _ToastIconButton(
            icon: Icons.call_end_rounded,
            tooltip: 'Hang up current & answer',
            background: AppColors.red,
            foreground: Colors.white,
            onTap: router.hangupCurrentAndAnswer,
          ),
        ],
      ),
    );
  }
}

class _PulsingPhoneIcon extends StatefulWidget {
  const _PulsingPhoneIcon();

  @override
  State<_PulsingPhoneIcon> createState() => _PulsingPhoneIconState();
}

class _PulsingPhoneIconState extends State<_PulsingPhoneIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent.withValues(alpha: 0.12 + 0.12 * t),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.35 + 0.35 * t),
              width: 1.0,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.phone_in_talk_rounded,
            size: 18,
            color: AppColors.accent,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Callback prompt card
// ─────────────────────────────────────────────────────────────────────────────

class _CallbackPromptCard extends StatelessWidget {
  final InboundCallRouter router;
  final HeldHangupRecord record;
  const _CallbackPromptCard({required this.router, required this.record});

  @override
  Widget build(BuildContext context) {
    final title = (record.displayName?.trim().isNotEmpty ?? false)
        ? record.displayName!.trim()
        : PhoneFormatter.format(record.number);

    return _ToastShell(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.burntAmber.withValues(alpha: 0.12),
          border: Border.all(
            color: AppColors.burntAmber.withValues(alpha: 0.35),
            width: 1.0,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.phone_missed_rounded,
          size: 18,
          color: AppColors.burntAmber,
        ),
      ),
      title: title,
      subtitle: 'Hung up while on hold',
      dismissTooltip: 'Dismiss',
      onDismiss: router.callbackPromptDismiss,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToastIconButton(
            icon: Icons.call_rounded,
            tooltip: 'Call back',
            background: AppColors.green,
            foreground: Colors.white,
            onTap: router.callbackPromptDial,
          ),
          const SizedBox(width: 6),
          _ToastIconButton(
            icon: Icons.sms_outlined,
            tooltip: 'Send SMS',
            background: AppColors.accent,
            foreground: AppColors.onAccent,
            onTap: router.callbackPromptSms,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared shell + small button
// ─────────────────────────────────────────────────────────────────────────────

class _ToastShell extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onDismiss;
  final String dismissTooltip;

  const _ToastShell({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onDismiss,
    required this.dismissTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.border.withValues(alpha: 0.6),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
            const SizedBox(width: 4),
            if (onDismiss != null)
              HoverButton(
                onTap: onDismiss,
                tooltip: dismissTooltip,
                borderRadius: BorderRadius.circular(7),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: AppColors.card,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToastIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  const _ToastIconButton({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onTap: onTap,
      tooltip: tooltip,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: background,
          boxShadow: [
            BoxShadow(
              color: background.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: foreground),
      ),
    );
  }
}
