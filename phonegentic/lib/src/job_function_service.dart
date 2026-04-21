import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db/call_history_db.dart';
import 'models/agent_context.dart';
import 'models/job_function.dart';

class JobFunctionService extends ChangeNotifier {
  static const _selectedIdKey = 'agent_job_function_id';

  List<JobFunction> _items = [];
  JobFunction? _selected;
  bool _editorOpen = false;
  JobFunction? _editing;

  List<JobFunction> get items => List.unmodifiable(_items);
  JobFunction? get selected => _selected;
  bool get isEditorOpen => _editorOpen;
  JobFunction? get editing => _editing;

  Future<void> loadAll() async {
    final rows = await CallHistoryDb.getAllJobFunctions();
    _items = rows.map((r) => JobFunction.fromMap(r)).toList();
    notifyListeners();
  }

  Future<void> restoreLastUsed() async {
    await loadAll();
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getInt(_selectedIdKey);

    if (savedId != null) {
      final match = _items.where((j) => j.id == savedId);
      if (match.isNotEmpty) {
        _selected = match.first;
        notifyListeners();
        return;
      }
    }

    if (_items.isNotEmpty) {
      _selected = _items.first;
      await _persistSelection();
      notifyListeners();
    }
  }

  Future<void> select(int id) async {
    final match = _items.where((j) => j.id == id);
    if (match.isEmpty) return;
    _selected = match.first;
    await _persistSelection();
    notifyListeners();
  }

  Future<void> save(JobFunction jf) async {
    if (jf.id != null) {
      final updated = jf.copyWith(updatedAt: DateTime.now());
      await CallHistoryDb.updateJobFunction(updated);
    } else {
      final newId = await CallHistoryDb.insertJobFunction(jf);
      if (_items.isEmpty) {
        await _persistSelectionId(newId);
      }
    }
    await loadAll();

    if (jf.id != null && _selected?.id == jf.id) {
      _selected = _items.firstWhere((j) => j.id == jf.id);
    } else if (jf.id == null && _items.isNotEmpty && _selected == null) {
      _selected = _items.last;
      await _persistSelection();
    }
    notifyListeners();
  }

  Future<bool> delete(int id) async {
    final count = await CallHistoryDb.jobFunctionCount();
    if (count <= 1) return false;

    await CallHistoryDb.deleteJobFunction(id);
    await loadAll();

    if (_selected?.id == id) {
      _selected = _items.isNotEmpty ? _items.first : null;
      await _persistSelection();
    }
    notifyListeners();
    return true;
  }

  AgentBootContext buildBootContext() {
    final jf = _selected;
    if (jf == null) return AgentBootContext.trivia();

    return AgentBootContext(
      name: jf.agentName,
      role: jf.role,
      jobFunction: jf.jobDescription,
      speakers: jf.speakers
          .map((s) => Speaker(role: s.role, source: s.source))
          .toList(),
      guardrails: jf.guardrails,
      textOnly: jf.whisperByDefault,
      elevenLabsVoiceId: jf.elevenLabsVoiceId,
      kokoroVoiceStyle: jf.kokoroVoiceStyle,
      pocketTtsVoiceId: jf.pocketTtsVoiceId,
      comfortNoisePath: jf.comfortNoisePath,
    );
  }

  void openEditor([JobFunction? existing]) {
    _editing = existing;
    _editorOpen = true;
    notifyListeners();
  }

  void closeEditor() {
    _editorOpen = false;
    _editing = null;
    notifyListeners();
  }

  Future<void> _persistSelection() async {
    if (_selected?.id != null) {
      await _persistSelectionId(_selected!.id!);
    }
  }

  Future<void> _persistSelectionId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_selectedIdKey, id);
  }
}
