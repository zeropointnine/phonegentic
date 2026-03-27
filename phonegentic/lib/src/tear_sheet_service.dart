import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart';

import 'agent_service.dart';
import 'call_history_service.dart';
import 'db/call_history_db.dart';

class TearSheetService extends ChangeNotifier {
  AgentService? agentService;
  CallHistoryService? callHistory;
  SIPUAHelper? sipHelper;

  int? _activeTearSheetId;
  List<Map<String, dynamic>> _items = [];
  int _currentIndex = -1;
  bool _isPaused = true;
  bool _isEditorOpen = false;

  /// Delay between calls (lets the agent report the outcome first).
  static const _interCallDelayMs = 3000;
  Timer? _advanceTimer;

  int? get activeTearSheetId => _activeTearSheetId;
  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  int get currentIndex => _currentIndex;
  bool get isPaused => _isPaused;
  bool get isActive => _activeTearSheetId != null;
  bool get isEditorOpen => _isEditorOpen;

  Map<String, dynamic>? get currentItem =>
      _currentIndex >= 0 && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  int get pendingCount =>
      _items.where((i) => i['status'] == 'pending').length;

  int get doneCount =>
      _items.where((i) => i['status'] == 'done').length;

  // ---------------------------------------------------------------------------
  // Creation
  // ---------------------------------------------------------------------------

  Future<void> createFromNumbers(List<String> numbers,
      {String name = 'Tear Sheet'}) async {
    if (numbers.isEmpty) return;

    final sheetId = await CallHistoryDb.insertTearSheet(name: name);
    for (int i = 0; i < numbers.length; i++) {
      final raw = numbers[i].trim();
      if (raw.isEmpty) continue;
      await CallHistoryDb.insertTearSheetItem(
        tearSheetId: sheetId,
        position: i,
        phoneNumber: raw,
      );
    }
    await _loadSheet(sheetId);
  }

  /// Create a tear sheet from call history search results. Extracts
  /// `remote_identity` and `remote_display_name` from each record.
  Future<void> createFromSearchResults(
      List<Map<String, dynamic>> results,
      {String name = 'From Search'}) async {
    if (results.isEmpty) return;

    // Deduplicate by remote_identity
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final r in results) {
      final id = r['remote_identity'] as String? ?? '';
      if (id.isNotEmpty && seen.add(id)) unique.add(r);
    }
    if (unique.isEmpty) return;

    final sheetId = await CallHistoryDb.insertTearSheet(name: name);
    for (int i = 0; i < unique.length; i++) {
      final r = unique[i];
      await CallHistoryDb.insertTearSheetItem(
        tearSheetId: sheetId,
        position: i,
        phoneNumber: r['remote_identity'] as String? ?? '',
        contactName: r['remote_display_name'] as String?,
      );
    }
    await _loadSheet(sheetId);
  }

  Future<void> loadSheetById(int sheetId) => _loadSheet(sheetId);

  Future<void> _loadSheet(int sheetId) async {
    _activeTearSheetId = sheetId;
    _items = await CallHistoryDb.getTearSheetItems(sheetId);
    _currentIndex = _items.indexWhere((i) => i['status'] == 'pending');
    if (_currentIndex < 0) _currentIndex = 0;
    _isPaused = true;
    notifyListeners();

    _sendTearSheetContext();
  }

  // ---------------------------------------------------------------------------
  // Playback controls
  // ---------------------------------------------------------------------------

  void play() {
    if (!isActive) return;
    _isPaused = false;
    notifyListeners();
    _dialCurrent();
  }

  void pause() {
    _isPaused = true;
    _advanceTimer?.cancel();
    notifyListeners();
    _sendPausedContext();
  }

  void skip() {
    if (!isActive || _currentIndex < 0) return;
    _markCurrentItem('skipped');
    _advanceToNext();
  }

  Future<void> removeItem(int itemId) async {
    await CallHistoryDb.deleteTearSheetItem(itemId);
    await _reloadItems();
    notifyListeners();
  }

  Future<void> moveUp(int itemId) async {
    final idx = _items.indexWhere((i) => i['id'] == itemId);
    if (idx <= 0) return;
    final prevId = _items[idx - 1]['id'] as int;
    final prevPos = _items[idx - 1]['position'] as int;
    final curPos = _items[idx]['position'] as int;
    await CallHistoryDb.reorderTearSheetItem(itemId, prevPos);
    await CallHistoryDb.reorderTearSheetItem(prevId, curPos);
    await _reloadItems();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Call lifecycle
  // ---------------------------------------------------------------------------

  void onCallEnded(String status) {
    if (!isActive || _isPaused) return;

    final flagStatuses = ['failed', 'missed'];
    final itemStatus = flagStatuses.contains(status) ? 'flagged' : 'done';
    _markCurrentItem(itemStatus);

    _advanceTimer?.cancel();
    _advanceTimer = Timer(
      const Duration(milliseconds: _interCallDelayMs),
      _advanceToNext,
    );
  }

  void _advanceToNext() {
    _advanceTimer?.cancel();
    if (!isActive) return;

    final nextIdx = _items.indexWhere(
      (i) => i['status'] == 'pending',
      _currentIndex + 1,
    );

    if (nextIdx < 0) {
      // Wrap search from beginning
      final wrapIdx = _items.indexWhere((i) => i['status'] == 'pending');
      if (wrapIdx < 0) {
        _onSheetComplete();
        return;
      }
      _currentIndex = wrapIdx;
    } else {
      _currentIndex = nextIdx;
    }

    notifyListeners();

    if (!_isPaused) {
      _dialCurrent();
    }
  }

  void _dialCurrent() {
    final item = currentItem;
    if (item == null) return;

    final number = item['phone_number'] as String? ?? '';
    if (number.isEmpty) {
      _markCurrentItem('flagged');
      _advanceToNext();
      return;
    }

    _markCurrentItem('calling');
    _sendCallingContext(item);

    // Dial via SIP
    _placeCall(number);
  }

  Future<void> _placeCall(String number) async {
    final helper = sipHelper ?? agentService?.sipHelper;
    if (helper == null) {
      debugPrint('[TearSheetService] No SIP helper available');
      return;
    }
    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };
      final stream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      helper.call(number, voiceOnly: true, mediaStream: stream);
    } catch (e) {
      debugPrint('[TearSheetService] Call failed: $e');
      _markCurrentItem('flagged');
      _advanceToNext();
    }
  }

  void _onSheetComplete() {
    _isPaused = true;
    if (_activeTearSheetId != null) {
      CallHistoryDb.updateTearSheetStatus(_activeTearSheetId!, 'completed');
    }
    notifyListeners();

    agentService?.whisper.sendSystemContext(
      '[TEAR_SHEET] All calls in the tear sheet are complete. '
      'Announce: "The tear sheet is finished — all calls have been made."',
    );
  }

  void _markCurrentItem(String status) {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return;
    final itemId = _items[_currentIndex]['id'] as int;
    CallHistoryDb.updateTearSheetItemStatus(itemId, status,
        callRecordId: callHistory?.activeCallRecordId);
    _items[_currentIndex] = Map<String, dynamic>.from(_items[_currentIndex])
      ..['status'] = status;
    notifyListeners();
  }

  Future<void> _reloadItems() async {
    if (_activeTearSheetId == null) return;
    _items = await CallHistoryDb.getTearSheetItems(_activeTearSheetId!);
    if (_currentIndex >= _items.length) {
      _currentIndex = _items.length - 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Agent context injection
  // ---------------------------------------------------------------------------

  void _sendTearSheetContext() {
    agentService?.whisper.sendSystemContext(
      '[TEAR_SHEET] Tear Sheet mode is now active. You will be calling through '
      'a queue of ${_items.length} numbers sequentially. Work through them '
      'efficiently. Do not change the order unless the host says otherwise. '
      'Announce each new call minimally: "Calling [name/number] now." '
      'Report outcomes briefly after each call before moving to the next.',
    );
  }

  void _sendCallingContext(Map<String, dynamic> item) {
    final name = item['contact_name'] as String? ?? '';
    final number = item['phone_number'] as String? ?? '';
    final label = name.isNotEmpty ? '$name ($number)' : number;
    agentService?.whisper.sendSystemContext(
      '[TEAR_SHEET] Now calling $label — item ${_currentIndex + 1} of ${_items.length}.',
    );
  }

  void _sendPausedContext() {
    final item = currentItem;
    final label = item != null
        ? (item['contact_name'] as String? ?? item['phone_number'] as String? ?? 'unknown')
        : 'unknown';
    agentService?.whisper.sendSystemContext(
      '[TEAR_SHEET] Paused after $label. Ready when the host presses play.',
    );
  }

  // ---------------------------------------------------------------------------
  // Editor
  // ---------------------------------------------------------------------------

  void openEditor() {
    _isEditorOpen = true;
    notifyListeners();
  }

  void closeEditor() {
    _isEditorOpen = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  Future<void> dismissSheet() async {
    _advanceTimer?.cancel();
    if (_activeTearSheetId != null) {
      final doneStatuses = ['done', 'flagged', 'skipped'];
      final allDone = _items.every(
          (i) => doneStatuses.contains(i['status']));
      if (!allDone) {
        await CallHistoryDb.updateTearSheetStatus(
            _activeTearSheetId!, 'paused');
      }
    }
    _activeTearSheetId = null;
    _items = [];
    _currentIndex = -1;
    _isPaused = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }
}
