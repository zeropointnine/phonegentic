import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../db/call_history_db.dart';
import '../models/calendar_event.dart';
import 'chrome_browser_service.dart';
import 'google_calendar_config.dart';
import 'google_calendar_models.dart';

class GoogleCalendarService extends ChangeNotifier {
  static final _log = Logger();

  final ChromeBrowserService _chrome = ChromeBrowserService();
  ChromeBrowserService get chrome => _chrome;

  GoogleCalendarConfig _config = const GoogleCalendarConfig();
  GoogleCalendarConfig get config => _config;

  List<GCalEventInfo>? _lastEvents;
  List<GCalEventInfo>? get lastEvents => _lastEvents;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  bool? _connected;
  bool? get connected => _connected;

  // ── JS: scrape Google Calendar day view ──────────────────────────────

  static const _readEventsJs = r'''
() => {
  const events = [];
  // Day view renders events as [data-eventid] elements
  const items = document.querySelectorAll('[data-eventid]');
  for (const item of items) {
    const title = (item.querySelector('[data-eventchip]') || item)
      .getAttribute('aria-label') || item.textContent.trim();
    // Attempt to parse time from aria-label: "Event Title, 2:00 – 3:00pm"
    const timeMatch = title.match(/(\d{1,2}(?::\d{2})?\s*(?:AM|PM)?)\s*[–-]\s*(\d{1,2}(?::\d{2})?\s*(?:AM|PM)?)/i);
    const startTime = timeMatch ? timeMatch[1].trim() : '';
    const endTime = timeMatch ? timeMatch[2].trim() : '';
    const titleClean = title.replace(/,?\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)?\s*[–-]\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM)?/i, '').trim();
    events.push({
      title: titleClean,
      startTime,
      endTime,
      date: '',
      location: '',
      description: '',
      attendees: [],
    });
  }
  // Fallback: try the schedule/list view items
  if (events.length === 0) {
    const listItems = document.querySelectorAll('li[data-eventid], div[data-eventid]');
    for (const li of listItems) {
      events.push({
        title: li.textContent.trim().substring(0, 200),
        startTime: '', endTime: '', date: '', location: '',
        description: '', attendees: [],
      });
    }
  }
  return events;
}
''';

  // ── JS: confirm event creation page loaded ───────────────────────────

  static const _createEventJs = r'''
() => {
  // Google Calendar's event edit URL pre-fills fields. We need to click Save.
  const saveBtn = document.querySelector('[data-savechip]')
    || document.querySelector('button[aria-label="Save"]')
    || document.querySelector('#xSaveBu');
  // Fallback: find any button with text "Save"
  if (!saveBtn) {
    const buttons = [...document.querySelectorAll('button, div[role="button"]')];
    const save = buttons.find(b => /^\s*Save\s*$/i.test(b.textContent));
    if (save) { save.click(); return { success: true, error: null }; }
    return { success: false, error: 'Save button not found. Calendar may not have loaded.' };
  }
  saveBtn.click();
  return { success: true, error: null };
}
''';

  // ── Config ───────────────────────────────────────────────────────────

  Future<void> loadConfig() async {
    _config = await GoogleCalendarConfig.load();
    notifyListeners();
  }

  Future<void> updateConfig(GoogleCalendarConfig config) async {
    _config = config;
    await config.save();
    await _chrome.close();
    _connected = null;
    notifyListeners();
  }

  Future<void> copyLaunchCommand() async {
    await Clipboard.setData(ClipboardData(text: _chrome.launchCommand));
  }

  Future<bool> testConnection() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final ok = await _chrome.isDebugPortOpen();
      _connected = ok;
      _error = ok ? null : 'Chrome not found on port ${_chrome.debugPort}';
    } catch (e) {
      _connected = false;
      _error = e.toString().split('\n').first;
    } finally {
      _loading = false;
      notifyListeners();
    }
    return _connected ?? false;
  }

  // ── Create event ────────────────────────────────────────────────────

  Future<bool> createEvent({
    required String title,
    required String date,
    required String startTime,
    required String endTime,
    String? description,
    String? location,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // Build RFC format dates: YYYYMMDDTHHMMSS
      final startDt = _parseDateTime(date, startTime);
      final endDt = _parseDateTime(date, endTime);
      if (startDt == null || endDt == null) {
        _error = 'Could not parse date/time. Use YYYY-MM-DD and HH:MM formats.';
        _loading = false;
        notifyListeners();
        return false;
      }

      final startStr = _toCalendarFormat(startDt);
      final endStr = _toCalendarFormat(endDt);

      final params = <String>[
        'text=${Uri.encodeComponent(title)}',
        'dates=$startStr/$endStr',
      ];
      if (description != null && description.isNotEmpty) {
        params.add('details=${Uri.encodeComponent(description)}');
      }
      if (location != null && location.isNotEmpty) {
        params.add('location=${Uri.encodeComponent(location)}');
      }

      final url =
          'https://calendar.google.com/calendar/r/eventedit?${params.join('&')}';
      _log.i('Creating calendar event: $url');

      final raw = await _chrome.navigateAndEvaluate(
        url,
        _createEventJs,
        renderDelay: const Duration(seconds: 5),
      );
      final result = Map<String, dynamic>.from(raw as Map);

      final success = result['success'] as bool? ?? false;
      if (!success) {
        _error = result['error'] as String? ?? 'Failed to create event';
      }
      _connected = true;
      _log.i('Create event result: $result');
      return success;
    } catch (e, st) {
      _log.e('Event creation failed', error: e, stackTrace: st);
      _error = 'Create failed: ${e.toString().split('\n').first}';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Read events for a date ──────────────────────────────────────────

  Future<List<GCalEventInfo>> readEvents(String date) async {
    _loading = true;
    _error = null;
    _lastEvents = null;
    notifyListeners();

    try {
      final dt = DateTime.tryParse(date);
      if (dt == null) {
        _error = 'Invalid date format. Use YYYY-MM-DD.';
        _loading = false;
        notifyListeners();
        return [];
      }

      final url =
          'https://calendar.google.com/calendar/r/day/${dt.year}/${dt.month}/${dt.day}';
      _log.i('Reading calendar events: $url');

      final raw = await _chrome.navigateAndEvaluate<List<dynamic>>(
        url,
        _readEventsJs,
        renderDelay: const Duration(seconds: 5),
      );

      final events = raw
          .whereType<Map>()
          .map((m) => GCalEventInfo.fromMap({
                ...Map<String, dynamic>.from(m),
                'date': date,
              }))
          .toList();

      _lastEvents = events;
      _connected = true;
      _error = events.isEmpty ? 'No events found for $date' : null;
      _log.i('Read ${events.length} event(s) for $date');
      return events;
    } catch (e, st) {
      _log.e('Calendar read failed', error: e, stackTrace: st);
      _error = 'Read failed: ${e.toString().split('\n').first}';
      return [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Sync: push local events to Google Calendar ──────────────────────

  Future<int> syncToGoogle(List<CalendarEvent> localEvents) async {
    int created = 0;
    for (final event in localEvents) {
      final ok = await createEvent(
        title: event.title,
        date:
            '${event.startTime.year}-${event.startTime.month.toString().padLeft(2, '0')}-${event.startTime.day.toString().padLeft(2, '0')}',
        startTime:
            '${event.startTime.hour.toString().padLeft(2, '0')}:${event.startTime.minute.toString().padLeft(2, '0')}',
        endTime:
            '${event.endTime.hour.toString().padLeft(2, '0')}:${event.endTime.minute.toString().padLeft(2, '0')}',
        description: event.description,
        location: event.location,
      );
      if (ok) created++;
    }
    return created;
  }

  // ── Sync: pull Google Calendar events into local SQLite ─────────────

  Future<int> syncFromGoogle(DateTime start, DateTime end) async {
    int imported = 0;
    var current = start;
    while (!current.isAfter(end)) {
      final dateStr =
          '${current.year}-${current.month.toString().padLeft(2, '0')}-${current.day.toString().padLeft(2, '0')}';
      final events = await readEvents(dateStr);
      for (final ge in events) {
        if (ge.title.isEmpty) continue;
        final startDt = _parseDateTime(dateStr, ge.startTime) ?? current;
        final endDt =
            _parseDateTime(dateStr, ge.endTime) ?? startDt.add(const Duration(hours: 1));
        final local = CalendarEvent(
          title: ge.title,
          startTime: startDt,
          endTime: endDt,
          location: ge.location.isNotEmpty ? ge.location : null,
          description: ge.description.isNotEmpty ? ge.description : null,
          status: 'active',
          syncedAt: DateTime.now(),
        );
        await CallHistoryDb.upsertCalendarEvent(local);
        imported++;
      }
      current = current.add(const Duration(days: 1));
    }
    return imported;
  }

  // ── Bidirectional sync ──────────────────────────────────────────────

  Future<String> syncBidirectional() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 1));
      final end = now.add(const Duration(days: 14));

      // Pull from Google into local
      final imported = await syncFromGoogle(start, end);

      // Push local events to Google
      final localEvents = await CallHistoryDb.getEventsBetween(start, end);
      final pushed = await syncToGoogle(localEvents);

      _connected = true;
      final msg = 'Synced: pulled $imported from Google, pushed $pushed to Google.';
      _log.i(msg);
      return msg;
    } catch (e, st) {
      _log.e('Calendar sync failed', error: e, stackTrace: st);
      _error = 'Sync failed: ${e.toString().split('\n').first}';
      return 'Sync failed: ${e.toString().split('\n').first}';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  DateTime? _parseDateTime(String date, String time) {
    try {
      final dt = DateTime.tryParse(date);
      if (dt == null) return null;
      if (time.isEmpty) return dt;

      // Handle "2:30 PM" or "14:30" formats
      final cleaned = time.trim().toUpperCase();
      final amPm = cleaned.contains('PM')
          ? 'PM'
          : cleaned.contains('AM')
              ? 'AM'
              : null;
      final timePart = cleaned.replaceAll(RegExp(r'[APM\s]'), '');
      final parts = timePart.split(':');
      var hour = int.tryParse(parts[0]) ?? 0;
      final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

      if (amPm == 'PM' && hour < 12) hour += 12;
      if (amPm == 'AM' && hour == 12) hour = 0;

      return DateTime(dt.year, dt.month, dt.day, hour, minute);
    } catch (_) {
      return null;
    }
  }

  String _toCalendarFormat(DateTime dt) {
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y$m${d}T$h${min}00';
  }

  Future<void> shutdown() async {
    await _chrome.close();
  }

  @override
  void dispose() {
    _chrome.dispose();
    super.dispose();
  }
}
