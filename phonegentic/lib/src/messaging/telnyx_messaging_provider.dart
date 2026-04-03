import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'messaging_provider.dart';
import 'models/sms_message.dart';
import 'phone_numbers.dart';

class TelnyxMessagingProvider implements MessagingProvider {
  static const _baseUrl = 'https://api.telnyx.com/v2';

  final String apiKey;
  @override
  final String fromNumber;
  final String? messagingProfileId;
  final int pollingIntervalSeconds;

  Timer? _pollTimer;
  final StreamController<SmsMessage> _incomingController =
      StreamController<SmsMessage>.broadcast();

  TelnyxMessagingProvider({
    required this.apiKey,
    required this.fromNumber,
    this.messagingProfileId,
    this.pollingIntervalSeconds = 15,
  });

  @override
  String get providerType => 'telnyx';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

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

    // Look up the messaging profile automatically if not configured or
    // the user entered a name instead of a UUID.
    String? profileId = messagingProfileId;
    if (profileId == null || profileId.isEmpty || !_looksLikeUuid(profileId)) {
      profileId = await _resolveMessagingProfileId(normalizedFrom);
    }

    final body = <String, dynamic>{
      'to': normalizedTo,
      'from': normalizedFrom,
      'text': text,
    };
    if (profileId != null && profileId.isNotEmpty) {
      body['messaging_profile_id'] = profileId;
    }
    if (mediaUrls != null && mediaUrls.isNotEmpty) {
      body['media_urls'] = mediaUrls;
      body['type'] = 'MMS';
    }

    debugPrint('[TelnyxMessaging] Sending: ${jsonEncode(body)}');

    final resp = await http.post(
      Uri.parse('$_baseUrl/messages'),
      headers: _headers,
      body: jsonEncode(body),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('[TelnyxMessaging] Send failed ${resp.statusCode}: ${resp.body}');
      throw TelnyxApiException(resp.statusCode, resp.body);
    }

    final data = jsonDecode(resp.body)['data'] as Map<String, dynamic>;
    return _parseMessageResponse(data, SmsDirection.outbound);
  }

  // ---------------------------------------------------------------------------
  // Retrieve single
  // ---------------------------------------------------------------------------

  @override
  Future<SmsMessage?> getMessage(String providerId) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/messages/$providerId'),
      headers: _headers,
    );
    if (resp.statusCode == 404) return null;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw TelnyxApiException(resp.statusCode, resp.body);
    }
    final data = jsonDecode(resp.body)['data'] as Map<String, dynamic>;
    final dir = (data['direction'] as String?) == 'inbound'
        ? SmsDirection.inbound
        : SmsDirection.outbound;
    return _parseMessageResponse(data, dir);
  }

  // ---------------------------------------------------------------------------
  // List via detail_records (delayed analytics data, no body text)
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
    final params = <String, String>{
      'filter[record_type]': 'messaging',
      'page[size]': pageSize.toString(),
      'page[number]': page.toString(),
    };
    if (since != null) {
      params['filter[date_range]'] = 'today';
    }
    if (direction != null) {
      params['filter[direction]'] = direction.name;
    }

    final uri = Uri.parse('$_baseUrl/detail_records')
        .replace(queryParameters: params);
    final resp = await http.get(uri, headers: _headers);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint('[TelnyxMessaging] detail_records error ${resp.statusCode}: ${resp.body}');
      throw TelnyxApiException(resp.statusCode, resp.body);
    }

    final json = jsonDecode(resp.body);
    final records = (json['data'] as List<dynamic>?) ?? [];

    final messages = <SmsMessage>[];
    for (final r in records) {
      final map = r as Map<String, dynamic>;
      final msg = _parseDetailRecord(map);
      if (msg == null) continue;
      if (remotePhone != null && msg.remotePhone != remotePhone) continue;
      messages.add(msg);
    }
    return messages;
  }

  // ---------------------------------------------------------------------------
  // Incoming stream
  // ---------------------------------------------------------------------------

  @override
  Stream<SmsMessage> get incomingMessages => _incomingController.stream;

  void handleWebhookPayload(Map<String, dynamic> payload) {
    try {
      final data = payload['data'] as Map<String, dynamic>?;
      if (data == null) return;
      final eventType = (data['event_type'] as String?) ?? '';
      if (eventType != 'message.received') return;
      final msgPayload = data['payload'] as Map<String, dynamic>?;
      if (msgPayload == null) return;
      final msg = _parseMessageResponse(msgPayload, SmsDirection.inbound);
      _incomingController.add(msg);
    } catch (e) {
      debugPrint('[TelnyxMessaging] Webhook parse error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Polling -- two-step: MDR to detect IDs, then GET /messages/{id} for body
  // ---------------------------------------------------------------------------

  final Set<String> _seenMessageIds = {};

  void _startPolling() {
    _pollTimer?.cancel();
    debugPrint('[TelnyxMessaging] Starting poll every ${pollingIntervalSeconds}s');
    _pollTimer =
        Timer.periodic(Duration(seconds: pollingIntervalSeconds), (_) async {
      try {
        await _pollOnce();
      } catch (e) {
        debugPrint('[TelnyxMessaging] Poll error: $e');
      }
    });
  }

  Future<void> _pollOnce() async {
    // Step 1: fetch detail records to discover new inbound message IDs
    final mdrMsgs = await listMessages(
      direction: SmsDirection.inbound,
      pageSize: 50,
    );
    debugPrint('[TelnyxMessaging] Poll found ${mdrMsgs.length} inbound MDR records');

    int newCount = 0;
    for (final mdr in mdrMsgs) {
      final id = mdr.providerId;
      if (id == null || _seenMessageIds.contains(id)) continue;
      _seenMessageIds.add(id);
      newCount++;

      // Step 2: fetch full message by ID to get body text
      try {
        final full = await getMessage(id);
        if (full != null) {
          debugPrint('[TelnyxMessaging] Fetched inbound msg $id: "${full.text}"');
          _incomingController.add(full);
        } else {
          _incomingController.add(mdr);
        }
      } catch (e) {
        debugPrint('[TelnyxMessaging] Failed to fetch message $id: $e');
        _incomingController.add(mdr);
      }
    }
    if (newCount > 0) {
      debugPrint('[TelnyxMessaging] $newCount new inbound message(s)');
    }

    // Cap seen-IDs set to avoid unbounded growth
    if (_seenMessageIds.length > 500) {
      final excess = _seenMessageIds.length - 300;
      _seenMessageIds.removeAll(_seenMessageIds.take(excess).toList());
    }
  }

  // ---------------------------------------------------------------------------
  // Auto-resolve messaging profile
  // ---------------------------------------------------------------------------

  String? _cachedProfileId;

  /// Query the Telnyx messaging profiles API and find one that owns [fromNumber].
  /// Falls back to the first profile if no number match is found.
  Future<String?> _resolveMessagingProfileId(String fromNumber) async {
    if (_cachedProfileId != null) return _cachedProfileId;
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/messaging_profiles'),
        headers: _headers,
      );
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body);
      final profiles = (json['data'] as List<dynamic>?) ?? [];
      if (profiles.isEmpty) return null;

      // Use the first available messaging profile
      final first = profiles.first as Map<String, dynamic>;
      _cachedProfileId = first['id'] as String?;
      debugPrint('[TelnyxMessaging] Auto-resolved profile: $_cachedProfileId');
      return _cachedProfileId;
    } catch (e) {
      debugPrint('[TelnyxMessaging] Profile lookup error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Test / connect / disconnect
  // ---------------------------------------------------------------------------

  @override
  Future<bool> testConnection() async {
    try {
      final resp = await http.get(
        Uri.parse('$_baseUrl/messaging_profiles'),
        headers: _headers,
      );
      if (resp.statusCode != 200) {
        debugPrint('[TelnyxMessaging] testConnection failed: ${resp.statusCode}');
        return false;
      }
      final json = jsonDecode(resp.body);
      final profiles = (json['data'] as List<dynamic>?) ?? [];
      debugPrint('[TelnyxMessaging] Found ${profiles.length} messaging profile(s)');
      for (final p in profiles) {
        final m = p as Map<String, dynamic>;
        debugPrint('[TelnyxMessaging]   profile id=${m['id']} name=${m['name']}');
      }
      return true;
    } catch (e) {
      debugPrint('[TelnyxMessaging] testConnection error: $e');
      return false;
    }
  }

  @override
  Future<void> connect() async {
    // Seed seen IDs so we don't re-process historical messages on first poll
    try {
      final existing = await listMessages(
          direction: SmsDirection.inbound, pageSize: 50);
      for (final m in existing) {
        if (m.providerId != null) _seenMessageIds.add(m.providerId!);
      }
      debugPrint('[TelnyxMessaging] Seeded ${_seenMessageIds.length} existing message IDs');
    } catch (e) {
      debugPrint('[TelnyxMessaging] Seed error (non-fatal): $e');
    }
    _startPolling();
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers
  // ---------------------------------------------------------------------------

  SmsMessage _parseMessageResponse(
      Map<String, dynamic> data, SmsDirection dir) {
    final fromObj = data['from'] as Map<String, dynamic>?;
    final toList = data['to'] as List<dynamic>?;

    String fromPhone = '';
    if (fromObj != null) {
      fromPhone = (fromObj['phone_number'] as String?) ?? '';
    } else if (data['from'] is String) {
      fromPhone = data['from'] as String;
    }

    String toPhone = '';
    if (toList != null && toList.isNotEmpty) {
      final first = toList.first;
      if (first is Map<String, dynamic>) {
        toPhone = (first['phone_number'] as String?) ?? '';
      } else if (first is String) {
        toPhone = first;
      }
    } else if (data['to'] is String) {
      toPhone = data['to'] as String;
    }

    final mediaList = <String>[];
    final media = data['media'] as List<dynamic>?;
    if (media != null) {
      for (final m in media) {
        final url = (m as Map<String, dynamic>)['url'] as String?;
        if (url != null) mediaList.add(url);
      }
    }

    final status = _mapStatus(data);

    return SmsMessage(
      providerId: data['id'] as String?,
      providerType: 'telnyx',
      from: fromPhone,
      to: toPhone,
      text: (data['text'] as String?) ?? '',
      direction: dir,
      status: status,
      createdAt: _parseTime(data),
      mediaUrls: mediaList,
    );
  }

  SmsMessage? _parseDetailRecord(Map<String, dynamic> r) {
    final dir = (r['direction'] as String?) == 'inbound'
        ? SmsDirection.inbound
        : SmsDirection.outbound;
    final cli = (r['cli'] as String?) ?? '';
    final cld = (r['cld'] as String?) ?? '';
    final from = dir == SmsDirection.inbound ? cli : cld;
    final to = dir == SmsDirection.inbound ? cld : cli;
    final createdAt = r['created_at'] as String?;
    if (createdAt == null) return null;
    return SmsMessage(
      providerId: r['id'] as String?,
      providerType: 'telnyx',
      from: from,
      to: to,
      text: '',
      direction: dir,
      status: _mapDetailStatus(r['status'] as String?),
      createdAt: DateTime.parse(createdAt),
    );
  }

  SmsStatus _mapStatus(Map<String, dynamic> data) {
    final toList = data['to'] as List<dynamic>?;
    if (toList != null && toList.isNotEmpty) {
      final first = toList.first;
      if (first is Map<String, dynamic>) {
        final s = first['status'] as String?;
        return _mapDetailStatus(s);
      }
    }
    return SmsStatus.queued;
  }

  SmsStatus _mapDetailStatus(String? s) {
    switch (s) {
      case 'delivered':
        return SmsStatus.delivered;
      case 'sent':
        return SmsStatus.sent;
      case 'queued':
      case 'sending':
        return SmsStatus.queued;
      case 'delivery_failed':
      case 'sending_failed':
        return SmsStatus.failed;
      default:
        return SmsStatus.queued;
    }
  }

  DateTime _parseTime(Map<String, dynamic> data) {
    final received = data['received_at'] as String?;
    if (received != null) return DateTime.parse(received);
    final sent = data['sent_at'] as String?;
    if (sent != null) return DateTime.parse(sent);
    return DateTime.now();
  }

  static bool _looksLikeUuid(String s) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(s);
  }
}

class TelnyxApiException implements Exception {
  final int statusCode;
  final String body;
  const TelnyxApiException(this.statusCode, this.body);
  @override
  String toString() => 'TelnyxApiException($statusCode): $body';
}
