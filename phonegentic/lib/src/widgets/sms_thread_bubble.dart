import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../contact_service.dart';
import '../models/chat_message.dart';
import '../theme_provider.dart';
import 'dialpad_contact_preview.dart';

/// Renders an SMS message inline in the agent panel as a speech-bubble shaped
/// card. Inbound messages anchor left; outbound messages anchor right.
///
/// The outline mimics a chat-bubble icon: rounded rectangle with a small
/// triangular tail at the bottom corner. The shape grows vertically to fit
/// content while keeping corner radii constant.
class SmsThreadBubble extends StatefulWidget {
  final ChatMessage message;
  const SmsThreadBubble({super.key, required this.message});

  @override
  State<SmsThreadBubble> createState() => _SmsThreadBubbleState();
}

class _SmsThreadBubbleState extends State<SmsThreadBubble> {
  bool _expanded = false;

  bool get _isInbound =>
      widget.message.metadata?['sms_direction'] == 'inbound';

  String get _remotePhone =>
      widget.message.metadata?['sms_remote_phone'] as String? ?? '';

  String? get _contactName =>
      widget.message.metadata?['sms_contact_name'] as String?;

  String get _displayName {
    if (_contactName != null && _contactName!.isNotEmpty) return _contactName!;
    final contact =
        context.read<ContactService>().lookupByPhone(_remotePhone);
    if (contact != null) {
      final name = contact['display_name'] as String?;
      if (name != null && name.isNotEmpty) return name;
    }
    return _remotePhone;
  }

  String get _messageText {
    final raw = widget.message.text;
    final colonIdx = raw.indexOf(': "');
    if (colonIdx != -1 && raw.endsWith('"')) {
      return raw.substring(colonIdx + 3, raw.length - 1);
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final isInbound = _isInbound;
    final accent = AppColors.accent;
    final bubbleColor = isInbound
        ? AppColors.surface
        : accent.withValues(alpha: 0.08);
    final borderColor = isInbound
        ? accent.withValues(alpha: 0.25)
        : accent.withValues(alpha: 0.35);
    final tailAlignment =
        isInbound ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final displayName = _displayName;
    final messageText = _messageText;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment:
            isInbound ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isInbound) const SizedBox(width: 36),
          Flexible(
            child: Column(
              crossAxisAlignment: tailAlignment,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: CustomPaint(
                      painter: _SpeechBubblePainter(
                        borderColor: borderColor,
                        fillColor: bubbleColor,
                        tailOnLeft: isInbound,
                        cornerRadius: 14,
                        tailWidth: 8,
                        tailHeight: 6,
                      ),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          isInbound ? 14 : 12,
                          10,
                          isInbound ? 12 : 14,
                          14,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildHeader(
                                displayName, isInbound, accent),
                            const SizedBox(height: 8),
                            _buildBody(messageText, isInbound),
                            if (_expanded) ...[
                              const SizedBox(height: 6),
                              _buildExpandedMeta(),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isInbound) const SizedBox(width: 36),
        ],
      ),
    );
  }

  Widget _buildHeader(String displayName, bool isInbound, Color accent) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ContactIdenticon(seed: _remotePhone, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: 0.2,
                ),
              ),
              if (_contactName != null && _contactName!.isNotEmpty)
                Text(
                  _remotePhone,
                  style: TextStyle(
                    fontSize: 9,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.3,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          isInbound ? Icons.call_received_rounded : Icons.call_made_rounded,
          size: 10,
          color: isInbound
              ? AppColors.green.withValues(alpha: 0.7)
              : accent.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 4),
        Text(
          _formatLocalTime(widget.message.timestamp),
          style: TextStyle(
            fontSize: 9,
            color: AppColors.textTertiary.withValues(alpha: 0.7),
            fontFamily: AppColors.timerFontFamily,
            fontFamilyFallback: AppColors.timerFontFamilyFallback,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(String messageText, bool isInbound) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.border.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.format_quote_rounded,
            size: 12,
            color: AppColors.textTertiary.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              messageText,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedMeta() {
    final direction = _isInbound ? 'Received' : 'Sent';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.sms_outlined,
            size: 10, color: AppColors.textTertiary.withValues(alpha: 0.5)),
        const SizedBox(width: 4),
        Text(
          '$direction · ${_formatFullTime(widget.message.timestamp)}',
          style: TextStyle(
            fontSize: 9,
            color: AppColors.textTertiary.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  static String _formatLocalTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$hour12:$m $ampm';
  }

  static String _formatFullTime(DateTime dt) {
    final local = dt.toLocal();
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}, ${_formatLocalTime(dt)}';
  }
}

// ---------------------------------------------------------------------------
// Speech-bubble outline painter
// ---------------------------------------------------------------------------

/// Draws a rounded-rectangle speech bubble with a small triangular tail.
/// The tail sits at the bottom-left (inbound) or bottom-right (outbound).
/// The body grows vertically; corner radii remain constant.
class _SpeechBubblePainter extends CustomPainter {
  final Color borderColor;
  final Color fillColor;
  final bool tailOnLeft;
  final double cornerRadius;
  final double tailWidth;
  final double tailHeight;

  _SpeechBubblePainter({
    required this.borderColor,
    required this.fillColor,
    required this.tailOnLeft,
    this.cornerRadius = 14,
    this.tailWidth = 8,
    this.tailHeight = 6,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = cornerRadius;
    final bodyH = h - tailHeight;

    final path = Path();

    // Top-left corner
    path.moveTo(r, 0);
    // Top edge
    path.lineTo(w - r, 0);
    // Top-right corner
    path.arcToPoint(Offset(w, r),
        radius: Radius.circular(r), clockwise: true);
    // Right edge
    path.lineTo(w, bodyH - r);
    // Bottom-right corner
    path.arcToPoint(Offset(w - r, bodyH),
        radius: Radius.circular(r), clockwise: true);

    if (tailOnLeft) {
      // Bottom edge to tail
      path.lineTo(r + tailWidth + 4, bodyH);
      // Tail
      path.lineTo(r + 2, bodyH + tailHeight);
      path.lineTo(r + 4, bodyH);
      // Bottom-left corner
      path.lineTo(r, bodyH);
      path.arcToPoint(Offset(0, bodyH - r),
          radius: Radius.circular(r), clockwise: true);
    } else {
      // Bottom edge
      path.lineTo(w - r - 4, bodyH);
      // Tail
      path.lineTo(w - r - 2, bodyH + tailHeight);
      path.lineTo(w - r - tailWidth - 4, bodyH);
      path.lineTo(r, bodyH);
      // Bottom-left corner
      path.arcToPoint(Offset(0, bodyH - r),
          radius: Radius.circular(r), clockwise: true);
    }

    // Left edge
    path.lineTo(0, r);
    // Top-left corner
    path.arcToPoint(Offset(r, 0),
        radius: Radius.circular(r), clockwise: true);
    path.close();

    // Fill
    canvas.drawPath(
        path,
        Paint()
          ..color = fillColor
          ..style = PaintingStyle.fill);

    // Border
    canvas.drawPath(
        path,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0);
  }

  @override
  bool shouldRepaint(_SpeechBubblePainter old) =>
      old.borderColor != borderColor ||
      old.fillColor != fillColor ||
      old.tailOnLeft != tailOnLeft;
}
