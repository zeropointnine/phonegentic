import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'conference_provider.dart';

/// Telnyx implementation of [ConferenceProvider].
///
/// Uses the Telnyx Call Control REST API (v2) to look up active calls
/// and create / manage conference bridges.  No webhooks required — all
/// operations are synchronous request/response from the client.
///
/// The active-calls endpoint requires either a Call Control App ID or a
/// credential connection with `webhook_event_url` set.  If the supplied
/// [connectionId] is a plain SIP credential connection, the provider
/// auto-resolves the correct ID at first use:
///   1. Lists existing Call Control Applications on the account.
///   2. Falls back to patching the credential connection to enable
///      webhook event delivery (using [webhookUrl]).
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

  /// Resolved at first use — may differ from [_connectionId] when the
  /// original value is a credential-connection ID.
  String? _resolvedId;
  bool _resolutionAttempted = false;

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
  // Connection-ID auto-resolution
  // -----------------------------------------------------------------------

  /// Returns the connection ID that the active-calls endpoint accepts.
  ///
  /// On the first call, tries the configured [_connectionId].  If the API
  /// returns 422 ("Invalid value for connection_id") we attempt:
  ///   1. Discover an existing Call Control Application on the account.
  ///   2. Patch the credential connection to add [webhookUrl], which
  ///      unlocks the active-calls endpoint for credential connections.
  Future<String> _effectiveConnectionId() async {
    if (_resolvedId != null) return _resolvedId!;
    if (_resolutionAttempted) return _connectionId;
    _resolutionAttempted = true;

    // Optimistic: try the configured ID first.
    final testResp = await http.get(
      Uri.parse('$_base/connections/$_connectionId/active_calls')
          .replace(queryParameters: {'page[size]': '1'}),
      headers: _headers,
    );
    if (testResp.statusCode >= 200 && testResp.statusCode < 300) {
      _resolvedId = _connectionId;
      debugPrint('[TelnyxConf] Connection ID $_connectionId accepted');
      return _resolvedId!;
    }

    debugPrint(
      '[TelnyxConf] Connection ID $_connectionId rejected '
      '(${testResp.statusCode}) — auto-resolving…',
    );

    // Strategy 1: look for an existing Call Control Application.
    try {
      final resp = await http.get(
        Uri.parse('$_base/call_control_applications')
            .replace(queryParameters: {'page[size]': '25'}),
        headers: _headers,
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final apps = body['data'] as List<dynamic>? ?? [];
        if (apps.isNotEmpty) {
          final app = apps.first as Map<String, dynamic>;
          final appId = app['id'] as String?;
          if (appId != null && appId.isNotEmpty) {
            _resolvedId = appId;
            debugPrint(
              '[TelnyxConf] Resolved Call Control App: '
              '$_resolvedId (${app['application_name']})',
            );
            return _resolvedId!;
          }
        }
      }
    } catch (e) {
      debugPrint('[TelnyxConf] Call Control App lookup failed: $e');
    }

    // Strategy 2: enable the credential connection for call-control
    // by setting webhook_event_url (the active-calls endpoint accepts
    // credential connections once they have a webhook URL).
    if (webhookUrl.isNotEmpty) {
      try {
        final resp = await http.patch(
          Uri.parse('$_base/credential_connections/$_connectionId'),
          headers: _headers,
          body: jsonEncode({
            'webhook_event_url': webhookUrl,
            'webhook_api_version': '2',
          }),
        );
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          _resolvedId = _connectionId;
          debugPrint(
            '[TelnyxConf] Enabled webhook on credential connection '
            '$_connectionId → active-calls now available',
          );
          return _resolvedId!;
        }
        debugPrint(
          '[TelnyxConf] Credential PATCH failed '
          '${resp.statusCode}: ${resp.body}',
        );
      } catch (e) {
        debugPrint('[TelnyxConf] Credential PATCH failed: $e');
      }
    }

    debugPrint('[TelnyxConf] Auto-resolution exhausted — using $_connectionId');
    return _connectionId;
  }

  // -----------------------------------------------------------------------
  // ConferenceProvider implementation
  // -----------------------------------------------------------------------

  @override
  Future<List<ActiveCallInfo>> lookupActiveCalls() async {
    final connId = await _effectiveConnectionId();
    final url = '$_base/connections/$connId/active_calls';
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

    // Credential connections omit from/to. Try enriching via detail endpoint.
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
        debugPrint(
          '[TelnyxConf]   enriched ${ac.callControlId}: '
          'from=$from to=$to created=$created keys=${data.keys.toList()}',
        );
        return ActiveCallInfo(
          callControlId: ac.callControlId,
          from: from,
          to: to,
          durationSeconds: ac.durationSeconds,
          createdAt: created,
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
