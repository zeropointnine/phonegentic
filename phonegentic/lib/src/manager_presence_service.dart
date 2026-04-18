import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'agent_service.dart';
import 'db/call_history_db.dart';
import 'user_config_service.dart';

class ManagerPresenceService extends ChangeNotifier
    with WidgetsBindingObserver {
  static const _awayThreshold = Duration(minutes: 5);
  static const _reminderCheckInterval = Duration(minutes: 5);

  AgentService? _agent;
  Timer? _awayTimer;
  Timer? _reminderCheckTimer;

  bool _windowFocused = true;
  DateTime? _lastFocusedAt;
  DateTime? _lastUnfocusedAt;
  bool _isAway = false;
  AwayReturnMode _awayReturnMode = AwayReturnMode.quietBadge;
  DateTime? _lastBriefingAt;
  List<Map<String, dynamic>> _cachedPendingReminders = [];
  List<Map<String, dynamic>> _cachedUpcomingReminders = [];

  bool get windowFocused => _windowFocused;
  bool get isAway => _isAway;
  DateTime? get lastFocusedAt => _lastFocusedAt;
  DateTime? get lastUnfocusedAt => _lastUnfocusedAt;
  AwayReturnMode get awayReturnMode => _awayReturnMode;
  DateTime? get lastBriefingAt => _lastBriefingAt;

  /// Pending reminders cached from the last periodic check (synchronous access).
  List<Map<String, dynamic>> get pendingReminders => _cachedPendingReminders;
  List<Map<String, dynamic>> get upcomingReminders => _cachedUpcomingReminders;

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

  bool _startupCheckDone = false;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _lastFocusedAt = DateTime.now();
    final config = await UserConfigService.loadAwayReturnConfig();
    _awayReturnMode = config.mode;
    _reminderCheckTimer?.cancel();
    _reminderCheckTimer =
        Timer.periodic(_reminderCheckInterval, (_) => _checkReminders());
    await _refreshReminderCache();
    debugPrint('[ManagerPresence] Started – mode: ${_awayReturnMode.name}');

    if (!_startupCheckDone) {
      _startupCheckDone = true;
      // Delay so the agent service and UI are fully wired before we push messages.
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

    if (_isAway) {
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

    final summary = await _buildAwayBriefing(awayMins);
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

  Future<String?> _buildAwayBriefing(int awayMinutes) async {
    final since = _lastUnfocusedAt ?? DateTime.now();
    final calls = await CallHistoryDb.searchCalls(since: since);
    final firedReminders = await CallHistoryDb.getPendingReminders();

    if (calls.isEmpty && firedReminders.isEmpty) return null;

    final buf = StringBuffer();
    buf.write('You were away for $awayMinutes min.');

    if (calls.isNotEmpty) {
      final inbound =
          calls.where((c) => c['direction'] == 'inbound').length;
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

      final withRecordings =
          calls.where((c) {
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
    _cachedPendingReminders = _cachedPendingReminders
        .where((r) => r['status'] == 'pending')
        .toList();
    _cachedUpcomingReminders = await CallHistoryDb.getUpcomingReminders();
  }

  Future<void> _checkReminders() async {
    await _refreshReminderCache();
    final fired = await CallHistoryDb.getPendingReminders();
    for (final row in fired) {
      final id = row['id'] as int;
      final title = row['title'] as String? ?? 'Reminder';
      final desc = row['description'] as String?;

      await CallHistoryDb.updateReminderStatus(id, 'fired');

      final text = desc != null && desc.isNotEmpty
          ? '$title — $desc'
          : title;

      _agent?.addReminderMessage(text, reminderId: id);

      _agent?.sendSystemEvent(
        '[REMINDER FIRED] $text',
      );
    }

    final upcoming = await CallHistoryDb.getUpcomingReminders();
    if (upcoming.isNotEmpty && _agent != null) {
      final buf = StringBuffer('[UPCOMING REMINDERS] ');
      for (final row in upcoming) {
        final title = row['title'] as String? ?? 'Reminder';
        final remindAt = DateTime.parse(row['remind_at'] as String).toLocal();
        final mins = remindAt.difference(DateTime.now()).inMinutes;
        buf.write('"$title" in $mins min. ');
      }
      _agent!.sendSystemEvent(buf.toString());
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
    super.dispose();
  }
}
