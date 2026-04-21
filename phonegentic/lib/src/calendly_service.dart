import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models/calendar_event.dart';

class CalendlyUser {
  final String uri;
  final String name;
  final String email;
  final String? schedulingUrl;

  const CalendlyUser({
    required this.uri,
    required this.name,
    required this.email,
    this.schedulingUrl,
  });
}

class CalendlyEventType {
  final String uri;
  final String name;
  final int durationMinutes;
  final String? schedulingUrl;

  const CalendlyEventType({
    required this.uri,
    required this.name,
    required this.durationMinutes,
    this.schedulingUrl,
  });
}

class CalendlyService {
  static const _baseUrl = 'https://api.calendly.com';

  final String _apiKey;

  CalendlyService(this._apiKey);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      };

  // ---------------------------------------------------------------------------
  // Connection test
  // ---------------------------------------------------------------------------

  /// Verify the token is valid and return the authenticated user.
  /// Returns null on auth failure; throws on network error.
  Future<CalendlyUser?> testConnection() async {
    debugPrint('[CalendlyService] Testing connection...');
    final resp = await http.get(
      Uri.parse('$_baseUrl/users/me'),
      headers: _headers,
    );
    debugPrint('[CalendlyService] /users/me → ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('[CalendlyService] Auth failed: ${resp.body}');
      return null;
    }
    final body = json.decode(resp.body) as Map<String, dynamic>;
    final r = body['resource'] as Map<String, dynamic>?;
    if (r == null) return null;
    final user = CalendlyUser(
      uri: r['uri'] as String? ?? '',
      name: r['name'] as String? ?? '',
      email: r['email'] as String? ?? '',
      schedulingUrl: r['scheduling_url'] as String?,
    );
    debugPrint('[CalendlyService] Authenticated: ${user.name} <${user.email}>');
    return user;
  }

  // ---------------------------------------------------------------------------
  // Read events
  // ---------------------------------------------------------------------------

  /// Fetch the current user URI (needed for event queries).
  Future<String?> getCurrentUserUri() async {
    try {
      debugPrint('[CalendlyService] GET /users/me  (key ${_apiKey.length} chars)');
      final resp = await http.get(
        Uri.parse('$_baseUrl/users/me'),
        headers: _headers,
      );
      debugPrint('[CalendlyService] /users/me → ${resp.statusCode}');
      if (resp.statusCode != 200) {
        debugPrint('[CalendlyService] /users/me body: ${resp.body}');
        return null;
      }
      final body = json.decode(resp.body) as Map<String, dynamic>;
      final resource = body['resource'] as Map<String, dynamic>?;
      final uri = resource?['uri'] as String?;
      debugPrint('[CalendlyService] Resolved user URI: $uri');
      return uri;
    } catch (e) {
      debugPrint('[CalendlyService] getCurrentUserUri error: $e');
      return null;
    }
  }

  /// Fetch scheduled events between [start] and [end].
  Future<List<CalendarEvent>> fetchEvents(DateTime start, DateTime end) async {
    try {
      final userUri = await getCurrentUserUri();
      if (userUri == null) {
        debugPrint('[CalendlyService] fetchEvents: could not resolve user URI '
            '(bad token or network?)');
        return [];
      }
      debugPrint('[CalendlyService] User URI: $userUri');

      final params = {
        'user': userUri,
        'min_start_time': start.toUtc().toIso8601String(),
        'max_start_time': end.toUtc().toIso8601String(),
        'sort': 'start_time:asc',
        'count': '100',
      };

      final uri = Uri.parse('$_baseUrl/scheduled_events')
          .replace(queryParameters: params);
      debugPrint('[CalendlyService] GET $uri');
      final resp = await http.get(uri, headers: _headers);
      debugPrint('[CalendlyService] Response: ${resp.statusCode}');
      if (resp.statusCode != 200) {
        debugPrint('[CalendlyService] fetchEvents body: ${resp.body}');
        return [];
      }

      final body = json.decode(resp.body) as Map<String, dynamic>;
      final pagination = body['pagination'] as Map<String, dynamic>?;
      debugPrint('[CalendlyService] Pagination: $pagination');
      final collection = body['collection'] as List<dynamic>? ?? [];
      debugPrint(
          '[CalendlyService] Parsed ${collection.length} event(s) from response');
      if (collection.isEmpty) {
        debugPrint('[CalendlyService] Full response body: ${resp.body}');
      }

      return collection.map((item) {
        final e = item as Map<String, dynamic>;
        final rawTitle = e['name'] as String? ?? 'Calendly Event';
        final invitee = _extractInviteeName(e);
        final title = invitee != null && !rawTitle.contains(invitee)
            ? '$rawTitle — $invitee'
            : rawTitle;
        return CalendarEvent(
          calendlyEventId: e['uri'] as String?,
          source: EventSource.calendly,
          title: title,
          description: _extractDescription(e),
          startTime: DateTime.parse(e['start_time'] as String),
          endTime: DateTime.parse(e['end_time'] as String),
          inviteeName: invitee,
          inviteeEmail: _extractInviteeEmail(e),
          eventType: e['event_type'] as String?,
          location: _extractLocation(e),
          status: 'active',
          syncedAt: DateTime.now(),
          createdAt: DateTime.tryParse(e['created_at'] as String? ?? ''),
        );
      }).toList();
    } catch (e, stack) {
      debugPrint('[CalendlyService] fetchEvents error: $e\n$stack');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Event types & availability (for Scheduling API)
  // ---------------------------------------------------------------------------

  /// List all event types for the authenticated user.
  Future<List<CalendlyEventType>> listEventTypes() async {
    try {
      final userUri = await getCurrentUserUri();
      if (userUri == null) return [];

      final uri = Uri.parse('$_baseUrl/event_types')
          .replace(queryParameters: {'user': userUri, 'active': 'true'});
      final resp = await http.get(uri, headers: _headers);
      if (resp.statusCode != 200) return [];

      final body = json.decode(resp.body) as Map<String, dynamic>;
      final collection = body['collection'] as List<dynamic>? ?? [];

      return collection.map((item) {
        final e = item as Map<String, dynamic>;
        return CalendlyEventType(
          uri: e['uri'] as String? ?? '',
          name: e['name'] as String? ?? '',
          durationMinutes: e['duration'] as int? ?? 30,
          schedulingUrl: e['scheduling_url'] as String?,
        );
      }).toList();
    } catch (e) {
      debugPrint('[CalendlyService] listEventTypes error: $e');
      return [];
    }
  }

  /// Get available time slots for an event type (max 7 days per request).
  Future<List<DateTime>> getAvailableTimes({
    required String eventTypeUri,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    try {
      final uri =
          Uri.parse('$_baseUrl/event_type_available_times').replace(
        queryParameters: {
          'event_type': eventTypeUri,
          'start_time': startTime.toUtc().toIso8601String(),
          'end_time': endTime.toUtc().toIso8601String(),
        },
      );
      final resp = await http.get(uri, headers: _headers);
      if (resp.statusCode != 200) return [];

      final body = json.decode(resp.body) as Map<String, dynamic>;
      final collection = body['collection'] as List<dynamic>? ?? [];

      return collection
          .map((item) {
            final e = item as Map<String, dynamic>;
            final status = e['status'] as String? ?? '';
            if (status != 'available') return null;
            return DateTime.tryParse(e['start_time'] as String? ?? '');
          })
          .where((d) => d != null)
          .cast<DateTime>()
          .toList();
    } catch (e) {
      debugPrint('[CalendlyService] getAvailableTimes error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Create events (Scheduling API -- POST /invitees)
  // ---------------------------------------------------------------------------

  /// Book a meeting directly via the Scheduling API.
  /// Requires a paid Calendly plan. Returns the scheduled event URI on success.
  Future<String?> createInvitee({
    required String eventTypeUri,
    required DateTime startTime,
    required String inviteeName,
    required String inviteeEmail,
    String timezone = 'America/New_York',
    String? locationKind,
    List<String>? eventGuests,
  }) async {
    try {
      final payload = <String, dynamic>{
        'event_type': eventTypeUri,
        'start_time': startTime.toUtc().toIso8601String(),
        'invitee': {
          'name': inviteeName,
          'email': inviteeEmail,
          'timezone': timezone,
        },
      };

      if (locationKind != null) {
        payload['location'] = {'kind': locationKind};
      }
      if (eventGuests != null && eventGuests.isNotEmpty) {
        payload['event_guests'] = eventGuests;
      }

      final resp = await http.post(
        Uri.parse('$_baseUrl/invitees'),
        headers: _headers,
        body: json.encode(payload),
      );

      if (resp.statusCode == 201) {
        final body = json.decode(resp.body) as Map<String, dynamic>;
        final resource = body['resource'] as Map<String, dynamic>?;
        return resource?['event'] as String?;
      }

      debugPrint(
          '[CalendlyService] createInvitee ${resp.statusCode}: ${resp.body}');
      return null;
    } catch (e) {
      debugPrint('[CalendlyService] createInvitee error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Cancel event
  // ---------------------------------------------------------------------------

  /// Cancel a scheduled event by its URI.
  /// The [eventUri] is the full Calendly event URI, e.g.
  /// `https://api.calendly.com/scheduled_events/<uuid>`.
  Future<bool> cancelEvent(String eventUri, {String? reason}) async {
    try {
      final uuid = Uri.parse(eventUri).pathSegments.last;
      final resp = await http.post(
        Uri.parse('$_baseUrl/scheduled_events/$uuid/cancellation'),
        headers: _headers,
        body: json.encode({
          if (reason != null) 'reason': reason,
        }),
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return true;
      }
      debugPrint(
          '[CalendlyService] cancelEvent ${resp.statusCode}: ${resp.body}');
      return false;
    } catch (e) {
      debugPrint('[CalendlyService] cancelEvent error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Scheduling links (legacy fallback)
  // ---------------------------------------------------------------------------

  /// Create a single-use scheduling link.
  Future<String?> createSchedulingLink({
    required String eventTypeUri,
    int maxEventCount = 1,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/scheduling_links'),
        headers: _headers,
        body: json.encode({
          'max_event_count': maxEventCount,
          'owner': eventTypeUri,
          'owner_type': 'EventType',
        }),
      );
      if (resp.statusCode == 201) {
        final body = json.decode(resp.body) as Map<String, dynamic>;
        final resource = body['resource'] as Map<String, dynamic>?;
        return resource?['booking_url'] as String?;
      }
      debugPrint(
          '[CalendlyService] createSchedulingLink ${resp.statusCode}: ${resp.body}');
      return null;
    } catch (e) {
      debugPrint('[CalendlyService] createSchedulingLink error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String? _extractLocation(Map<String, dynamic> event) {
    final loc = event['location'] as Map<String, dynamic>?;
    if (loc == null) return null;
    return loc['location'] as String? ?? loc['join_url'] as String?;
  }

  String? _extractInviteeName(Map<String, dynamic> event) {
    final guests = event['event_guests'] as List<dynamic>? ?? [];
    if (guests.isNotEmpty) {
      final first = guests.first as Map<String, dynamic>;
      final name = first['name'] as String?;
      if (name != null && name.isNotEmpty) return name;
    }
    final memberships = event['event_memberships'] as List<dynamic>? ?? [];
    if (memberships.isNotEmpty) {
      final first = memberships.first as Map<String, dynamic>;
      return first['user_name'] as String?;
    }
    return null;
  }

  String? _extractInviteeEmail(Map<String, dynamic> event) {
    final guests = event['event_guests'] as List<dynamic>? ?? [];
    if (guests.isNotEmpty) {
      final first = guests.first as Map<String, dynamic>;
      return first['email'] as String?;
    }
    return null;
  }

  String? _extractDescription(Map<String, dynamic> event) {
    final memberships =
        event['event_memberships'] as List<dynamic>? ?? [];
    if (memberships.isNotEmpty) {
      final first = memberships.first as Map<String, dynamic>;
      return first['user_name'] as String?;
    }
    return null;
  }
}
