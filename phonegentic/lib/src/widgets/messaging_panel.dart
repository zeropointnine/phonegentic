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
      child: Column(
        children: [
          _buildHeader(messaging),
          Divider(height: 0.5, color: AppColors.border.withValues(alpha: 0.4)),
          _buildSearchBar(),
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
    );
  }

  Widget _buildHeader(MessagingService messaging) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(90, 18, 16, 10),
      child: Row(
        children: [
          Text(
            'Messages',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          HoverButton(
            onTap: () => messaging.syncNow(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.refresh_rounded,
                  size: 18, color: AppColors.textTertiary),
            ),
          ),
          HoverButton(
            onTap: () => setState(() => _showNewMessage = !_showNewMessage),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _showNewMessage
                    ? AppColors.accent.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.edit_rounded,
                  size: 18,
                  color: _showNewMessage
                      ? AppColors.accent
                      : AppColors.textTertiary),
            ),
          ),
          HoverButton(
            onTap: () => messaging.close(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close_rounded,
                  size: 18, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search conversations...',
            hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            prefixIcon: Icon(Icons.search_rounded,
                size: 16, color: AppColors.textTertiary),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 32, minHeight: 0),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
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
                border:
                    Border.all(color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
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
                      fontSize: 12, color: AppColors.textTertiary.withValues(alpha: 0.6)),
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

    return InkWell(
      onTap: () => messaging.selectConversation(convo.remotePhone),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            ContactIdenticon(
              seed: convo.contactName ?? convo.remotePhone,
              size: 42,
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
