import 'dart:async';

// ignore: unnecessary_import
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'agent_service.dart';
import 'db/call_history_db.dart';
import 'user_config_service.dart';

class ManagerPresenceService extends ChangeNotifier
    with WidgetsBindingObserver {
  static const _awayThreshold = Duration(minutes: 5);
  static const _reminderCheckInterval = Duration(minutes: 1);

  AgentService? _agent;
  Timer? _awayTimer;
  Timer? _reminderCheckTimer;
  final Map<int, Timer> _scheduledReminderTimers = {};

  bool _windowFocused = true;
  DateTime? _lastFocusedAt;
  DateTime? _lastUnfocusedAt;
  bool _isAway = false;
  bool _manuallyAway = false;
  AwayReturnMode _awayReturnMode = AwayReturnMode.quietBadge;
  DateTime? _lastBriefingAt;
  List<Map<String, dynamic>> _cachedPendingReminders = [];
  List<Map<String, dynamic>> _cachedUpcomingReminders = [];

  /// Structured call records from the most recent away period, shown in the
  /// agent panel banner until dismissed.
  List<Map<String, dynamic>> _awayCallRecords = [];
  int _awayMinutes = 0;

  bool get windowFocused => _windowFocused;
  bool get isAway => _isAway || _manuallyAway;
  bool get manuallyAway => _manuallyAway;
  DateTime? get lastFocusedAt => _lastFocusedAt;
  DateTime? get lastUnfocusedAt => _lastUnfocusedAt;
  AwayReturnMode get awayReturnMode => _awayReturnMode;
  DateTime? get lastBriefingAt => _lastBriefingAt;

  /// Pending reminders cached from the last periodic check (synchronous access).
  List<Map<String, dynamic>> get pendingReminders => _cachedPendingReminders;
  List<Map<String, dynamic>> get upcomingReminders => _cachedUpcomingReminders;

  /// Calls that occurred during the most recent away period.
  List<Map<String, dynamic>> get awayCallRecords => _awayCallRecords;
  int get awayMinutes => _awayMinutes;
  bool get hasAwayCallSummary => _awayCallRecords.isNotEmpty;

  void dismissAwayCallSummary() {
    _awayCallRecords = [];
    _awayMinutes = 0;
    notifyListeners();
  }

  Duration? get awayDuration {
    if (!_isAway || _lastUnfocusedAt == null) return null;
    return DateTime.now().difference(_lastUnfocusedAt!);
  }

  set agent(AgentService a) {
    _agent = a;
  }

  set awayReturnMode(AwayReturnMode mode) {
    _awayReturnMode = mode;
    UserConfigService.saveAwayReturnConfig(AwayReturnConfig(mode: mode));
    notifyListeners();
  }

  void setManuallyAway() {
    _manuallyAway = true;
    _awayTimer?.cancel();
    if (_lastUnfocusedAt == null) _lastUnfocusedAt = DateTime.now();
    debugPrint('[ManagerPresence] Manually set away');
    notifyListeners();
  }

  void clearManuallyAway() {
    final wasAway = isAway;
    _manuallyAway = false;
    _isAway = false;
    debugPrint('[ManagerPresence] Manually set available');
    if (wasAway) _handleReturnFromAway();
    notifyListeners();
  }

  bool _startupCheckDone = false;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _lastFocusedAt = DateTime.now();

    // Always create the periodic timer first so reminder checks run even if
    // subsequent DB/config operations fail.
    _reminderCheckTimer?.cancel();
    _reminderCheckTimer =
        Timer.periodic(_reminderCheckInterval, (_) => _checkReminders());

    try {
      final config = await UserConfigService.loadAwayReturnConfig();
      _awayReturnMode = config.mode;
    } catch (e) {
      debugPrint('[ManagerPresence] Error loading away config: $e');
    }

    try {
      await _refreshReminderCache();
      await _scheduleUpcomingTimers();
    } catch (e) {
      debugPrint('[ManagerPresence] Error on initial reminder setup: $e');
    }

    debugPrint('[ManagerPresence] Started – mode: ${_awayReturnMode.name}');

    if (!_startupCheckDone) {
      _startupCheckDone = true;
      Future.delayed(const Duration(seconds: 2), _checkMissedReminders);
    }
  }

  // ---------------------------------------------------------------------------
  // Focus tracking (WidgetsBindingObserver)
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasFocused = _windowFocused;
    _windowFocused = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;

    if (_windowFocused && !wasFocused) {
      _onFocusGained();
    } else if (!_windowFocused && wasFocused) {
      _onFocusLost();
    }
  }

  void _onFocusLost() {
    _lastUnfocusedAt = DateTime.now();
    _awayTimer?.cancel();
    _awayTimer = Timer(_awayThreshold, () {
      _isAway = true;
      debugPrint('[ManagerPresence] Manager is now away');
      notifyListeners();
    });
    notifyListeners();
  }

  void _onFocusGained() {
    _lastFocusedAt = DateTime.now();
    _awayTimer?.cancel();

    if (_isAway && !_manuallyAway) {
      _handleReturnFromAway();
    }

    _isAway = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Return-from-away flow
  // ---------------------------------------------------------------------------

  Future<void> _handleReturnFromAway() async {
    final awayMins = awayDuration?.inMinutes ?? 0;
    if (awayMins < 1) return;

    debugPrint(
        '[ManagerPresence] Manager returned after $awayMins min, mode: ${_awayReturnMode.name}');

    final since = _lastUnfocusedAt ?? DateTime.now();
    final calls = await CallHistoryDb.searchCalls(since: since);

    // Populate structured summary for the agent panel banner
    if (calls.isNotEmpty) {
      _awayCallRecords = calls;
      _awayMinutes = awayMins;
      notifyListeners();
    }

    final summary = await _buildAwayBriefing(awayMins, prefetchedCalls: calls);
    if (summary == null) return;

    _lastBriefingAt = DateTime.now();

    switch (_awayReturnMode) {
      case AwayReturnMode.quietBadge:
        _agent?.addReminderMessage(summary);
        break;
      case AwayReturnMode.proactiveGreeting:
        _agent?.sendSystemEvent(
          '[MANAGER RETURNED] $summary',
          requireResponse: true,
        );
        break;
    }
  }

  Future<String?> _buildAwayBriefing(
    int awayMinutes, {
    List<Map<String, dynamic>>? prefetchedCalls,
  }) async {
    final calls = prefetchedCalls ??
        await CallHistoryDb.searchCalls(
            since: _lastUnfocusedAt ?? DateTime.now());
    final firedReminders = await CallHistoryDb.getPendingReminders();

    if (calls.isEmpty && firedReminders.isEmpty) return null;

    final buf = StringBuffer();
    buf.write('You were away for $awayMinutes min.');

    if (calls.isNotEmpty) {
      final inbound = calls.where((c) => c['direction'] == 'inbound').length;
      final outbound = calls.length - inbound;
      buf.write(' ${calls.length} call(s)');
      if (inbound > 0 && outbound > 0) {
        buf.write(' ($inbound inbound, $outbound outbound)');
      } else if (inbound > 0) {
        buf.write(' (inbound)');
      } else {
        buf.write(' (outbound)');
      }

      final names = calls
          .map((c) =>
              c['remote_display_name'] as String? ??
              c['remote_identity'] as String? ??
              'Unknown')
          .toSet()
          .take(3);
      buf.write(' with ${names.join(', ')}');
      if (calls.length > 3) buf.write(' and others');
      buf.write('.');

      final withRecordings = calls.where((c) {
        final p = c['recording_path'] as String?;
        return p != null && p.isNotEmpty;
      }).length;
      if (withRecordings > 0) {
        buf.write(' $withRecordings recording(s) available.');
      }
    }

    if (firedReminders.isNotEmpty) {
      buf.write(
          ' ${firedReminders.length} reminder(s) fired while you were away.');
    }

    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Startup: missed-reminder triage
  // ---------------------------------------------------------------------------

  Future<void> _checkMissedReminders() async {
    final overdue = await CallHistoryDb.getPendingReminders();
    if (overdue.isEmpty) return;

    debugPrint(
        '[ManagerPresence] ${overdue.length} missed reminder(s) on startup');

    for (final row in overdue) {
      final id = row['id'] as int;
      final title = row['title'] as String? ?? 'Reminder';
      final desc = row['description'] as String?;
      final remindAt = DateTime.parse(row['remind_at'] as String).toLocal();
      final ago = DateTime.now().difference(remindAt);

      String timeAgo;
      if (ago.inDays > 0) {
        timeAgo = '${ago.inDays}d ago';
      } else if (ago.inHours > 0) {
        timeAgo = '${ago.inHours}h ago';
      } else {
        timeAgo = '${ago.inMinutes}m ago';
      }

      final text = desc != null && desc.isNotEmpty
          ? 'Missed ($timeAgo): $title — $desc'
          : 'Missed ($timeAgo): $title';

      _agent?.addMissedReminderMessage(text, reminderId: id);
    }

    await _refreshReminderCache();
  }

  // ---------------------------------------------------------------------------
  // Periodic reminder check
  // ---------------------------------------------------------------------------

  Future<void> _refreshReminderCache() async {
    _cachedPendingReminders = await CallHistoryDb.getAllReminders(limit: 50);
    _cachedPendingReminders =
        _cachedPendingReminders.where((r) => r['status'] == 'pending').toList();
    _cachedUpcomingReminders = await CallHistoryDb.getUpcomingReminders();
  }

  Future<void> _checkReminders() async {
    try {
      await _refreshReminderCache();
      final fired = await CallHistoryDb.getPendingReminders();
      if (fired.isNotEmpty) {
        debugPrint(
            '[ManagerPresence] _checkReminders: ${fired.length} past-due reminder(s)');
      }
      for (final row in fired) {
        await _fireReminder(row);
      }

      await _scheduleUpcomingTimers();
    } catch (e, st) {
      debugPrint('[ManagerPresence] _checkReminders error: $e\n$st');
    }
  }

  Future<void> _fireReminder(Map<String, dynamic> row) async {
    try {
      final id = row['id'] as int;
      final title = row['title'] as String? ?? 'Reminder';
      final desc = row['description'] as String?;

      _scheduledReminderTimers.remove(id)?.cancel();
      await CallHistoryDb.updateReminderStatus(id, 'fired');

      final source = row['source'] as String? ?? '';
      final remindAt =
          DateTime.tryParse(row['remind_at'] as String? ?? '')?.toLocal();
      final isCalendar = source == 'calendar';

      String? contactName;
      if (isCalendar && desc != null && desc.startsWith('Meeting with ')) {
        contactName = desc.substring('Meeting with '.length).trim();
      }

      final text = desc != null && desc.isNotEmpty ? '$title — $desc' : title;
      debugPrint(
          '[ManagerPresence] Firing reminder $id: "$text" (agent=${_agent != null})');

      _agent?.addReminderMessage(text,
          reminderId: id, contactName: contactName);

      String prompt;
      if (isCalendar && remindAt != null) {
        final eventTime = remindAt.add(const Duration(minutes: 15));
        final h = eventTime.hour > 12
            ? eventTime.hour - 12
            : (eventTime.hour == 0 ? 12 : eventTime.hour);
        final m = eventTime.minute.toString().padLeft(2, '0');
        final ap = eventTime.hour >= 12 ? 'PM' : 'AM';
        prompt = '[UPCOMING MEETING] $text at $h:$m $ap — '
            'Give the manager a brief, friendly heads-up that their meeting '
            'is coming up soon. Do NOT mention the word "reminder".';
      } else {
        prompt = '[REMINDER FIRED] $text — Please act on this reminder now.';
      }

      _agent?.sendSystemEvent(prompt, requireResponse: true);
    } catch (e, st) {
      debugPrint('[ManagerPresence] _fireReminder error: $e\n$st');
    }
  }

  /// Schedule precise timers for upcoming reminders so they fire on time
  /// even between polling intervals.
  Future<void> _scheduleUpcomingTimers() async {
    final upcoming = await CallHistoryDb.getUpcomingReminders();
    final scheduledIds = <int>{};

    for (final row in upcoming) {
      final id = row['id'] as int;
      scheduledIds.add(id);

      if (_scheduledReminderTimers.containsKey(id)) continue;

      final remindAt = DateTime.parse(row['remind_at'] as String).toLocal();
      var delay = remindAt.difference(DateTime.now());
      if (delay.isNegative) delay = Duration.zero;

      debugPrint(
          '[ManagerPresence] Scheduling timer for reminder $id in ${delay.inSeconds}s');

      _scheduledReminderTimers[id] = Timer(delay, () async {
        _scheduledReminderTimers.remove(id);
        final fresh = await CallHistoryDb.getReminderById(id);
        if (fresh != null && fresh['status'] == 'pending') {
          await _fireReminder(fresh);
          await _refreshReminderCache();
        }
      });
    }

    // Cancel timers for reminders that are no longer upcoming (cancelled/dismissed).
    _scheduledReminderTimers.keys
        .where((id) => !scheduledIds.contains(id))
        .toList()
        .forEach((id) {
      _scheduledReminderTimers.remove(id)?.cancel();
    });

    notifyListeners();
  }

  /// Called externally (e.g. after creating a reminder) to immediately
  /// refresh the cache, fire any already-due reminders, and schedule timers.
  Future<void> onReminderCreatedOrChanged() async {
    try {
      await _refreshReminderCache();

      final pastDue = await CallHistoryDb.getPendingReminders();
      for (final row in pastDue) {
        debugPrint(
            '[ManagerPresence] onReminderCreatedOrChanged: firing past-due reminder ${row['id']}');
        await _fireReminder(row);
      }

      await _scheduleUpcomingTimers();
      notifyListeners();
    } catch (e, st) {
      debugPrint('[ManagerPresence] onReminderCreatedOrChanged error: $e\n$st');
    }
  }

  void markBriefingDone() {
    _lastBriefingAt = DateTime.now();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _awayTimer?.cancel();
    _reminderCheckTimer?.cancel();
    for (final t in _scheduledReminderTimers.values) {
      t.cancel();
    }
    _scheduledReminderTimers.clear();
    super.dispose();
  }
}
