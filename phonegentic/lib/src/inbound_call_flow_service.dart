import 'package:flutter/foundation.dart';

import 'db/call_history_db.dart';
import 'models/inbound_call_flow.dart';

class InboundCallFlowService extends ChangeNotifier {
  List<InboundCallFlow> _items = [];
  bool _editorOpen = false;
  InboundCallFlow? _editing;

  List<InboundCallFlow> get items => List.unmodifiable(_items);
  bool get isEditorOpen => _editorOpen;
  InboundCallFlow? get editing => _editing;

  /// True when at least one flow is enabled.
  bool get hasEnabledFlow => _items.any((f) => f.enabled);

  Future<void> loadAll() async {
    final rows = await CallHistoryDb.getAllInboundCallFlows();
    _items = rows.map((r) => InboundCallFlow.fromMap(r)).toList();
    notifyListeners();
  }

  Future<void> save(InboundCallFlow flow) async {
    if (flow.id != null) {
      final updated = flow.copyWith(updatedAt: DateTime.now());
      await CallHistoryDb.updateInboundCallFlow(updated);
    } else {
      await CallHistoryDb.insertInboundCallFlow(flow);
    }
    await loadAll();
  }

  Future<void> delete(int id) async {
    await CallHistoryDb.deleteInboundCallFlow(id);
    await loadAll();
  }

  Future<void> toggleEnabled(int id) async {
    final match = _items.where((f) => f.id == id);
    if (match.isEmpty) return;
    final flow = match.first;
    await save(flow.copyWith(enabled: !flow.enabled));
  }

  /// Walk all enabled flows in order, match rules top-to-bottom.
  /// Returns the job function ID for the first matching rule, or null.
  int? resolveJobFunctionId(String callerNumber) {
    for (final flow in _items) {
      if (!flow.enabled) continue;
      for (final rule in flow.rules) {
        if (rule.matches(callerNumber)) return rule.jobFunctionId;
      }
    }
    return null;
  }

  void openEditor([InboundCallFlow? existing]) {
    _editing = existing;
    _editorOpen = true;
    notifyListeners();
  }

  void closeEditor() {
    _editorOpen = false;
    _editing = null;
    notifyListeners();
  }
}
