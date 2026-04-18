import 'package:flutter/foundation.dart';

import 'db/call_history_db.dart';
import 'models/transfer_rule.dart';

class TransferRuleService extends ChangeNotifier {
  List<TransferRule> _items = [];

  List<TransferRule> get items => List.unmodifiable(_items);

  Future<void> loadAll() async {
    final rows = await CallHistoryDb.getAllTransferRules();
    _items = rows.map((r) => TransferRule.fromMap(r)).toList();
    notifyListeners();
  }

  Future<TransferRule> save(TransferRule rule) async {
    if (rule.id != null) {
      final updated = rule.copyWith(updatedAt: DateTime.now());
      await CallHistoryDb.updateTransferRule(updated);
      await loadAll();
      return _items.firstWhere((r) => r.id == rule.id, orElse: () => updated);
    } else {
      final newId = await CallHistoryDb.insertTransferRule(rule);
      await loadAll();
      return _items.firstWhere((r) => r.id == newId,
          orElse: () => rule.copyWith(id: newId));
    }
  }

  Future<void> delete(int id) async {
    await CallHistoryDb.deleteTransferRule(id);
    await loadAll();
  }

  /// Walk all enabled rules in order, return the first that matches
  /// [callerNumber], or null if none match.
  TransferRule? resolve(String callerNumber) {
    for (final rule in _items) {
      if (!rule.enabled) continue;
      if (rule.matches(callerNumber)) {
        debugPrint('[TransferRuleService] Matched rule="${rule.name}" '
            'for "$callerNumber" → ${rule.transferTarget}');
        return rule;
      }
    }
    return null;
  }
}
