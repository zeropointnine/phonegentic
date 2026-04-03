import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../messaging/models/sms_message.dart';
import '../theme_provider.dart';
import 'emoji_picker.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({Key? key}) : super(key: key);

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final TextEditingController _composeCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _composeFocus = FocusNode();
  bool _showEmoji = false;
  int _lastCount = 0;
  List<String> _attachmentUrls = [];

  @override
  void dispose() {
    _composeCtrl.dispose();
    _scrollCtrl.dispose();
    _composeFocus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send(MessagingService messaging) {
    final text = _composeCtrl.text.trim();
    if (text.isEmpty && _attachmentUrls.isEmpty) return;
    _composeCtrl.clear();
    messaging.reply(
      text,
      mediaUrls: _attachmentUrls.isNotEmpty ? _attachmentUrls : null,
    );
    setState(() => _attachmentUrls = []);
    _composeFocus.requestFocus();
  }

  bool _isDragging = false;

  void _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result != null) {
      setState(() {
        for (final f in result.files) {
          if (f.path != null) _attachmentUrls.add(f.path!);
        }
      });
    }
  }

  void _onDropDone(DropDoneDetails details) {
    setState(() {
      for (final xFile in details.files) {
        final path = xFile.path;
        if (path.isNotEmpty) _attachmentUrls.add(path);
      }
      _isDragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MessagingService>(
      builder: (context, messaging, _) {
        final convo = messaging.selectedConversation;
        final messages = messaging.activeMessages;

        if (messages.length != _lastCount) {
          _lastCount = messages.length;
          _scrollToBottom();
        }

        return DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: _onDropDone,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.bg,
              border: _isDragging
                  ? Border.all(
                      color: AppColors.accent.withOpacity(0.8), width: 2)
                  : null,
            ),
            child: Column(
              children: [
                _buildConvoHeader(messaging, convo),
                Divider(height: 0.5, color: AppColors.border.withOpacity(0.4)),
                Expanded(
                  child: Stack(
                    children: [
                      messages.isEmpty
                          ? _buildEmptyThread()
                          : _buildMessageList(messages),
                      if (_isDragging)
                        Container(
                          color: AppColors.bg.withOpacity(0.85),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.file_upload_outlined,
                                    size: 48, color: AppColors.accent),
                                const SizedBox(height: 8),
                                Text('Drop images here',
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: AppColors.textSecondary)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (messaging.lastError != null) _buildErrorBanner(messaging),
                _buildComposeBar(messaging),
                if (_showEmoji) _buildEmojiPicker(),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildConvoHeader(
      MessagingService messaging, dynamic convo) {
    final demo = context.read<DemoModeService>();
    final rawPhone = messaging.selectedRemotePhone ?? '';
    final rawName = convo?.contactName as String?;
    final name = rawName != null
        ? demo.maskDisplayName(rawName)
        : demo.maskPhone(rawPhone);
    final phone = demo.maskPhone(rawPhone);
    return Padding(
      padding: const EdgeInsets.fromLTRB(90, 18, 16, 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => messaging.deselectConversation(),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppColors.border.withOpacity(0.4), width: 0.5),
              ),
              child: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 14, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          // Avatar
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withOpacity(0.12),
            ),
            child: Center(
              child: Text(
                convo?.initials ?? '#',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  phone,
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          GestureDetector(
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

  // ---------------------------------------------------------------------------
  // Message list
  // ---------------------------------------------------------------------------

  Widget _buildEmptyThread() {
    return Center(
      child: Text(
        'Start the conversation...',
        style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
      ),
    );
  }

  Widget _buildMessageList(List<SmsMessage> messages) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final msg = messages[i];
        final showDate = i == 0 ||
            _shouldShowDate(messages[i - 1].createdAt, msg.createdAt);
        return Column(
          children: [
            if (showDate) _buildDateSeparator(msg.createdAt),
            _MessageBubble(
              message: msg,
              showTail: i == messages.length - 1 ||
                  messages[i + 1].direction != msg.direction,
              onDelete: msg.localId != null
                  ? () => context
                      .read<MessagingService>()
                      .deleteMessage(msg.localId!)
                  : null,
            ),
          ],
        );
      },
    );
  }

  bool _shouldShowDate(DateTime prev, DateTime current) {
    return current.difference(prev).inMinutes > 30;
  }

  Widget _buildDateSeparator(DateTime dt) {
    final now = DateTime.now();
    String label;
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      label =
          'Today ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else {
      label =
          '${dt.month}/${dt.day}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error banner
  // ---------------------------------------------------------------------------

  Widget _buildErrorBanner(MessagingService messaging) {
    return GestureDetector(
      onTap: messaging.clearError,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.red.withOpacity(0.12),
          border: Border(
            top: BorderSide(color: AppColors.red.withOpacity(0.3), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                size: 15, color: AppColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                messaging.lastError!,
                style: TextStyle(fontSize: 12, color: AppColors.red),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.close_rounded,
                size: 14, color: AppColors.red.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Compose bar
  // ---------------------------------------------------------------------------

  Widget _buildComposeBar(MessagingService messaging) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border.withOpacity(0.4), width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_attachmentUrls.isNotEmpty)
            _buildAttachmentPreview(),
          Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: _pickAttachment,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 2),
              child: Icon(
                Icons.add_photo_alternate_outlined,
                size: 22,
                color: _attachmentUrls.isNotEmpty
                    ? AppColors.accent
                    : AppColors.textTertiary,
              ),
            ),
          ),
          // Emoji toggle
          GestureDetector(
            onTap: () => setState(() => _showEmoji = !_showEmoji),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 4),
              child: Icon(
                _showEmoji
                    ? Icons.keyboard_rounded
                    : Icons.emoji_emotions_outlined,
                size: 22,
                color: _showEmoji ? AppColors.accent : AppColors.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      HardwareKeyboard.instance.isShiftPressed) {
                    _send(messaging);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _composeCtrl,
                  focusNode: _composeFocus,
                  maxLines: null,
                  textInputAction: TextInputAction.newline,
                  style:
                      TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Message... (Shift+Enter to send)',
                    hintStyle: TextStyle(
                        fontSize: 13, color: AppColors.textTertiary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: (_composeCtrl.text.trim().isNotEmpty || _attachmentUrls.isNotEmpty)
                ? () => _send(messaging)
                : null,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (_composeCtrl.text.trim().isNotEmpty || _attachmentUrls.isNotEmpty)
                    ? AppColors.accent
                    : AppColors.card,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                color: (_composeCtrl.text.trim().isNotEmpty || _attachmentUrls.isNotEmpty)
                    ? AppColors.onAccent
                    : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
        ],
      ),
    );
  }

  Widget _buildAttachmentPreview() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _attachmentUrls.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) => Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.border.withOpacity(0.5), width: 0.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _buildAttachmentThumb(_attachmentUrls[i]),
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: GestureDetector(
                  onTap: () => setState(
                      () => _attachmentUrls.removeAt(i)),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close, size: 12, color: AppColors.onAccent),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentThumb(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Image.network(path, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Center(
                child: Icon(Icons.image_rounded,
                    size: 20, color: AppColors.textTertiary)));
    }
    final file = File(path);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return Center(
        child: Icon(Icons.image_rounded,
            size: 20, color: AppColors.textTertiary));
  }

  // ---------------------------------------------------------------------------
  // Emoji picker
  // ---------------------------------------------------------------------------

  Widget _buildEmojiPicker() {
    return SizedBox(
      height: 180,
      child: EmojiPickerWidget(
        onSelected: (emoji) {
          _composeCtrl.text += emoji;
          _composeCtrl.selection = TextSelection.collapsed(
              offset: _composeCtrl.text.length);
          setState(() {});
        },
      ),
    );
  }
}

// =============================================================================
// Message Bubble (iMessage / macOS 26 style)
// =============================================================================

class _MessageBubble extends StatelessWidget {
  final SmsMessage message;
  final bool showTail;
  final VoidCallback? onDelete;

  const _MessageBubble({
    required this.message,
    this.showTail = false,
    this.onDelete,
  });

  bool get _isOutbound => message.direction == SmsDirection.outbound;

  @override
  Widget build(BuildContext context) {
    final bubbleColor = _isOutbound
        ? AppColors.accent
        : AppColors.surface;
    final textColor = _isOutbound
        ? AppColors.onAccent
        : AppColors.textPrimary;
    final align = _isOutbound ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(_isOutbound || !showTail ? 18 : 4),
      bottomRight: Radius.circular(!_isOutbound || !showTail ? 18 : 4),
    );

    return Align(
      alignment: _isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: align,
          children: [
          if (message.mediaUrls.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                left: _isOutbound ? 60 : 0,
                right: _isOutbound ? 0 : 60,
                bottom: 4,
              ),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment:
                    _isOutbound ? WrapAlignment.end : WrapAlignment.start,
                children: message.mediaUrls
                    .map((url) => ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            url,
                            width: 180,
                            height: 180,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 180,
                              height: 60,
                              decoration: BoxDecoration(
                                color: AppColors.card,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Icon(Icons.broken_image_rounded,
                                    size: 24, color: AppColors.textTertiary),
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),

          if (message.text.isNotEmpty)
            GestureDetector(
              onLongPress: () => _showContextMenu(context),
              child: Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.65),
                margin: EdgeInsets.only(
                  left: _isOutbound ? 60 : 0,
                  right: _isOutbound ? 0 : 60,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: borderRadius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Text(
                  message.text,
                  style: TextStyle(
                    fontSize: 14,
                    color: textColor,
                    height: 1.35,
                  ),
                ),
              ),
            ),

          if (_isOutbound && showTail)
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 4),
              child: Text(
                _statusLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: message.status == SmsStatus.failed
                      ? AppColors.red
                      : AppColors.textTertiary,
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }

  String get _statusLabel {
    switch (message.status) {
      case SmsStatus.delivered:
        return 'Delivered';
      case SmsStatus.sent:
        return 'Sent';
      case SmsStatus.failed:
        return 'Failed';
      case SmsStatus.queued:
        return 'Sending...';
      default:
        return '';
    }
  }

  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded, size: 20),
              title: const Text('Copy', style: TextStyle(fontSize: 14)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.text));
                Navigator.pop(context);
              },
            ),
            if (onDelete != null)
              ListTile(
                leading:
                    Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.red),
                title: Text('Delete',
                    style: TextStyle(fontSize: 14, color: AppColors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onDelete!();
                },
              ),
          ],
        ),
      ),
    );
  }
}
