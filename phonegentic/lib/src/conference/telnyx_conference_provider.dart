import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'conference_provider.dart';

/// Telnyx implementation of [ConferenceProvider].
///
/// Uses the Telnyx Call Control REST API (v2) to look up active calls
/// and create / manage conference bridges.  Requires a **Call Control App**
/// connection — credential connections do not support the Conference API
/// (no media redirection, no REST call control actions).
///
/// The [connectionId] must be the Call Control App's connection ID.
/// Webhooks from the Call Control App are relayed via WebSocket to the
/// Flutter client for B-leg discovery (distinct A/B-leg CCIDs).
class TelnyxConferenceProvider implements ConferenceProvider {
  TelnyxConferenceProvider({
    required String apiKey,
    required String connectionId,
    this.webhookUrl = '',
  })  : _apiKey = apiKey,
        _connectionId = connectionId;

  final String _apiKey;
  final String _connectionId;
  final String webhookUrl;

  static const _base = 'https://api.telnyx.com/v2';

  @override
  String get providerName => 'Telnyx';

  @override
  String get providerId => 'telnyx';

  @override
  bool get isConfigured => _apiKey.isNotEmpty && _connectionId.isNotEmpty;

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  void _checkResponse(http.Response resp, String label) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint(
          '[TelnyxConf] $label failed ${resp.statusCode}: ${resp.body}');
      throw ConferenceApiException(label, resp.statusCode, resp.body);
    }
  }

  // -----------------------------------------------------------------------
  // ConferenceProvider implementation
  // -----------------------------------------------------------------------

  @override
  Future<List<ActiveCallInfo>> lookupActiveCalls() async {
    final url = '$_base/connections/$_connectionId/active_calls';
    final results = <ActiveCallInfo>[];
    String? pageAfter;

    // Paginate through all active calls.
    while (true) {
      final uri = Uri.parse(url).replace(queryParameters: {
        'page[size]': '250',
        if (pageAfter != null) 'page[after]': pageAfter,
      });
      final resp = await http.get(uri, headers: _headers);
      _checkResponse(resp, 'lookupActiveCalls');

      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      for (final item in data) {
        final map = item as Map<String, dynamic>;
        final ccid = map['call_control_id'] as String? ?? '';
        final from = _extractPhoneField(map['from']);
        final to = _extractPhoneField(map['to']);
        debugPrint(
          '[TelnyxConf]   active call: ccid=$ccid '
          'from=$from to=$to '
          'leg=${map['call_leg_id']} '
          'session=${map['call_session_id']} '
          'keys=${map.keys.toList()}',
        );
        results.add(ActiveCallInfo(
          callControlId: ccid,
          from: from,
          to: to,
          durationSeconds: map['call_duration'] as int?,
          createdAt: (map['created_at'] ?? map['start_time']) as String?,
          callSessionId: map['call_session_id'] as String?,
          callLegId: map['call_leg_id'] as String?,
        ));
      }

      final meta = body['meta'] as Map<String, dynamic>?;
      final nextPage = meta?['page_after'] as String?;
      if (nextPage == null || nextPage.isEmpty || data.isEmpty) break;
      pageAfter = nextPage;
    }

    // Deduplicate by call_control_id (the API can return duplicates).
    final seen = <String>{};
    results.retainWhere((r) => seen.add(r.callControlId));

    debugPrint('[TelnyxConf] lookupActiveCalls found ${results.length} unique legs');

    // Call Control Apps normally include from/to, but enrich if missing.
    final needsEnrichment = results.any(
      (r) => (r.from == null || r.from!.isEmpty) &&
             (r.to == null || r.to!.isEmpty),
    );
    if (needsEnrichment) {
      debugPrint('[TelnyxConf] Enriching ${results.length} calls with details');
      final enriched = <ActiveCallInfo>[];
      for (final ac in results) {
        enriched.add(await _enrichCallInfo(ac));
      }
      // Sort chronologically so the greedy fallback maps oldest → first leg.
      enriched.sort((a, b) =>
          (a.createdAt ?? '').compareTo(b.createdAt ?? ''));
      return enriched;
    }

    return results;
  }

  /// Fetch detailed info for a single call to get from/to numbers.
  Future<ActiveCallInfo> _enrichCallInfo(ActiveCallInfo ac) async {
    try {
      final resp = await http.get(
        Uri.parse('$_base/calls/${ac.callControlId}'),
        headers: _headers,
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>? ?? {};
        final from = _extractPhoneField(data['from']) ?? ac.from;
        final to = _extractPhoneField(data['to']) ?? ac.to;
        final created = (data['start_time'] ?? data['created_at']) as String?
            ?? ac.createdAt;
        final sessionId =
            (data['call_session_id'] as String?) ?? ac.callSessionId;
        final legId = (data['call_leg_id'] as String?) ?? ac.callLegId;
        debugPrint(
          '[TelnyxConf]   enriched ${ac.callControlId}: '
          'from=$from to=$to created=$created '
          'session=$sessionId leg=$legId keys=${data.keys.toList()}',
        );
        return ActiveCallInfo(
          callControlId: ac.callControlId,
          from: from,
          to: to,
          durationSeconds: ac.durationSeconds,
          createdAt: created,
          callSessionId: sessionId,
          callLegId: legId,
        );
      }
      debugPrint(
        '[TelnyxConf]   enrich failed ${resp.statusCode}: ${resp.body} '
        'for ${ac.callControlId}',
      );
    } catch (e) {
      debugPrint('[TelnyxConf]   enrich error for ${ac.callControlId}: $e');
    }
    return ac;
  }

  /// Extract a phone number from a field that may be a plain string or
  /// a Telnyx object with `phone_number` / `sip_address` sub-fields.
  static String? _extractPhoneField(dynamic field) {
    if (field == null) return null;
    if (field is String) return field.isEmpty ? null : field;
    if (field is Map) {
      final phone = field['phone_number'] as String?;
      if (phone != null && phone.isNotEmpty) return phone;
      final sip = field['sip_address'] as String?;
      if (sip != null && sip.isNotEmpty) return sip;
      final any = field.values
          .whereType<String>()
          .where((v) => v.isNotEmpty);
      return any.isNotEmpty ? any.first : null;
    }
    return field.toString();
  }

  @override
  Future<ConferenceBridge> createConference(
    String callControlId, {
    String? name,
  }) async {
    final confName =
        name ?? 'phonegentic-${DateTime.now().millisecondsSinceEpoch}';
    final resp = await http.post(
      Uri.parse('$_base/conferences'),
      headers: _headers,
      body: jsonEncode({
        'call_control_id': callControlId,
        'name': confName,
      }),
    );
    _checkResponse(resp, 'createConference');

    final data =
        (jsonDecode(resp.body) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    final confId = data['id'] as String? ?? '';
    debugPrint('[TelnyxConf] created conference $confId ($confName)');
    return ConferenceBridge(conferenceId: confId, name: confName);
  }

  @override
  Future<void> joinConference(
      String conferenceId, String callControlId) async {
    final resp = await http.post(
      Uri.parse('$_base/conferences/$conferenceId/actions/join'),
      headers: _headers,
      body: jsonEncode({'call_control_id': callControlId}),
    );
    _checkResponse(resp, 'joinConference');
    debugPrint('[TelnyxConf] joined $callControlId → conference $conferenceId');
  }


  @override
  Future<void> holdParticipant(
      String conferenceId, String callControlId) async {
    final resp = await http.post(
      Uri.parse('$_base/conferences/$conferenceId/actions/hold'),
      headers: _headers,
      body: jsonEncode({'call_control_ids': [callControlId]}),
    );
    _checkResponse(resp, 'holdParticipant');
  }

  @override
  Future<void> unholdParticipant(
      String conferenceId, String callControlId) async {
    final resp = await http.post(
      Uri.parse('$_base/conferences/$conferenceId/actions/unhold'),
      headers: _headers,
      body: jsonEncode({'call_control_ids': [callControlId]}),
    );
    _checkResponse(resp, 'unholdParticipant');
  }

  @override
  Future<void> removeParticipant(
      String conferenceId, String callControlId) async {
    final resp = await http.post(
      Uri.parse('$_base/calls/$callControlId/actions/leave'),
      headers: _headers,
      body: jsonEncode({'conference_id': conferenceId}),
    );
    _checkResponse(resp, 'removeParticipant');
  }

  /// Invoked by the webhook listener for each Telnyx call control event.
  /// Returns the B-leg call_control_id if this is a `call.initiated` event
  /// for the terminator side (direction = "outgoing", i.e. the PSTN leg).
  static String? extractBLegFromWebhook(Map<String, dynamic> payload) {
    final data = payload['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    final eventType = data['event_type'] as String?;
    final eventPayload = data['payload'] as Map<String, dynamic>?;
    if (eventPayload == null) return null;

    // call.initiated with direction "outgoing" is the B-leg being created.
    if (eventType == 'call.initiated') {
      final direction = eventPayload['direction'] as String?;
      if (direction == 'outgoing') {
        final ccid = eventPayload['call_control_id'] as String?;
        final sessionId = eventPayload['call_session_id'] as String?;
        debugPrint(
          '[TelnyxConf] Webhook B-leg detected: ccid=$ccid '
          'session=$sessionId direction=$direction',
        );
        return ccid;
      }
    }
    return null;
  }

  @override
  Future<List<ConferenceParticipant>> listParticipants(
      String conferenceId) async {
    final resp = await http.get(
      Uri.parse('$_base/conferences/$conferenceId/participants'),
      headers: _headers,
    );
    _checkResponse(resp, 'listParticipants');

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>? ?? [];
    final participants = <ConferenceParticipant>[];
    for (final item in data) {
      final map = item as Map<String, dynamic>;
      participants.add(ConferenceParticipant(
        callControlId: map['call_control_id'] as String? ?? '',
        callLegId: map['call_leg_id'] as String?,
        callSessionId: map['call_session_id'] as String?,
        muted: map['muted'] as bool? ?? false,
        onHold: map['on_hold'] as bool? ?? false,
        status: map['status'] as String?,
      ));
    }
    return participants;
  }

}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

class ConferenceApiException implements Exception {
  final String operation;
  final int statusCode;
  final String body;

  ConferenceApiException(this.operation, this.statusCode, this.body);

  @override
  String toString() =>
      'ConferenceApiException($operation, status=$statusCode, body=$body)';
}
