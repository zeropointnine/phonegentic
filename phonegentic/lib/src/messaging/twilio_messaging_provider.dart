import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'messaging_provider.dart';
import 'models/sms_message.dart';
import 'phone_numbers.dart';

class TwilioMessagingProvider implements MessagingProvider {
  final String accountSid;
  final String authToken;
  @override
  final String fromNumber;
  final int pollingIntervalSeconds;

  Timer? _pollTimer;
  final StreamController<SmsMessage> _incomingController =
      StreamController<SmsMessage>.broadcast();
  final Set<String> _seenMessageSids = {};

  TwilioMessagingProvider({
    required this.accountSid,
    required this.authToken,
    required this.fromNumber,
    this.pollingIntervalSeconds = 15,
  });

  @override
  String get providerType => 'twilio';

  String get _accountPath =>
      'https://api.twilio.com/2010-04-01/Accounts/${Uri.encodeComponent(accountSid)}';

  String get _messagesUrl => '$_accountPath/Messages.json';

  Map<String, String> get _headers => {
        'Authorization': _basicAuth(),
        'Accept': 'application/json',
      };

  String _basicAuth() {
    final token = base64Encode(utf8.encode('$accountSid:$authToken'));
    return 'Basic $token';
  }

  static String _encodeForm(List<MapEntry<String, String>> pairs) {
    return pairs
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  // ---------------------------------------------------------------------------
  // Send
  // ---------------------------------------------------------------------------

  @override
  Future<SmsMessage> sendMessage({
    required String to,
    required String from,
    required String text,
    List<String>? mediaUrls,
  }) async {
    final normalizedFrom = ensureE164(from);
    final normalizedTo = ensureE164(to);

    final pairs = <MapEntry<String, String>>[
      MapEntry('To', normalizedTo),
      MapEntry('From', normalizedFrom),
      MapEntry('Body', text),
    ];
    for (final u in mediaUrls ?? const <String>[]) {
      pairs.add(MapEntry('MediaUrl', u));
    }

    final resp = await http.post(
      Uri.parse(_messagesUrl),
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: _encodeForm(pairs),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('[TwilioMessaging] Send failed ${resp.statusCode}: ${resp.body}');
      throw TwilioApiException(resp.statusCode, resp.body);
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseMessageResource(data, SmsDirection.outbound);
  }

  // ---------------------------------------------------------------------------
  // Single message
  // ---------------------------------------------------------------------------

  @override
  Future<SmsMessage?> getMessage(String providerId) async {
    final uri = Uri.parse('$_accountPath/Messages/${Uri.encodeComponent(providerId)}.json');
    final resp = await http.get(uri, headers: _headers);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw TwilioApiException(resp.statusCode, resp.body);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseMessageResource(data, _directionFromTwilio(data['direction'] as String?));
  }

  // ---------------------------------------------------------------------------
  // List (recent page; filter client-side)
  // ---------------------------------------------------------------------------

  @override
  Future<List<SmsMessage>> listMessages({
    String? remotePhone,
    DateTime? since,
    DateTime? until,
    SmsDirection? direction,
    int pageSize = 50,
    int page = 1,
  }) async {
    final qp = <String, String>{
      'PageSize': pageSize.clamp(1, 1000).toString(),
      'Page': (page - 1).clamp(0, 9999).toString(),
    };
    final uri = Uri.parse(_messagesUrl).replace(queryParameters: qp);
    final resp = await http.get(uri, headers: _headers);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('[TwilioMessaging] List failed ${resp.statusCode}: ${resp.body}');
      throw TwilioApiException(resp.statusCode, resp.body);
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = (json['messages'] as List<dynamic>?) ?? [];
    final out = <SmsMessage>[];

    for (final item in raw) {
      final m = item as Map<String, dynamic>;
      final dir = _directionFromTwilio(m['direction'] as String?);
      if (direction != null && dir != direction) continue;

      final msg = _parseMessageResource(m, dir);
      if (remotePhone != null && msg.remotePhone != remotePhone) continue;

      final t = msg.createdAt;
      if (since != null && t.isBefore(since)) continue;
      if (until != null && t.isAfter(until)) continue;

      out.add(msg);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------------

  @override
  Stream<SmsMessage> get incomingMessages => _incomingController.stream;

  /// Twilio status callback / inbound webhook (form-encoded).
  void handleWebhookForm(Map<String, String> form) {
    try {
      final sid = form['MessageSid'] ?? form['SmsSid'];
      if (sid == null || sid.isEmpty) return;

      final from = form['From'] ?? '';
      final to = form['To'] ?? '';
      final body = form['Body'] ?? '';
      final numMedia = int.tryParse(form['NumMedia'] ?? '0') ?? 0;
      final media = <String>[];
      for (var i = 0; i < numMedia; i++) {
        final u = form['MediaUrl$i'];
        if (u != null && u.isNotEmpty) media.add(u);
      }

      final msg = SmsMessage(
        providerId: sid,
        providerType: 'twilio',
        from: from,
        to: to,
        text: body,
        direction: SmsDirection.inbound,
        status: SmsStatus.received,
        createdAt: DateTime.now(),
        mediaUrls: media,
      );
      _incomingController.add(msg);
    } catch (e) {
      debugPrint('[TwilioMessaging] Webhook form parse error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Polling
  // ---------------------------------------------------------------------------

  void _startPolling() {
    _pollTimer?.cancel();
    debugPrint('[TwilioMessaging] Starting poll every ${pollingIntervalSeconds}s');
    _pollTimer =
        Timer.periodic(Duration(seconds: pollingIntervalSeconds), (_) async {
      try {
        await _pollOnce();
      } catch (e) {
        debugPrint('[TwilioMessaging] Poll error: $e');
      }
    });
  }

  Future<void> _pollOnce() async {
    final recent = await listMessages(
      direction: SmsDirection.inbound,
      pageSize: 50,
      page: 1,
    );

    var newCount = 0;
    for (final msg in recent) {
      final sid = msg.providerId;
      if (sid == null || _seenMessageSids.contains(sid)) continue;
      _seenMessageSids.add(sid);
      newCount++;
      if (msg.text.isEmpty && sid.isNotEmpty) {
        try {
          final full = await getMessage(sid);
          if (full != null) {
            _incomingController.add(full);
            continue;
          }
        } catch (e) {
          debugPrint('[TwilioMessaging] Failed to fetch message $sid: $e');
        }
      }
      _incomingController.add(msg);
    }
    if (newCount > 0) {
      debugPrint('[TwilioMessaging] $newCount new inbound message(s)');
    }

    if (_seenMessageSids.length > 500) {
      final excess = _seenMessageSids.length - 300;
      _seenMessageSids.removeAll(_seenMessageSids.take(excess).toList());
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<bool> testConnection() async {
    try {
      final uri = Uri.parse('$_accountPath.json');
      final resp = await http.get(uri, headers: _headers);
      if (resp.statusCode != 200) {
        debugPrint('[TwilioMessaging] testConnection failed: ${resp.statusCode}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[TwilioMessaging] testConnection error: $e');
      return false;
    }
  }

  @override
  Future<void> connect() async {
    try {
      final existing = await listMessages(
        direction: SmsDirection.inbound,
        pageSize: 50,
      );
      for (final m in existing) {
        if (m.providerId != null) _seenMessageSids.add(m.providerId!);
      }
      debugPrint(
          '[TwilioMessaging] Seeded ${_seenMessageSids.length} existing message SIDs');
    } catch (e) {
      debugPrint('[TwilioMessaging] Seed error (non-fatal): $e');
    }
    _startPolling();
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  SmsDirection _directionFromTwilio(String? d) {
    if (d == 'inbound') return SmsDirection.inbound;
    return SmsDirection.outbound;
  }

  SmsMessage _parseMessageResource(Map<String, dynamic> m, SmsDirection dir) {
    final from = (m['from'] as String?) ?? '';
    final to = (m['to'] as String?) ?? '';
    final body = (m['body'] as String?) ?? '';
    final sid = m['sid'] as String?;

    final status = _mapTwilioStatus(m['status'] as String?, dir);
    final created = _parseTwilioTime(m);

    return SmsMessage(
      providerId: sid,
      providerType: 'twilio',
      from: from,
      to: to,
      text: body,
      direction: dir,
      status: status,
      createdAt: created,
      mediaUrls: const [],
    );
  }

  DateTime _parseTwilioTime(Map<String, dynamic> m) {
    for (final key in ['date_sent', 'date_created', 'date_updated']) {
      final s = m[key] as String?;
      if (s != null && s.isNotEmpty) {
        try {
          return DateTime.parse(s);
        } catch (_) {}
      }
    }
    return DateTime.now();
  }

  SmsStatus _mapTwilioStatus(String? s, SmsDirection dir) {
    if (dir == SmsDirection.inbound) {
      return s == 'received' ? SmsStatus.received : SmsStatus.delivered;
    }
    switch (s) {
      case 'queued':
      case 'accepted':
        return SmsStatus.queued;
      case 'sending':
      case 'scheduled':
        return SmsStatus.queued;
      case 'sent':
        return SmsStatus.sent;
      case 'delivered':
        return SmsStatus.delivered;
      case 'undelivered':
      case 'failed':
      case 'canceled':
        return SmsStatus.failed;
      default:
        return SmsStatus.queued;
    }
  }
}

class TwilioApiException implements Exception {
  final int statusCode;
  final String body;
  const TwilioApiException(this.statusCode, this.body);
  @override
  String toString() => 'TwilioApiException($statusCode): $body';
}
