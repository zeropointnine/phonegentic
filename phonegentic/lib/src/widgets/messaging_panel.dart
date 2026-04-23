import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../messaging/models/sms_conversation.dart';
import '../theme_provider.dart';
import 'conversation_view.dart';
import 'dialpad_contact_preview.dart';

class MessagingPanel extends StatefulWidget {
  const MessagingPanel({super.key});

  @override
  State<MessagingPanel> createState() => _MessagingPanelState();
}

class _MessagingPanelState extends State<MessagingPanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _showNewMessage = false;
  final TextEditingController _newNumberCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _newNumberCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MessagingService>(
      builder: (context, messaging, _) {
        if (messaging.selectedRemotePhone != null) {
          return const ConversationView();
        }
        return _buildConversationList(messaging);
      },
    );
  }

  Widget _buildConversationList(MessagingService messaging) {
    final filtered = _searchCtrl.text.isEmpty
        ? messaging.conversations
        : messaging.conversations.where((c) {
            final q = _searchCtrl.text.toLowerCase();
            return c.displayName.toLowerCase().contains(q) ||
                c.remotePhone.toLowerCase().contains(q);
          }).toList();

    return Container(
      color: AppColors.bg,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(messaging),
            if (_showNewMessage) _buildNewMessageRow(messaging),
            Expanded(
              child: filtered.isEmpty
                  ? _buildEmptyState(messaging)
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 0.5,
                        indent: 68,
                        color: AppColors.border.withValues(alpha: 0.3),
                      ),
                      itemBuilder: (context, i) =>
                          _buildConversationTile(messaging, filtered[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(MessagingService messaging) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.message_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(
            'Messages',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
              ),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  hintStyle:
                      TextStyle(fontSize: 13, color: AppColors.textTertiary),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 16, color: AppColors.textTertiary),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 32, minHeight: 0),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: () => setState(() => _showNewMessage = !_showNewMessage),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _showNewMessage
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : AppColors.card,
                border: Border.all(
                    color: _showNewMessage
                        ? AppColors.accent.withValues(alpha: 0.3)
                        : AppColors.border.withValues(alpha: 0.5),
                    width: 0.5),
              ),
              child: Icon(Icons.edit_rounded,
                  size: 16,
                  color: _showNewMessage
                      ? AppColors.accent
                      : AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: () => messaging.close(),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.card,
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
              ),
              child: Icon(Icons.close_rounded,
                  size: 16, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewMessageRow(MessagingService messaging) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
              ),
              child: TextField(
                controller: _newNumberCtrl,
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Phone number (e.g. +18005551234)',
                  hintStyle:
                      TextStyle(fontSize: 13, color: AppColors.textTertiary),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          HoverButton(
            onTap: () {
              final num = _newNumberCtrl.text.trim();
              if (num.isEmpty) return;
              messaging.selectConversation(num);
              setState(() {
                _showNewMessage = false;
                _newNumberCtrl.clear();
              });
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text('Open',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onAccent)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(MessagingService messaging) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                size: 48, color: AppColors.textTertiary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              messaging.isConfigured
                  ? 'No conversations yet'
                  : 'Messaging not configured',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textTertiary,
              ),
            ),
            if (!messaging.isConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Set up SMS (Telnyx or Twilio) in Settings',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary.withValues(alpha: 0.6)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(
      MessagingService messaging, SmsConversation convo) {
    final demo = context.read<DemoModeService>();
    final hasUnread = convo.unreadCount > 0;
    final lastMsg = convo.lastMessage;
    final preview = lastMsg?.text ?? '';
    final timeStr = _formatTime(lastMsg?.createdAt);
    final displayName = convo.contactName != null
        ? demo.maskDisplayName(convo.contactName!)
        : demo.maskPhone(convo.remotePhone);

    final tileBody = InkWell(
      onTap: () => messaging.selectConversation(convo.remotePhone),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            ContactIdenticon(
              seed: convo.contactName ?? convo.remotePhone,
              size: 48,
              thumbnailPath: convo.thumbnailPath,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                hasUnread ? FontWeight.w700 : FontWeight.w500,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 11,
                          color: hasUnread
                              ? AppColors.accent
                              : AppColors.textTertiary,
                          fontWeight:
                              hasUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          style: TextStyle(
                            fontSize: 12,
                            color: hasUnread
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                            fontWeight:
                                hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${convo.unreadCount}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.onAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return _SwipeableConversationTile(
      onDelete: () => _confirmDeleteThread(messaging, convo),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            _showThreadContextMenu(messaging, convo, details.globalPosition),
        child: tileBody,
      ),
    );
  }

  Future<void> _showThreadContextMenu(
    MessagingService messaging,
    SmsConversation convo,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<_ThreadMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      color: AppColors.surface,
      items: <PopupMenuEntry<_ThreadMenuAction>>[
        PopupMenuItem<_ThreadMenuAction>(
          value: _ThreadMenuAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 16, color: AppColors.red),
              const SizedBox(width: 10),
              Text(
                'Delete conversation',
                style: TextStyle(fontSize: 13, color: AppColors.red),
              ),
            ],
          ),
        ),
      ],
    );
    if (selected == _ThreadMenuAction.delete) {
      await _confirmDeleteThread(messaging, convo);
    }
  }

  Future<void> _confirmDeleteThread(
    MessagingService messaging,
    SmsConversation convo,
  ) async {
    final name = convo.contactName ?? convo.remotePhone;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Delete conversation?',
          style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
        ),
        content: Text(
          'All messages with $name will be removed from this device. '
          'The other party will still have their copy.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete',
                style: TextStyle(
                  color: AppColors.red,
                  fontWeight: FontWeight.w600,
                )),
          ),
        ],
      ),
    );
    if (ok == true) {
      await messaging.deleteThread(convo.remotePhone);
    }
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.month}/${dt.day}';
  }
}

enum _ThreadMenuAction { delete }

/// Lightweight, dependency-free swipe-to-reveal for the conversation
/// tile. Drags the tile left up to -88px to uncover a red Delete action;
/// snaps back past the threshold. Only actively tracks drags on touch
/// platforms (iOS / Android); desktop relies on right-click context menu.
class _SwipeableConversationTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onDelete;

  const _SwipeableConversationTile({
    required this.child,
    required this.onDelete,
  });

  @override
  State<_SwipeableConversationTile> createState() =>
      _SwipeableConversationTileState();
}

class _SwipeableConversationTileState
    extends State<_SwipeableConversationTile>
    with SingleTickerProviderStateMixin {
  static const double _revealWidth = 88;
  static const double _openSnapThreshold = 44;

  double _dx = 0;
  late AnimationController _ctrl;
  Animation<double>? _anim;

  bool get _touch =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    _anim = Tween<double>(begin: _dx, end: target).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    )..addListener(() {
        setState(() => _dx = _anim!.value);
      });
    _ctrl
      ..reset()
      ..forward();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _dx = (_dx + d.delta.dx).clamp(-_revealWidth * 1.2, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dx.abs() > _openSnapThreshold) {
      _animateTo(-_revealWidth);
    } else {
      _animateTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Desktop / web: no swipe reveal — right-click handles delete.
    if (!_touch) return widget.child;

    final tile = Transform.translate(
      offset: Offset(_dx, 0),
      child: widget.child,
    );

    return Stack(
      children: [
        // Red delete action sits behind the tile and is only rendered when
        // the tile has actually been dragged; otherwise it would bleed
        // through whenever the tile itself isn't fully opaque.
        if (_dx < 0)
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _animateTo(0);
                  widget.onDelete();
                },
                child: Container(
                  width: _revealWidth,
                  color: AppColors.red,
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 20, color: AppColors.onAccent),
                      const SizedBox(height: 2),
                      Text('Delete',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onAccent,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: tile,
        ),
      ],
    );
  }
}
