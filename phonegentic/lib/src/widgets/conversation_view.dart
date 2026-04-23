import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'package:sip_ua/sip_ua.dart';

import '../contact_service.dart';
import '../demo_mode_service.dart';
import '../messaging/messaging_service.dart';
import '../messaging/models/sms_message.dart';
import '../messaging/phone_numbers.dart';
import '../theme_provider.dart';
import 'dialpad_contact_preview.dart';
import 'emoji_picker.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({super.key});

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final TextEditingController _composeCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _composeFocus = FocusNode();
  bool _showEmoji = false;
  String _searchQuery = '';
  List<String> _attachmentUrls = [];

  @override
  void dispose() {
    _composeCtrl.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _composeFocus.dispose();
    super.dispose();
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
        final allMessages = messaging.activeMessages;
        final messages = _searchQuery.isEmpty
            ? allMessages
            : allMessages
                .where((m) =>
                    m.text.toLowerCase().contains(_searchQuery.toLowerCase()))
                .toList();

        return DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: _onDropDone,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.bg,
              border: _isDragging
                  ? Border.all(
                      color: AppColors.accent.withValues(alpha: 0.8), width: 2)
                  : null,
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildConvoHeader(messaging, convo),
                  Expanded(
                    child: Stack(
                      children: [
                        messages.isEmpty
                            ? (_searchQuery.isNotEmpty
                                ? _buildNoSearchResults()
                                : _buildEmptyThread())
                            : _buildMessageList(messages, convo),
                        if (_isDragging)
                          Container(
                            color: AppColors.bg.withValues(alpha: 0.85),
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
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _buildConvoHeader(MessagingService messaging, dynamic convo) {
    final demo = context.read<DemoModeService>();
    final rawPhone = messaging.selectedRemotePhone ?? '';
    final rawName = convo?.contactName as String?;
    final name = rawName != null
        ? demo.maskDisplayName(rawName)
        : demo.maskPhone(rawPhone);
    final phone = demo.maskPhone(rawPhone);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => messaging.deselectConversation(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.message_rounded,
                      size: 15, color: AppColors.textTertiary),
                  const SizedBox(width: 4),
                  Text(
                    'Messages',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.chevron_right_rounded,
                        size: 16, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          ContactIdenticon(
            seed: convo?.contactName ?? rawPhone,
            size: 30,
            thumbnailPath: convo?.thumbnailPath as String?,
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
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
                  style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
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
                    color: AppColors.border.withValues(alpha: 0.4),
                    width: 0.5),
              ),
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  hintStyle:
                      TextStyle(color: AppColors.textTertiary, fontSize: 13),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 16, color: AppColors.textTertiary),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 32, minHeight: 0),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (v) => setState(() => _searchQuery = v.trim()),
              ),
            ),
          ),
          const SizedBox(width: 8),
          HoverButton(
            onTap: () => _dialRemote(rawPhone),
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
              child:
                  Icon(Icons.phone_rounded, size: 15, color: AppColors.accent),
            ),
          ),
          const SizedBox(width: 6),
          HoverButton(
            onTap: () => _openContact(rawPhone),
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
              child: Icon(Icons.person_rounded,
                  size: 15, color: AppColors.textSecondary),
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

  void _dialRemote(String rawPhone) async {
    if (rawPhone.isEmpty) return;
    context.read<MessagingService>().close();
    try {
      final helper = context.read<SIPUAHelper>();
      final stream = await navigator.mediaDevices
          .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
      helper.call(ensureE164(rawPhone), voiceOnly: true, mediaStream: stream);
    } catch (e) {
      debugPrint('[ConversationView] Call failed: $e');
    }
  }

  void _openContact(String rawPhone) {
    if (rawPhone.isEmpty) return;
    context.read<MessagingService>().close();
    context.read<ContactService>().openContactForPhone(rawPhone);
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

  Widget _buildNoSearchResults() {
    return Center(
      child: Text(
        'No messages match your search',
        style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
      ),
    );
  }

  Widget _buildMessageList(List<SmsMessage> messages, dynamic convo) {
    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final msgIdx = messages.length - 1 - i;
        final msg = messages[msgIdx];
        final showDate = msgIdx == 0 ||
            _shouldShowDate(messages[msgIdx - 1].createdAt, msg.createdAt);
        return Column(
          children: [
            if (showDate) _buildDateSeparator(msg.createdAt),
            _MessageBubble(
              message: msg,
              contactSeed: convo?.contactName as String? ??
                  convo?.remotePhone as String? ??
                  '?',
              showTail: msgIdx == messages.length - 1 ||
                  messages[msgIdx + 1].direction != msg.direction,
              onDelete: msg.localId != null
                  ? () => context
                      .read<MessagingService>()
                      .deleteMessage(msg.localId!)
                  : null,
              onResend: msg.status == SmsStatus.failed
                  ? () => context.read<MessagingService>().resendMessage(msg)
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
    final local = dt.toLocal();
    final now = DateTime.now();
    final h =
        local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour);
    final ampm = local.hour >= 12 ? 'PM' : 'AM';
    final time = '$h:${local.minute.toString().padLeft(2, '0')} $ampm';
    String label;
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      label = 'Today $time';
    } else {
      label = '${local.month}/${local.day}/${local.year} $time';
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
    return HoverButton(
      onTap: messaging.clearError,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.12),
          border: Border(
            top: BorderSide(
                color: AppColors.red.withValues(alpha: 0.3), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 15, color: AppColors.red),
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
                size: 14, color: AppColors.red.withValues(alpha: 0.6)),
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
          top: BorderSide(
              color: AppColors.border.withValues(alpha: 0.4), width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_attachmentUrls.isNotEmpty) _buildAttachmentPreview(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              HoverButton(
                onTap: _pickAttachment,
                child: Padding(
                  padding: const EdgeInsets.only(right: 2),
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
              HoverButton(
                onTap: () => setState(() => _showEmoji = !_showEmoji),
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    _showEmoji
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    size: 22,
                    color:
                        _showEmoji ? AppColors.accent : AppColors.textTertiary,
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
                        color: AppColors.border.withValues(alpha: 0.5),
                        width: 0.5),
                  ),
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
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
                        hintText: 'Message...',
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
              HoverButton(
                onTap: (_composeCtrl.text.trim().isNotEmpty ||
                        _attachmentUrls.isNotEmpty)
                    ? () => _send(messaging)
                    : null,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (_composeCtrl.text.trim().isNotEmpty ||
                            _attachmentUrls.isNotEmpty)
                        ? AppColors.accent
                        : AppColors.card,
                  ),
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    size: 18,
                    color: (_composeCtrl.text.trim().isNotEmpty ||
                            _attachmentUrls.isNotEmpty)
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
                      color: AppColors.border.withValues(alpha: 0.5),
                      width: 0.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _buildAttachmentThumb(_attachmentUrls[i]),
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: HoverButton(
                  onTap: () => setState(() => _attachmentUrls.removeAt(i)),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.red,
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(Icons.close, size: 12, color: AppColors.onAccent),
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
      return Image.network(path,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Center(
              child: Icon(Icons.image_rounded,
                  size: 20, color: AppColors.textTertiary)));
    }
    final file = File(path);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return Center(
        child:
            Icon(Icons.image_rounded, size: 20, color: AppColors.textTertiary));
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
          _composeCtrl.selection =
              TextSelection.collapsed(offset: _composeCtrl.text.length);
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
  final String contactSeed;
  final bool showTail;
  final VoidCallback? onDelete;
  final VoidCallback? onResend;

  const _MessageBubble({
    required this.message,
    required this.contactSeed,
    this.showTail = false,
    this.onDelete,
    this.onResend,
  });

  bool get _isOutbound => message.direction == SmsDirection.outbound;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final bubbleColor =
        _isOutbound ? accent.withValues(alpha: 0.08) : AppColors.card;
    final textColor = AppColors.textPrimary;
    final align =
        _isOutbound ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    Widget bubbleContent = Column(
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
              alignment: _isOutbound ? WrapAlignment.end : WrapAlignment.start,
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
                right: _isOutbound ? 0 : 60,
              ),
              child: CustomPaint(
                painter: _SpeechBubblePainter(
                  borderColor: _isOutbound
                      ? AppColors.accent.withValues(alpha: 0.35)
                      : AppColors.accent.withValues(alpha: 0.25),
                  fillColor: bubbleColor,
                  tailOnLeft: !_isOutbound,
                  showTail: showTail,
                  cornerRadius: 18,
                  tailWidth: 8,
                  tailHeight: 6,
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(14, 10, 14, showTail ? 16 : 10),
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
            ),
          ),
        if (_isOutbound && showTail)
          message.status == SmsStatus.failed
              ? _buildFailedStatus()
              : Padding(
                  padding: const EdgeInsets.only(top: 3, right: 4),
                  child: Text(
                    _statusLabel,
                    style:
                        TextStyle(fontSize: 10, color: AppColors.textTertiary),
                  ),
                ),
      ],
    );

    if (_isOutbound) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 3, bottom: 3),
          child: bubbleContent,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: bubbleContent,
      ),
    );
  }

  Widget _buildFailedStatus() {
    final bool hasError =
        message.errorReason != null && message.errorReason!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 3, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (hasError)
            Tooltip(
              message: message.errorReason!,
              preferBelow: false,
              triggerMode: TooltipTriggerMode.tap,
              showDuration: const Duration(seconds: 6),
              textStyle: const TextStyle(fontSize: 13, color: Colors.white),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: HoverButton(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.error_outline_rounded,
                        size: 13, color: AppColors.red),
                    const SizedBox(width: 3),
                    Text(
                      'Failed',
                      style: TextStyle(fontSize: 10, color: AppColors.red),
                    ),
                  ],
                ),
              ),
            )
          else ...<Widget>[
            Icon(Icons.error_outline_rounded, size: 13, color: AppColors.red),
            const SizedBox(width: 3),
            Text(
              'Failed',
              style: TextStyle(fontSize: 10, color: AppColors.red),
            ),
          ],
          if (onResend != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Text(
                '\u00B7',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            HoverButton(
              onTap: onResend,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Resend',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.green,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _statusLabel {
    switch (message.status) {
      case SmsStatus.delivered:
        return 'Delivered';
      case SmsStatus.sent:
        return 'Sent';
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
                leading: Icon(Icons.delete_outline_rounded,
                    size: 20, color: AppColors.red),
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

// =============================================================================
// Speech-bubble outline painter
// =============================================================================

class _SpeechBubblePainter extends CustomPainter {
  final Color borderColor;
  final Color fillColor;
  final bool tailOnLeft;
  final bool showTail;
  final double cornerRadius;
  final double tailWidth;
  final double tailHeight;

  _SpeechBubblePainter({
    required this.borderColor,
    required this.fillColor,
    required this.tailOnLeft,
    this.showTail = true,
    this.cornerRadius = 18,
    this.tailWidth = 8,
    this.tailHeight = 6,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = cornerRadius;
    final bodyH = showTail ? h - tailHeight : h;

    final path = Path();

    path.moveTo(r, 0);
    path.lineTo(w - r, 0);
    path.arcToPoint(Offset(w, r), radius: Radius.circular(r), clockwise: true);
    path.lineTo(w, bodyH - r);
    path.arcToPoint(Offset(w - r, bodyH),
        radius: Radius.circular(r), clockwise: true);

    if (showTail && tailOnLeft) {
      path.lineTo(r + tailWidth + 4, bodyH);
      path.lineTo(r + 2, bodyH + tailHeight);
      path.lineTo(r + 4, bodyH);
      path.lineTo(r, bodyH);
      path.arcToPoint(Offset(0, bodyH - r),
          radius: Radius.circular(r), clockwise: true);
    } else if (showTail && !tailOnLeft) {
      path.lineTo(w - r - 4, bodyH);
      path.lineTo(w - r - 2, bodyH + tailHeight);
      path.lineTo(w - r - tailWidth - 4, bodyH);
      path.lineTo(r, bodyH);
      path.arcToPoint(Offset(0, bodyH - r),
          radius: Radius.circular(r), clockwise: true);
    } else {
      path.lineTo(r, bodyH);
      path.arcToPoint(Offset(0, bodyH - r),
          radius: Radius.circular(r), clockwise: true);
    }

    path.lineTo(0, r);
    path.arcToPoint(Offset(r, 0), radius: Radius.circular(r), clockwise: true);
    path.close();

    canvas.drawPath(
        path,
        Paint()
          ..color = fillColor
          ..style = PaintingStyle.fill);

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
      old.tailOnLeft != tailOnLeft ||
      old.showTail != showTail;
}
