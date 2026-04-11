import 'dart:async';

import 'package:flutter/widgets.dart';

import '../contact_service.dart';
import '../db/call_history_db.dart';
import 'messaging_config.dart';
import 'messaging_provider.dart';
import 'models/sms_conversation.dart';
import 'models/sms_message.dart';
import 'phone_numbers.dart';
import 'telnyx_messaging_provider.dart';
import 'twilio_messaging_provider.dart';
import 'webhook_listener.dart';

class MessagingService extends ChangeNotifier with WidgetsBindingObserver {
  ContactService? _contactService;
  MessagingProvider? _provider;
  WebhookListener? _webhookListener;
  StreamSubscription<SmsMessage>? _incomingSub;

  /// Register a handler for Telnyx call control webhook events (e.g. to
  /// capture B-leg call_control_ids for conference merging).
  set callControlHandler(void Function(Map<String, dynamic>)? handler) {
    if (_webhookListener != null) {
      _webhookListener!.onTelnyxCallControl = handler;
    }
    _pendingCallControlHandler = handler;
  }
  void Function(Map<String, dynamic>)? _pendingCallControlHandler;

  List<SmsConversation> _conversations = [];
  List<SmsMessage> _activeMessages = [];
  String? _selectedRemotePhone;
  int _unreadCount = 0;
  bool _isOpen = false;
  bool _windowFocused = true;
  Timer? _readTimer;
  String? _lastError;

  // Engagement heuristic: how long (ms) after focus before auto-marking read
  static const _readDelayMs = 30000;

  // ---------------------------------------------------------------------------
  // Public getters
  // ---------------------------------------------------------------------------

  List<SmsConversation> get conversations => _conversations;
  List<SmsMessage> get activeMessages => _activeMessages;
  String? get selectedRemotePhone => _selectedRemotePhone;
  int get unreadCount => _unreadCount;
  bool get isOpen => _isOpen;
  bool get isConfigured => _provider != null;
  String? get lastError => _lastError;

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  SmsConversation? get selectedConversation {
    if (_selectedRemotePhone == null) return null;
    return _conversations.cast<SmsConversation?>().firstWhere(
        (c) => c?.remotePhone == _selectedRemotePhone,
        orElse: () => null);
  }

  set contactService(ContactService? svc) {
    _contactService = svc;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await _loadProvider();
    await _refreshConversations();
  }

  Future<void> reconfigure() async {
    await _webhookListener?.stop();
    _webhookListener = null;
    await _provider?.disconnect();
    _incomingSub?.cancel();
    await _loadProvider();
    await _refreshConversations();
  }

  Future<void> _loadProvider() async {
    final backend = await MessagingSettings.loadBackend();

    if (backend == MessagingBackend.none) {
      _provider = null;
      notifyListeners();
      return;
    }

    final telnyxConfig = await TelnyxMessagingConfig.load();
    final twilioConfig = await TwilioMessagingConfig.load();

    MessagingProvider? next;

    if (backend == MessagingBackend.twilio && twilioConfig.isConfigured) {
      next = TwilioMessagingProvider(
        accountSid: twilioConfig.accountSid,
        authToken: twilioConfig.authToken,
        fromNumber: twilioConfig.fromNumber,
        pollingIntervalSeconds: twilioConfig.pollingIntervalSeconds,
      );
    } else if (backend == MessagingBackend.telnyx && telnyxConfig.isConfigured) {
      next = TelnyxMessagingProvider(
        apiKey: telnyxConfig.apiKey,
        fromNumber: telnyxConfig.fromNumber,
        messagingProfileId: telnyxConfig.messagingProfileId.isEmpty
            ? null
            : telnyxConfig.messagingProfileId,
        pollingIntervalSeconds: telnyxConfig.pollingIntervalSeconds,
      );
    } else if (twilioConfig.isConfigured) {
      next = TwilioMessagingProvider(
        accountSid: twilioConfig.accountSid,
        authToken: twilioConfig.authToken,
        fromNumber: twilioConfig.fromNumber,
        pollingIntervalSeconds: twilioConfig.pollingIntervalSeconds,
      );
    } else if (telnyxConfig.isConfigured) {
      next = TelnyxMessagingProvider(
        apiKey: telnyxConfig.apiKey,
        fromNumber: telnyxConfig.fromNumber,
        messagingProfileId: telnyxConfig.messagingProfileId.isEmpty
            ? null
            : telnyxConfig.messagingProfileId,
        pollingIntervalSeconds: telnyxConfig.pollingIntervalSeconds,
      );
    }

    _provider = next;
    if (_provider == null) return;

    _incomingSub?.cancel();
    _incomingSub = _provider!.incomingMessages.listen(_onIncomingMessage);
    await _provider!.connect();

    final webhookUrl = _provider is TwilioMessagingProvider
        ? twilioConfig.webhookUrl
        : telnyxConfig.webhookUrl;
    if (webhookUrl.isNotEmpty) {
      _webhookListener = WebhookListener(
        onTelnyxJson: _provider is TelnyxMessagingProvider
            ? (m) =>
                (_provider as TelnyxMessagingProvider).handleWebhookPayload(m)
            : null,
        onTwilioForm: _provider is TwilioMessagingProvider
            ? (f) =>
                (_provider as TwilioMessagingProvider).handleWebhookForm(f)
            : null,
        onTelnyxCallControl: _pendingCallControlHandler,
      );
      await _webhookListener!.start();
    }
  }

  // ---------------------------------------------------------------------------
  // Focus tracking (WidgetsBindingObserver)
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasFocused = _windowFocused;
    _windowFocused =
        state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (!wasFocused && _windowFocused) {
      _startReadTimer();
    }
    if (!_windowFocused) {
      _readTimer?.cancel();
    }
  }

  void _startReadTimer() {
    _readTimer?.cancel();
    if (_selectedRemotePhone == null) return;
    _readTimer = Timer(const Duration(milliseconds: _readDelayMs), () {
      if (_selectedRemotePhone != null && _windowFocused) {
        markConversationRead(_selectedRemotePhone!);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Panel open / close
  // ---------------------------------------------------------------------------

  void toggleOpen() {
    _isOpen = !_isOpen;
    if (_isOpen) {
      _refreshConversations();
    }
    notifyListeners();
  }

  void close() {
    _isOpen = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Conversation selection
  // ---------------------------------------------------------------------------

  Future<void> selectConversation(String remotePhone) async {
    _selectedRemotePhone = ensureE164(remotePhone);
    await _loadMessages(_selectedRemotePhone!);
    _startReadTimer();
    notifyListeners();
  }

  void deselectConversation() {
    _selectedRemotePhone = null;
    _activeMessages = [];
    _readTimer?.cancel();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Send message
  // ---------------------------------------------------------------------------

  Future<SmsMessage?> sendMessage({
    required String to,
    required String text,
    List<String>? mediaUrls,
  }) async {
    _lastError = null;
    if (_provider == null) {
      _lastError =
          'Messaging not configured. Set up SMS in Settings (Telnyx or Twilio).';
      notifyListeners();
      return null;
    }
    final from = _provider!.fromNumber;
    if (from.isEmpty) {
      _lastError = 'No "from" number configured in Settings.';
      notifyListeners();
      return null;
    }

    // Validate the destination number
    final stripped = to.replaceAll(RegExp(r'[\s\-\(\)\.\+]'), '');
    if (stripped.length < 10) {
      _lastError = 'Invalid number "$to" — needs at least 10 digits (e.g. +14155331352).';
      notifyListeners();
      return null;
    }

    // Optimistic update: show the message in the UI immediately
    final normalizedTo = ensureE164(to);
    final optimistic = SmsMessage(
      from: from,
      to: normalizedTo,
      text: text,
      direction: SmsDirection.outbound,
      status: SmsStatus.queued,
      createdAt: DateTime.now(),
      mediaUrls: mediaUrls ?? const [],
      isRead: true,
    );
    _activeMessages.add(optimistic);
    notifyListeners();

    try {
      final sent = await _provider!.sendMessage(
        to: to,
        from: from,
        text: text,
        mediaUrls: mediaUrls,
      );
      debugPrint('[MessagingService] API accepted message id=${sent.providerId} status=${sent.status}');

      // Telnyx returns "queued" for a freshly accepted message; promote to
      // "sent" so the UI reflects that the API accepted it.
      final withStatus = sent.status == SmsStatus.queued
          ? sent.copyWith(status: SmsStatus.sent, isRead: true)
          : sent.copyWith(isRead: true);

      _activeMessages.remove(optimistic);
      await _persistMessage(withStatus);
      await _refreshConversations();
      await _loadMessages(_selectedRemotePhone ?? normalizedTo);
      _lastError = null;
      notifyListeners();

      // Check delivery status after a short delay
      if (withStatus.providerId != null) {
        _checkDeliveryStatus(withStatus.providerId!, normalizedTo);
      }

      return withStatus;
    } catch (e) {
      debugPrint('[MessagingService] Send error: $e');
      _activeMessages.remove(optimistic);
      _lastError = 'Send failed: ${_friendlyError(e)}';
      notifyListeners();
      return null;
    }
  }

  /// Poll the message status a few times after sending to detect delivery
  /// failures (e.g. 10DLC not registered, carrier rejection).
  Future<void> _checkDeliveryStatus(String messageId, String remotePhone) async {
    const delays = [Duration(seconds: 3), Duration(seconds: 8), Duration(seconds: 20)];
    for (final delay in delays) {
      await Future.delayed(delay);
      try {
        final msg = await _provider!.getMessage(messageId);
        if (msg == null) continue;
        debugPrint('[MessagingService] Delivery check $messageId: ${msg.status}');

        if (msg.status == SmsStatus.delivered) {
          await _updateMessageStatus(messageId, SmsStatus.delivered);
          return;
        }
        if (msg.status == SmsStatus.failed) {
          await _updateMessageStatus(messageId, SmsStatus.failed,
              errorReason: msg.errorReason);

          if (msg.errorReason != null && msg.errorReason!.isNotEmpty) {
            _lastError = 'Message delivery failed: ${msg.errorReason}';
          } else {
            _lastError = _provider!.providerType == 'twilio'
                ? 'Message delivery failed. Check Twilio A2P 10DLC / toll-free '
                    'registration and account balance.'
                : 'Message delivery failed. Check your Telnyx 10DLC registration '
                    '(required for US numbers since Feb 2025) and account balance.';
          }
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('[MessagingService] Delivery check error: $e');
      }
    }
  }

  Future<void> _updateMessageStatus(String providerId, SmsStatus status,
      {String? errorReason}) async {
    final db = await CallHistoryDb.database;
    final values = <String, dynamic>{'status': status.name};
    if (errorReason != null) values['error_reason'] = errorReason;
    await db.update(
      'sms_messages',
      values,
      where: 'provider_id = ?',
      whereArgs: [providerId],
    );
    if (_selectedRemotePhone != null) {
      await _loadMessages(_selectedRemotePhone!);
      notifyListeners();
    }
  }

  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('40305')) return 'Invalid "from" number — check Settings.';
    if (s.contains('40310')) return 'Invalid "to" number — check the phone number.';
    if (s.contains('40300')) return 'Message rejected — check your Telnyx account.';
    if (s.contains('40010')) return 'Not 10DLC registered — required for US numbers.';
    if (s.contains('21211')) return 'Invalid phone number (Twilio).';
    if (s.contains('21610')) return 'Unverified or invalid Twilio "from" number.';
    if (s.contains('20003') || s.contains('Authenticate')) {
      return 'Twilio authentication failed — check Account SID and Auth Token.';
    }
    if (s.contains('401') || s.contains('403')) return 'Auth failed — check your API key.';
    return s.length > 120 ? '${s.substring(0, 120)}...' : s;
  }

  /// Send a reply in the currently selected conversation.
  Future<SmsMessage?> reply(String text, {List<String>? mediaUrls}) async {
    if (_selectedRemotePhone == null) return null;
    return sendMessage(
        to: _selectedRemotePhone!, text: text, mediaUrls: mediaUrls);
  }

  // ---------------------------------------------------------------------------
  // Delete (local soft-delete)
  // ---------------------------------------------------------------------------

  Future<void> deleteMessage(int localId) async {
    await CallHistoryDb.softDeleteSmsMessage(localId);
    _activeMessages.removeWhere((m) => m.localId == localId);
    await _refreshConversations();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Mark read
  // ---------------------------------------------------------------------------

  Future<void> markConversationRead(String remotePhone) async {
    await CallHistoryDb.markSmsRead(remotePhone);
    _unreadCount = await CallHistoryDb.getUnreadSmsCount();
    final idx = _conversations.indexWhere((c) => c.remotePhone == remotePhone);
    if (idx >= 0) {
      _conversations[idx] = _conversations[idx].copyWith(unreadCount: 0);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  Future<List<SmsMessage>> searchMessages(String query) async {
    final rows = await CallHistoryDb.searchSmsMessages(query);
    return rows.map((r) => SmsMessage.fromDbMap(r)).toList();
  }

  // ---------------------------------------------------------------------------
  // Incoming handler
  // ---------------------------------------------------------------------------

  Future<void> _onIncomingMessage(SmsMessage msg) async {
    final shouldMarkRead =
        _windowFocused && _isOpen && _selectedRemotePhone == msg.remotePhone;
    final toStore = shouldMarkRead ? msg.copyWith(isRead: true) : msg;
    await _persistMessage(toStore);
    await _refreshConversations();
    if (_selectedRemotePhone == msg.remotePhone) {
      await _loadMessages(msg.remotePhone);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Persistence helpers
  // ---------------------------------------------------------------------------

  Future<void> _persistMessage(SmsMessage msg) async {
    if (msg.providerId != null) {
      final existing = await CallHistoryDb.getSmsMessageByProviderId(
          msg.providerId!, msg.providerType);
      if (existing != null) {
        debugPrint('[MessagingService] Message already persisted, skipping: ${msg.providerId}');
        return;
      }
    }
    debugPrint('[MessagingService] Persisting message: remote=${msg.remotePhone} status=${msg.status}');
    await CallHistoryDb.insertSmsMessage(msg.toDbMap());
  }

  Future<void> _loadMessages(String remotePhone) async {
    final rows =
        await CallHistoryDb.getSmsMessagesForConversation(remotePhone);
    debugPrint('[MessagingService] Loaded ${rows.length} messages for $remotePhone');
    _activeMessages = rows.map((r) => SmsMessage.fromDbMap(r)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> _refreshConversations() async {
    final rows = await CallHistoryDb.getSmsConversations();
    final convos = <SmsConversation>[];
    for (final r in rows) {
      final remotePhone = r['remote_phone'] as String;
      final localPhone = (r['local_phone'] as String?) ?? '';
      final unread = (r['unread_count'] as int?) ?? 0;
      final total = (r['total_messages'] as int?) ?? 0;

      final lastRow = await CallHistoryDb.getLastSmsForConversation(remotePhone);
      final lastMsg =
          lastRow != null ? SmsMessage.fromDbMap(lastRow) : null;

      String? contactName;
      if (_contactService != null) {
        final contact = _contactService!.lookupByPhone(remotePhone);
        contactName = contact?['display_name'] as String?;
      }

      convos.add(SmsConversation(
        remotePhone: remotePhone,
        localPhone: localPhone,
        contactName: contactName,
        lastMessage: lastMsg,
        unreadCount: unread,
        totalMessages: total,
      ));
    }

    // Pin unread conversations at the top
    convos.sort((a, b) {
      if (a.unreadCount > 0 && b.unreadCount == 0) return -1;
      if (a.unreadCount == 0 && b.unreadCount > 0) return 1;
      final aTime = a.lastMessage?.createdAt ?? DateTime(2000);
      final bTime = b.lastMessage?.createdAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    _conversations = convos;
    _unreadCount = await CallHistoryDb.getUnreadSmsCount();
    notifyListeners();
  }

  /// Trigger an on-demand poll (useful for pull-to-refresh).
  Future<void> syncNow() async {
    if (_provider == null) return;
    try {
      final recent = await _provider!.listMessages(
        since: DateTime.now().subtract(const Duration(days: 1)),
        pageSize: 50,
      );
      for (final msg in recent) {
        await _persistMessage(msg);
      }
      await _refreshConversations();
      if (_selectedRemotePhone != null) {
        await _loadMessages(_selectedRemotePhone!);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[MessagingService] Sync error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Dispose
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readTimer?.cancel();
    _incomingSub?.cancel();
    _webhookListener?.stop();
    _provider?.disconnect();
    super.dispose();
  }
}
