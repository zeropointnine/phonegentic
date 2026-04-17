import 'package:flutter/foundation.dart';

import 'db/call_history_db.dart';

class CallSearchParams {
  final String? contactName;
  final int? minDurationSeconds;
  final int? maxDurationSeconds;
  final DateTime? since;
  final DateTime? before;
  final String? direction;
  final String? status;

  const CallSearchParams({
    this.contactName,
    this.minDurationSeconds,
    this.maxDurationSeconds,
    this.since,
    this.before,
    this.direction,
    this.status,
  });

  /// Parse a natural-language search query into structured params.
  ///
  /// Handles patterns like:
  ///   "calls with 585 in number"
  ///   "calls to Fred over 2 minutes"
  ///   "missed calls today"
  ///   "outbound calls last hour"
  ///   "calls longer than 5 minutes"
  factory CallSearchParams.fromQuery(String query) {
    final q = query.toLowerCase().trim();
    String? contactName;
    int? minDuration;
    int? maxDuration;
    DateTime? since;
    String? direction;
    String? status;

    // Strip filler words for parsing
    var working = q
        .replaceAll(RegExp(r'\bcalls?\b'), '')
        .replaceAll(RegExp(r'\bshow\s+me\b'), '')
        .replaceAll(RegExp(r'\bfind\b'), '')
        .replaceAll(RegExp(r'\ball\b'), '')
        .replaceAll(RegExp(r'\bthe\b'), '')
        .replaceAll(RegExp(r'\bmy\b'), '')
        .trim();

    // Direction
    if (RegExp(r'\b(outbound|outgoing|made|dialed)\b').hasMatch(working)) {
      direction = 'outbound';
      working = working
          .replaceAll(RegExp(r'\b(outbound|outgoing|made|dialed)\b'), '')
          .trim();
    } else if (RegExp(r'\b(inbound|incoming|received)\b').hasMatch(working)) {
      direction = 'inbound';
      working = working
          .replaceAll(RegExp(r'\b(inbound|incoming|received)\b'), '')
          .trim();
    }

    // Status
    if (RegExp(r'\bmissed\b').hasMatch(working)) {
      status = 'missed';
      working = working.replaceAll(RegExp(r'\bmissed\b'), '').trim();
    } else if (RegExp(r'\bfailed\b').hasMatch(working)) {
      status = 'failed';
      working = working.replaceAll(RegExp(r'\bfailed\b'), '').trim();
    } else if (RegExp(r'\bcompleted\b').hasMatch(working)) {
      status = 'completed';
      working = working.replaceAll(RegExp(r'\bcompleted\b'), '').trim();
    }

    // Time: "last N hour(s)/minute(s)/min"
    final timeMatch = RegExp(
            r'\b(?:in\s+)?(?:the\s+)?last\s+(\d+)\s*(hours?|minutes?|mins?|days?)\b')
        .firstMatch(working);
    if (timeMatch != null) {
      final n = int.parse(timeMatch.group(1)!);
      final unit = timeMatch.group(2)!;
      if (unit.startsWith('h')) {
        since = DateTime.now().subtract(Duration(hours: n));
      } else if (unit.startsWith('m')) {
        since = DateTime.now().subtract(Duration(minutes: n));
      } else if (unit.startsWith('d')) {
        since = DateTime.now().subtract(Duration(days: n));
      }
      working = working.replaceAll(timeMatch.group(0)!, '').trim();
    } else if (RegExp(r'\b(?:in\s+)?(?:the\s+)?last\s+hour\b')
        .hasMatch(working)) {
      since = DateTime.now().subtract(const Duration(hours: 1));
      working = working
          .replaceAll(
              RegExp(r'\b(?:in\s+)?(?:the\s+)?last\s+hour\b'), '')
          .trim();
    } else if (RegExp(r'\btoday\b').hasMatch(working)) {
      final now = DateTime.now();
      since = DateTime(now.year, now.month, now.day);
      working = working.replaceAll(RegExp(r'\btoday\b'), '').trim();
    } else if (RegExp(r'\byesterday\b').hasMatch(working)) {
      final now = DateTime.now();
      since = DateTime(now.year, now.month, now.day - 1);
      working = working.replaceAll(RegExp(r'\byesterday\b'), '').trim();
    } else if (RegExp(r'\b(?:this|last)\s+week\b').hasMatch(working)) {
      since = DateTime.now().subtract(const Duration(days: 7));
      working = working
          .replaceAll(RegExp(r'\b(?:this|last)\s+week\b'), '')
          .trim();
    }

    // Duration: "over/longer than/more than N min(utes)/sec(onds)"
    final durMatch = RegExp(
            r'\b(?:over|longer\s+than|more\s+than|>=?)\s*(\d+)\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\b')
        .firstMatch(working);
    if (durMatch != null) {
      final n = int.parse(durMatch.group(1)!);
      final unit = durMatch.group(2)!;
      if (unit.startsWith('h')) {
        minDuration = n * 3600;
      } else if (unit.startsWith('m')) {
        minDuration = n * 60;
      } else {
        minDuration = n;
      }
      working = working.replaceAll(durMatch.group(0)!, '').trim();
    }

    // Duration: "under/shorter than/less than N min"
    final durMaxMatch = RegExp(
            r'\b(?:under|shorter\s+than|less\s+than|<=?)\s*(\d+)\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\b')
        .firstMatch(working);
    if (durMaxMatch != null) {
      final n = int.parse(durMaxMatch.group(1)!);
      final unit = durMaxMatch.group(2)!;
      if (unit.startsWith('h')) {
        maxDuration = n * 3600;
      } else if (unit.startsWith('m')) {
        maxDuration = n * 60;
      } else {
        maxDuration = n;
      }
      working = working.replaceAll(durMaxMatch.group(0)!, '').trim();
    }

    // Whatever remains is the contact name / number search term.
    // Clean up filler prepositions and "in number"/"with number" etc.
    working = working
        .replaceAll(RegExp(r'\b(to|from|with|for|in|number|named?)\b'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    if (working.isNotEmpty) {
      contactName = working;
    }

    return CallSearchParams(
      contactName: contactName,
      minDurationSeconds: minDuration,
      maxDurationSeconds: maxDuration,
      since: since,
      direction: direction,
      status: status,
    );
  }
}

class CallHistoryService extends ChangeNotifier {
  int? _activeCallRecordId;
  final List<Map<String, dynamic>> _searchResults = [];
  bool _isOpen = false;
  String _searchQuery = '';
  bool _isLoading = false;
  int? _expandedCallId;

  List<Map<String, dynamic>> get searchResults =>
      List.unmodifiable(_searchResults);
  bool get isOpen => _isOpen;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  int? get activeCallRecordId => _activeCallRecordId;
  int? get expandedCallId => _expandedCallId;

  // ---------------------------------------------------------------------------
  // Call lifecycle — called by AgentService during active calls
  // ---------------------------------------------------------------------------

  Future<void> startCallRecord({
    required String direction,
    String? remoteIdentity,
    String? remoteDisplayName,
    String? localIdentity,
  }) async {
    if (_activeCallRecordId != null) return;
    try {
      _activeCallRecordId = await CallHistoryDb.insertCallRecord(
        direction: direction,
        remoteIdentity: remoteIdentity,
        remoteDisplayName: remoteDisplayName,
        localIdentity: localIdentity,
      );
      debugPrint('[CallHistory] Started record #$_activeCallRecordId');
    } catch (e) {
      debugPrint('[CallHistory] Failed to start record: $e');
    }
  }

  Future<void> setRecordingPath(String path) async {
    if (_activeCallRecordId == null) return;
    try {
      await CallHistoryDb.updateRecordingPath(_activeCallRecordId!, path);
      debugPrint('[CallHistory] Recording saved for #$_activeCallRecordId');
    } catch (e) {
      debugPrint('[CallHistory] Failed to save recording path: $e');
    }
  }

  Future<void> endCallRecord({required String status}) async {
    if (_activeCallRecordId == null) return;
    try {
      await CallHistoryDb.finalizeCallRecord(
        _activeCallRecordId!,
        status: status,
      );
      debugPrint(
          '[CallHistory] Finalized record #$_activeCallRecordId → $status');
    } catch (e) {
      debugPrint('[CallHistory] Failed to finalize record: $e');
    }
    _activeCallRecordId = null;
    // Refresh the displayed list so new/ended calls appear immediately.
    loadRecentCalls();
  }

  Future<void> addTranscript({
    required String role,
    String? speakerName,
    required String text,
  }) async {
    if (_activeCallRecordId == null) return;
    try {
      await CallHistoryDb.insertTranscript(
        callRecordId: _activeCallRecordId!,
        role: role,
        speakerName: speakerName,
        text: text,
      );
    } catch (e) {
      debugPrint('[CallHistory] Failed to add transcript: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // UI state
  // ---------------------------------------------------------------------------

  void openHistory({String? query}) {
    _isOpen = true;
    if (query != null) _searchQuery = query;
    notifyListeners();
    loadRecentCalls();
  }

  void closeHistory() {
    _isOpen = false;
    _expandedCallId = null;
    notifyListeners();
  }

  void toggleHistory() {
    if (_isOpen) {
      closeHistory();
    } else {
      openHistory();
    }
  }

  void toggleExpanded(int callId) {
    _expandedCallId = _expandedCallId == callId ? null : callId;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Parse a natural-language query and execute the structured search.
  Future<void> naturalSearch(String query) async {
    final params = CallSearchParams.fromQuery(query);
    await search(params);
  }

  Future<void> loadRecentCalls() async {
    _isLoading = true;
    notifyListeners();
    try {
      final results = await CallHistoryDb.getRecentCalls();
      _searchResults
        ..clear()
        ..addAll(results);
    } catch (e) {
      debugPrint('[CallHistory] Load failed: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> search(CallSearchParams params) async {
    _isLoading = true;
    notifyListeners();
    try {
      final results = await CallHistoryDb.searchCalls(
        contactName: params.contactName,
        minDurationSeconds: params.minDurationSeconds,
        maxDurationSeconds: params.maxDurationSeconds,
        since: params.since,
        before: params.before,
        direction: params.direction,
        status: params.status,
      );
      _searchResults
        ..clear()
        ..addAll(results);
    } catch (e) {
      debugPrint('[CallHistory] Search failed: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Execute a search and return a human-readable summary for the agent.
  Future<String> searchAndFormat(CallSearchParams params) async {
    await search(params);
    if (_searchResults.isEmpty) return 'No calls found matching your criteria.';

    final lines = _searchResults.take(10).map((r) {
      final name =
          r['remote_display_name'] ?? r['remote_identity'] ?? 'Unknown';
      final dir = r['direction'] ?? '';
      final dur = (r['duration_seconds'] ?? 0) as int;
      final mins = dur ~/ 60;
      final secs = dur % 60;
      final startedAt = r['started_at'] as String? ?? '';
      String timeStr = startedAt;
      try {
        final dt = DateTime.parse(startedAt).toLocal();
        final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
        final ampm = dt.hour >= 12 ? 'PM' : 'AM';
        timeStr =
            '${dt.month}/${dt.day} $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
      } catch (_) {}
      return '$name — $dir — ${mins}m ${secs}s — $timeStr';
    });

    return 'Found ${_searchResults.length} call(s):\n${lines.join('\n')}';
  }

  Future<List<Map<String, dynamic>>> getTranscripts(int callRecordId) {
    return CallHistoryDb.getTranscripts(callRecordId);
  }
}
