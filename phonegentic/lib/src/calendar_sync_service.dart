import 'dart:async';

import 'package:flutter/foundation.dart';

import 'calendly_service.dart';
import 'db/call_history_db.dart';
import 'job_function_service.dart';
import 'models/calendar_event.dart';
import 'user_config_service.dart';

enum ReminderLevel { none, upcoming, imminent, active }

class CalendarSyncService extends ChangeNotifier {
  static const _pollInterval = Duration(minutes: 2);
  static const _tickInterval = Duration(seconds: 30);

  JobFunctionService? _jobFunctionService;
  CalendlyService? _calendlyService;
  Timer? _pollTimer;
  Timer? _tickTimer;

  CalendarEvent? _nextEvent;
  ReminderLevel _reminderLevel = ReminderLevel.none;
  bool _isOpen = false;
  List<CalendarEvent> _events = [];
  int? _previousJobFunctionId;
  bool _jobFunctionSwitched = false;
  String? _lastSwitchMessage;

  CalendarEvent? get nextEvent => _nextEvent;
  ReminderLevel get reminderLevel => _reminderLevel;
  bool get isOpen => _isOpen;
  List<CalendarEvent> get events => List.unmodifiable(_events);
  String? get lastSwitchMessage => _lastSwitchMessage;
  bool get hasCalendly => _calendlyService != null;
  CalendlyService? get calendlyService => _calendlyService;

  set jobFunctionService(JobFunctionService jf) {
    _jobFunctionService = jf;
  }

  void toggleOpen() {
    _isOpen = !_isOpen;
    notifyListeners();
  }

  void close() {
    _isOpen = false;
    notifyListeners();
  }

  /// Call once after the service is wired up to start syncing.
  Future<void> start() async {
    debugPrint('[CalendarSync] Starting...');
    await _refreshApiKey();
    await syncNow();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => syncNow());
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_tickInterval, (_) => _updateReminders());
  }

  Future<void> _refreshApiKey() async {
    final config = await UserConfigService.loadCalendlyConfig();
    if (config.apiKey.isNotEmpty) {
      _calendlyService = CalendlyService(config.apiKey);
      debugPrint(
          '[CalendarSync] API key loaded (${config.apiKey.length} chars)');
    } else {
      _calendlyService = null;
      debugPrint('[CalendarSync] No API key configured');
    }
  }

  /// Force a sync right now (e.g. after saving a new API key).
  Future<void> syncNow() async {
    await _refreshApiKey();
    if (_calendlyService != null) {
      debugPrint('[CalendarSync] Fetching events from Calendly...');
      await _fetchAndStore();
    } else {
      debugPrint('[CalendarSync] Skipping fetch – no API key');
    }
    await _loadFromDb();
    _updateReminders();
  }

  Future<void> _fetchAndStore() async {
    if (_calendlyService == null) return;
    try {
      final now = DateTime.now().toUtc();
      final start = now.subtract(const Duration(days: 7));
      final end = now.add(const Duration(days: 30));
      debugPrint(
          '[CalendarSync] Query window (UTC): ${start.toIso8601String()} → ${end.toIso8601String()}');
      final remote = await _calendlyService!.fetchEvents(start, end);
      debugPrint('[CalendarSync] Calendly returned ${remote.length} event(s)');
      for (final event in remote) {
        debugPrint(
            '[CalendarSync]   → "${event.title}" at ${event.startTime} '
            '(local: ${event.startTime.toLocal()})');
        await CallHistoryDb.upsertCalendarEvent(event);
      }
    } catch (e, stack) {
      debugPrint('[CalendarSync] sync error: $e\n$stack');
    }
  }

  Future<void> _loadFromDb() async {
    _events = await CallHistoryDb.getUpcomingEvents(limit: 100);
    debugPrint('[CalendarSync] ${_events.length} upcoming event(s) in DB');
    notifyListeners();
  }

  void _updateReminders() {
    final now = DateTime.now();
    _lastSwitchMessage = null;

    CalendarEvent? next;
    for (final event in _events) {
      if (event.endTime.isAfter(now)) {
        next = event;
        break;
      }
    }
    _nextEvent = next;

    if (next == null) {
      if (_reminderLevel != ReminderLevel.none) {
        _revertJobFunction();
        _reminderLevel = ReminderLevel.none;
      }
      notifyListeners();
      return;
    }

    final minutesUntil = next.startTime.difference(now).inMinutes;
    final secondsUntil = next.startTime.difference(now).inSeconds;

    ReminderLevel newLevel;
    if (secondsUntil <= 0 && next.endTime.isAfter(now)) {
      newLevel = ReminderLevel.active;
    } else if (minutesUntil <= 15) {
      newLevel = ReminderLevel.imminent;
    } else if (minutesUntil <= 60) {
      newLevel = ReminderLevel.upcoming;
    } else {
      newLevel = ReminderLevel.none;
    }

    if (newLevel == ReminderLevel.active && !_jobFunctionSwitched) {
      _switchJobFunction(next);
    }

    if (newLevel != ReminderLevel.active && _jobFunctionSwitched) {
      _revertJobFunction();
    }

    _reminderLevel = newLevel;
    notifyListeners();
  }

  void _switchJobFunction(CalendarEvent event) {
    if (event.jobFunctionId == null || _jobFunctionService == null) return;
    _previousJobFunctionId = _jobFunctionService!.selected?.id;
    _jobFunctionService!.select(event.jobFunctionId!);
    _jobFunctionSwitched = true;
    final jfMatches = _jobFunctionService!.items
        .where((j) => j.id == event.jobFunctionId)
        .map((j) => j.title);
    final jfName = jfMatches.isNotEmpty ? jfMatches.first : null;
    _lastSwitchMessage =
        "Switched to '${jfName ?? 'job function'}' for: ${event.title}";
  }

  void _revertJobFunction() {
    if (!_jobFunctionSwitched || _jobFunctionService == null) return;
    if (_previousJobFunctionId != null) {
      _jobFunctionService!.select(_previousJobFunctionId!);
    }
    _jobFunctionSwitched = false;
    _previousJobFunctionId = null;
  }

  /// Minutes until the next event starts (negative if already started).
  int? get minutesUntilNext {
    if (_nextEvent == null) return null;
    return _nextEvent!.startTime.difference(DateTime.now()).inMinutes;
  }

  Future<void> loadEvents() async {
    await _loadFromDb();
  }

  Future<List<CalendarEvent>> getEventsForRange(
      DateTime start, DateTime end) async {
    return CallHistoryDb.getEventsBetween(start, end);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }
}
