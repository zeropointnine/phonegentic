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
  final String? transcriptQuery;

  const CallSearchParams({
    this.contactName,
    this.minDurationSeconds,
    this.maxDurationSeconds,
    this.since,
    this.before,
    this.direction,
    this.status,
    this.transcriptQuery,
  });

  /// Parse a natural-language search query into structured params.
  ///
  /// Handles patterns like:
  ///   "calls with 585 in number"
  ///   "calls to Fred over 2 minutes"
  ///   "missed calls today"
  ///   "outbound calls last hour"
  ///   "calls longer than 5 minutes"
  ///   "calls a minute or longer"
  ///   "calls from yesterday till today"
  ///   "calls on April 15th"
  ///   "calls on 4/15"
  ///   "calls on Monday"
  ///   "calls last Friday"
  ///   "calls this month"
  ///   "calls from April 10 to April 15"
  ///   "calls where somebody said hello"
  factory CallSearchParams.fromQuery(String query) {
    final q = query.toLowerCase().trim();
    String? contactName;
    int? minDuration;
    int? maxDuration;
    DateTime? since;
    DateTime? before;
    String? direction;
    String? status;
    String? transcriptQuery;

    // Strip filler words for parsing
    var working = q
        .replaceAll(RegExp(r'\bcalls?\b'), '')
        .replaceAll(RegExp(r'\bshow\s+me\b'), '')
        .replaceAll(RegExp(r'\bfind\b'), '')
        .replaceAll(RegExp(r'\ball\b'), '')
        .replaceAll(RegExp(r'\bthe\b'), '')
        .replaceAll(RegExp(r'\bmy\b'), '')
        .trim();

    // Transcript content search: "where somebody/someone/they/caller said ..."
    // or "mentioning ..." / "about ..."
    final saidMatch = RegExp(
            r'\bwhere\s+(?:somebody|someone|they|the\s+caller|a\s+caller)\s+(?:said|mentioned|talked\s+about)\s+"?(.+?)"?\s*$')
        .firstMatch(working);
    if (saidMatch != null) {
      transcriptQuery = saidMatch.group(1)!.trim();
      working = working.replaceAll(saidMatch.group(0)!, '').trim();
    } else {
      final mentioningMatch =
          RegExp(r'\b(?:mentioning|about|containing)\s+"?(.+?)"?\s*$')
              .firstMatch(working);
      if (mentioningMatch != null) {
        transcriptQuery = mentioningMatch.group(1)!.trim();
        working =
            working.replaceAll(mentioningMatch.group(0)!, '').trim();
      }
    }

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

    // Date range: "from X to/till/until Y"
    final now = DateTime.now();
    final rangeMatch = RegExp(
            r'\b(?:from\s+)(\S+(?:\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s*\d{4})?)?)\s+(?:to|till|until|through)\s+(\S+(?:\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s*\d{4})?)?)\b')
        .firstMatch(working);
    if (rangeMatch != null) {
      final startDate = _tryParseDate(rangeMatch.group(1)!, now);
      final endDate = _tryParseDate(rangeMatch.group(2)!, now);
      if (startDate != null && endDate != null) {
        since = startDate;
        before =
            DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59);
        working = working.replaceAll(rangeMatch.group(0)!, '').trim();
      }
    }

    // Time / date expressions (only if range didn't already set since)
    if (since == null) {
      final timeMatch = RegExp(
              r'\b(?:in\s+)?(?:the\s+)?last\s+(\d+)\s*(hours?|minutes?|mins?|days?)\b')
          .firstMatch(working);
      if (timeMatch != null) {
        final n = int.parse(timeMatch.group(1)!);
        final unit = timeMatch.group(2)!;
        if (unit.startsWith('h')) {
          since = now.subtract(Duration(hours: n));
        } else if (unit.startsWith('m')) {
          since = now.subtract(Duration(minutes: n));
        } else if (unit.startsWith('d')) {
          since = now.subtract(Duration(days: n));
        }
        working = working.replaceAll(timeMatch.group(0)!, '').trim();
      } else if (RegExp(r'\b(?:in\s+)?(?:the\s+)?last\s+hour\b')
          .hasMatch(working)) {
        since = now.subtract(const Duration(hours: 1));
        working = working
            .replaceAll(
                RegExp(r'\b(?:in\s+)?(?:the\s+)?last\s+hour\b'), '')
            .trim();
      } else {
        // "on April 15", "on 4/15", "on Monday", "April 15th", "4/15/2026"
        final onDateMatch = RegExp(
                r'\b(?:on\s+)?(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\b')
            .firstMatch(working);
        // "on April 15th" / "April 15" / "on March 3rd, 2026"
        final namedDateMatch = RegExp(
                r'\b(?:on\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?\b')
            .firstMatch(working);
        // "on Monday", "last Tuesday", "this Wednesday"
        final dowMatch = RegExp(
                r'\b(?:on\s+|last\s+|this\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\b')
            .firstMatch(working);

        if (namedDateMatch != null) {
          final month = _parseMonth(namedDateMatch.group(1)!);
          final day = int.parse(namedDateMatch.group(2)!);
          final year = namedDateMatch.group(3) != null
              ? int.parse(namedDateMatch.group(3)!)
              : now.year;
          since = DateTime(year, month, day);
          before = DateTime(year, month, day, 23, 59, 59);
          working =
              working.replaceAll(namedDateMatch.group(0)!, '').trim();
        } else if (onDateMatch != null) {
          final parts = onDateMatch.group(1)!.split('/');
          final month = int.parse(parts[0]);
          final day = int.parse(parts[1]);
          final year = parts.length > 2 ? _parseYear(parts[2]) : now.year;
          since = DateTime(year, month, day);
          before = DateTime(year, month, day, 23, 59, 59);
          working = working.replaceAll(onDateMatch.group(0)!, '').trim();
        } else if (dowMatch != null) {
          final target = _parseDayOfWeek(dowMatch.group(1)!);
          final prefix = dowMatch.group(0)!.toLowerCase();
          final isThis = prefix.startsWith('this');
          var date = now;
          // Walk backwards to find the most recent matching weekday
          for (var i = isThis ? 0 : 1; i <= 7; i++) {
            final d = now.subtract(Duration(days: i));
            if (d.weekday == target) {
              date = d;
              break;
            }
          }
          since = DateTime(date.year, date.month, date.day);
          before = DateTime(date.year, date.month, date.day, 23, 59, 59);
          working = working.replaceAll(dowMatch.group(0)!, '').trim();
        } else if (RegExp(r'\btoday\b').hasMatch(working)) {
          since = DateTime(now.year, now.month, now.day);
          working = working.replaceAll(RegExp(r'\btoday\b'), '').trim();
        } else if (RegExp(r'\byesterday\b').hasMatch(working)) {
          since = DateTime(now.year, now.month, now.day - 1);
          working =
              working.replaceAll(RegExp(r'\byesterday\b'), '').trim();
        } else if (RegExp(r'\b(?:this|last)\s+month\b').hasMatch(working)) {
          final isLast =
              RegExp(r'\blast\s+month\b').hasMatch(working);
          if (isLast) {
            final prev = DateTime(now.year, now.month - 1);
            since = DateTime(prev.year, prev.month, 1);
            before = DateTime(now.year, now.month, 1)
                .subtract(const Duration(seconds: 1));
          } else {
            since = DateTime(now.year, now.month, 1);
          }
          working = working
              .replaceAll(RegExp(r'\b(?:this|last)\s+month\b'), '')
              .trim();
        } else if (RegExp(r'\b(?:this|last)\s+week\b').hasMatch(working)) {
          since = now.subtract(const Duration(days: 7));
          working = working
              .replaceAll(RegExp(r'\b(?:this|last)\s+week\b'), '')
              .trim();
        }
      }
    }

    // Duration: "over/longer than/more than N min(utes)/sec(onds)"
    // Also handles "a minute or longer", "an hour or more", etc.
    final durArticleMatch = RegExp(
            r'\b(?:over|longer\s+than|more\s+than|>=?|(?:at\s+least\s+)?)\s*(?:an?\s+)(minutes?|mins?|seconds?|secs?|hours?|hrs?)\s*(?:or\s+(?:longer|more))?\b')
        .firstMatch(working);
    final durMatch = RegExp(
            r'\b(?:over|longer\s+than|more\s+than|>=?)\s*(\d+)\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\b')
        .firstMatch(working);
    final durOrLongerMatch = RegExp(
            r'\b(\d+)\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\s+or\s+(?:longer|more)\b')
        .firstMatch(working);

    if (durArticleMatch != null && durMatch == null) {
      final unit = durArticleMatch.group(1)!;
      minDuration = _unitToSeconds(unit, 1);
      working = working.replaceAll(durArticleMatch.group(0)!, '').trim();
    } else if (durOrLongerMatch != null) {
      final n = int.parse(durOrLongerMatch.group(1)!);
      final unit = durOrLongerMatch.group(2)!;
      minDuration = _unitToSeconds(unit, n);
      working = working.replaceAll(durOrLongerMatch.group(0)!, '').trim();
    } else if (durMatch != null) {
      final n = int.parse(durMatch.group(1)!);
      final unit = durMatch.group(2)!;
      minDuration = _unitToSeconds(unit, n);
      working = working.replaceAll(durMatch.group(0)!, '').trim();
    }

    // Duration: "under/shorter than/less than N min"
    final durMaxMatch = RegExp(
            r'\b(?:under|shorter\s+than|less\s+than|<=?)\s*(\d+)\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)\b')
        .firstMatch(working);
    if (durMaxMatch != null) {
      final n = int.parse(durMaxMatch.group(1)!);
      final unit = durMaxMatch.group(2)!;
      maxDuration = _unitToSeconds(unit, n);
      working = working.replaceAll(durMaxMatch.group(0)!, '').trim();
    }

    // Whatever remains is the contact name / number search term.
    // Clean up filler prepositions and "in number"/"with number" etc.
    working = working
        .replaceAll(RegExp(r'\b(to|from|with|for|in|on|number|named?|that|are|or|longer|more|least|at|during)\b'), '')
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
      before: before,
      direction: direction,
      status: status,
      transcriptQuery: transcriptQuery,
    );
  }

  static int _unitToSeconds(String unit, int n) {
    if (unit.startsWith('h')) return n * 3600;
    if (unit.startsWith('m')) return n * 60;
    return n;
  }

  /// Try to parse a date token like "today", "yesterday", "monday",
  /// "april 15", "4/15", "4/15/2026".
  static DateTime? _tryParseDate(String token, DateTime now) {
    final t = token.trim().toLowerCase();
    if (t == 'today') return DateTime(now.year, now.month, now.day);
    if (t == 'yesterday') return DateTime(now.year, now.month, now.day - 1);

    // Day-of-week
    final dow = _tryParseDayOfWeek(t);
    if (dow != null) {
      for (var i = 0; i <= 7; i++) {
        final d = now.subtract(Duration(days: i));
        if (d.weekday == dow) return DateTime(d.year, d.month, d.day);
      }
    }

    // M/D or M/D/YYYY
    final slashMatch =
        RegExp(r'^(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?$').firstMatch(t);
    if (slashMatch != null) {
      final m = int.parse(slashMatch.group(1)!);
      final d = int.parse(slashMatch.group(2)!);
      final y = slashMatch.group(3) != null
          ? _parseYear(slashMatch.group(3)!)
          : now.year;
      return DateTime(y, m, d);
    }

    // "month day" e.g. "april 15" or "apr 15th"
    final namedMatch = RegExp(
            r'^(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?$')
        .firstMatch(t);
    if (namedMatch != null) {
      final m = _parseMonth(namedMatch.group(1)!);
      final d = int.parse(namedMatch.group(2)!);
      final y = namedMatch.group(3) != null
          ? int.parse(namedMatch.group(3)!)
          : now.year;
      return DateTime(y, m, d);
    }

    return null;
  }

  static int _parseMonth(String m) {
    const months = {
      'jan': 1, 'january': 1,
      'feb': 2, 'february': 2,
      'mar': 3, 'march': 3,
      'apr': 4, 'april': 4,
      'may': 5,
      'jun': 6, 'june': 6,
      'jul': 7, 'july': 7,
      'aug': 8, 'august': 8,
      'sep': 9, 'sept': 9, 'september': 9,
      'oct': 10, 'october': 10,
      'nov': 11, 'november': 11,
      'dec': 12, 'december': 12,
    };
    return months[m.toLowerCase()] ?? 1;
  }

  static int _parseYear(String y) {
    final n = int.parse(y);
    return n < 100 ? 2000 + n : n;
  }

  static int _parseDayOfWeek(String d) {
    return _tryParseDayOfWeek(d) ?? DateTime.monday;
  }

  static int? _tryParseDayOfWeek(String d) {
    const days = {
      'mon': 1, 'monday': 1,
      'tue': 2, 'tues': 2, 'tuesday': 2,
      'wed': 3, 'wednesday': 3,
      'thu': 4, 'thur': 4, 'thurs': 4, 'thursday': 4,
      'fri': 5, 'friday': 5,
      'sat': 6, 'saturday': 6,
      'sun': 7, 'sunday': 7,
    };
    return days[d.toLowerCase()];
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
    int? jobFunctionId,
  }) async {
    if (_activeCallRecordId != null) return;
    try {
      // Resolve contact by phone so the record is linked from the start.
      int? contactId;
      String? displayName = remoteDisplayName;
      if (remoteIdentity != null && remoteIdentity.isNotEmpty) {
        final contact =
            await CallHistoryDb.getContactByPhone(remoteIdentity);
        if (contact != null) {
          contactId = contact['id'] as int;
          final cName = contact['display_name'] as String? ?? '';
          if (cName.isNotEmpty) displayName = cName;
        }
      }
      _activeCallRecordId = await CallHistoryDb.insertCallRecord(
        direction: direction,
        remoteIdentity: remoteIdentity,
        remoteDisplayName: displayName,
        localIdentity: localIdentity,
        contactId: contactId,
        jobFunctionId: jobFunctionId,
      );
      debugPrint('[CallHistory] Started record #$_activeCallRecordId '
          '(jf=$jobFunctionId)');
    } catch (e) {
      debugPrint('[CallHistory] Failed to start record: $e');
    }
  }

  /// Update the active call's job_function_id — for mid-call persona
  /// switches triggered by transfer rules or calendar auto-switching.
  Future<void> updateActiveCallJobFunction(int? jobFunctionId) async {
    final id = _activeCallRecordId;
    if (id == null) return;
    try {
      await CallHistoryDb.updateCallJobFunction(id, jobFunctionId);
      debugPrint(
          '[CallHistory] Updated record #$id job_function_id=$jobFunctionId');
    } catch (e) {
      debugPrint('[CallHistory] Failed to update job_function_id: $e');
    }
  }

  /// Look up the most recent completed call with [remoteIdentity] that was
  /// handled by a specific persona (job function) within [since]. Used by
  /// AgentService to preserve persona continuity when the same remote party
  /// calls back after a recent outbound conversation.
  Future<Map<String, dynamic>?> findRecentCallWithPersona(
    String remoteIdentity, {
    Duration since = const Duration(hours: 2),
  }) async {
    try {
      return await CallHistoryDb.getMostRecentCallWithPersona(
        remoteIdentity,
        since: DateTime.now().subtract(since),
      );
    } catch (e) {
      debugPrint('[CallHistory] findRecentCallWithPersona failed: $e');
      return null;
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

  void openHistory({String? query, bool keepResults = false}) {
    _isOpen = true;
    if (query != null) _searchQuery = query;
    notifyListeners();
    if (keepResults) return;
    if (query != null && query.isNotEmpty) {
      naturalSearch(query);
    } else {
      loadRecentCalls();
    }
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

  /// Callback set by AgentService so we can escalate to AI without a
  /// circular dependency.
  void Function(String query)? onAgentSearch;

  /// Unified search: runs a local DB search first. If it finds results,
  /// displays them immediately. If not, falls through to the AI agent.
  Future<void> smartSearch(String query) async {
    if (query.trim().isEmpty) {
      await loadRecentCalls();
      return;
    }
    _searchQuery = query;
    await naturalSearch(query);
    if (_searchResults.isEmpty && onAgentSearch != null) {
      onAgentSearch!(query);
    }
  }

  Future<List<Map<String, String>>> getSuggestions(String prefix) {
    return CallHistoryDb.searchSuggestions(prefix);
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
      final List<Map<String, dynamic>> results;
      if (params.transcriptQuery != null) {
        results = await CallHistoryDb.searchCallsByTranscript(
          query: params.transcriptQuery!,
          contactName: params.contactName,
          minDurationSeconds: params.minDurationSeconds,
          maxDurationSeconds: params.maxDurationSeconds,
          since: params.since,
          before: params.before,
          direction: params.direction,
          status: params.status,
        );
      } else {
        results = await CallHistoryDb.searchCalls(
          contactName: params.contactName,
          minDurationSeconds: params.minDurationSeconds,
          maxDurationSeconds: params.maxDurationSeconds,
          since: params.since,
          before: params.before,
          direction: params.direction,
          status: params.status,
        );
      }
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
      final contactName = r['contact_name'] as String? ?? '';
      final name = contactName.isNotEmpty
          ? contactName
          : (r['remote_display_name'] ?? r['remote_identity'] ?? 'Unknown');
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
