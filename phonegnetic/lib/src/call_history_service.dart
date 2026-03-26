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
