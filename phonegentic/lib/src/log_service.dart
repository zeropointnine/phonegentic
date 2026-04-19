import 'dart:collection';

class LogEntry {
  final DateTime timestamp;
  final String message;

  const LogEntry(this.timestamp, this.message);

  String formatted() {
    final t = timestamp.toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    return '[$t] $message';
  }
}

/// In-memory ring buffer that captures all debugPrint output so the agent
/// can query recent logs and attach excerpts to GitHub issues.
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  static const int capacity = 2000;

  final Queue<LogEntry> _buffer = Queue<LogEntry>();

  void add(String message) {
    if (_buffer.length >= capacity) _buffer.removeFirst();
    _buffer.add(LogEntry(DateTime.now(), message));
  }

  /// Most recent [count] entries (newest last).
  List<LogEntry> recent({int count = 200}) {
    if (count >= _buffer.length) return _buffer.toList();
    return _buffer.toList().sublist(_buffer.length - count);
  }

  /// Entries whose message contains [query] (case-insensitive).
  List<LogEntry> search(String query, {int count = 100}) {
    final lower = query.toLowerCase();
    final matches = _buffer.where((e) => e.message.toLowerCase().contains(lower));
    final list = matches.toList();
    if (list.length <= count) return list;
    return list.sublist(list.length - count);
  }

  /// Entries after [time].
  List<LogEntry> since(DateTime time) {
    return _buffer.where((e) => e.timestamp.isAfter(time)).toList();
  }

  /// Format a list of entries for tool output.
  static String formatted(List<LogEntry> entries) {
    if (entries.isEmpty) return '(no log entries)';
    return entries.map((e) => e.formatted()).join('\n');
  }
}
