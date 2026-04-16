import 'package:flutter/foundation.dart';
import 'package:sip_ua/sip_ua.dart';

import 'conference_config.dart';

// ---------------------------------------------------------------------------
// Call leg model
// ---------------------------------------------------------------------------

enum LegState { ringing, active, held, merged }

class ConferenceCallLeg {
  final String sipCallId;
  final String remoteNumber;
  final String? displayName;
  final bool isOutbound;
  LegState state;

  ConferenceCallLeg({
    required this.sipCallId,
    required this.remoteNumber,
    this.displayName,
    this.isOutbound = true,
    this.state = LegState.ringing,
  });
}

// ---------------------------------------------------------------------------
// Conference service
// ---------------------------------------------------------------------------

class ConferenceService extends ChangeNotifier {
  ConferenceService();

  ConferenceConfig _config = const ConferenceConfig();

  ConferenceConfig get config => _config;

  set onConferenceModeChanged(void Function(bool active)? cb) =>
      _onConferenceModeChanged = cb;

  void applyConfig(ConferenceConfig config) {
    _config = config;
    notifyListeners();
  }

  // -- SIP helper reference ---------------------------------------------------

  SIPUAHelper? sipHelper;

  void Function(bool active)? _onConferenceModeChanged;

  // -- Leg tracking -----------------------------------------------------------

  final List<ConferenceCallLeg> _legs = [];
  String? _focusedLegId;
  String? _conferenceId;
  String? _conferenceName;
  bool _merging = false;
  String? _mergeError;

  List<ConferenceCallLeg> get legs => List.unmodifiable(_legs);
  int get legCount => _legs.length;
  String? get focusedLegId => _focusedLegId;
  bool get hasConference => _conferenceId != null;
  String? get conferenceId => _conferenceId;
  String? get conferenceName => _conferenceName;
  bool get isMerging => _merging;
  String? get mergeError => _mergeError;
  bool get canMerge =>
      _legs.length >= 2 &&
      _conferenceId == null &&
      (_config.provider == ConferenceProviderType.basic ||
          _config.provider == ConferenceProviderType.onDevice);

  ConferenceCallLeg? get focusedLeg {
    if (_focusedLegId == null) return null;
    try {
      return _legs.firstWhere((l) => l.sipCallId == _focusedLegId);
    } catch (_) {
      return null;
    }
  }

  ConferenceCallLeg? legById(String sipCallId) {
    try {
      return _legs.firstWhere((l) => l.sipCallId == sipCallId);
    } catch (_) {
      return null;
    }
  }

  // -- Leg lifecycle ----------------------------------------------------------

  void addLeg(Call call, {String? displayName, bool isOutbound = true}) {
    if (_legs.any((l) => l.sipCallId == call.id)) return;
    _legs.add(ConferenceCallLeg(
      sipCallId: call.id!,
      remoteNumber: call.remote_identity ?? '',
      displayName: displayName ?? call.remote_display_name,
      isOutbound: isOutbound,
    ));
    _focusedLegId ??= call.id;
    notifyListeners();
  }

  void removeLeg(String sipCallId) {
    _legs.removeWhere((l) => l.sipCallId == sipCallId);
    if (_focusedLegId == sipCallId) {
      _focusedLegId = _legs.isNotEmpty ? _legs.first.sipCallId : null;
    }
    if (_legs.isEmpty) {
      _conferenceId = null;
      _conferenceName = null;
    }
    notifyListeners();
  }

  void updateLegState(String sipCallId, LegState state) {
    final leg = legById(sipCallId);
    if (leg == null) return;
    leg.state = state;
    notifyListeners();
  }

  void focusLeg(String sipCallId) {
    if (_focusedLegId == sipCallId) return;
    _focusedLegId = sipCallId;
    notifyListeners();
  }

  // -- Hold/unhold a specific leg via SIP ------------------------------------

  void holdLeg(String sipCallId) {
    final call = sipHelper?.findCall(sipCallId);
    if (call == null) return;
    final useUpdate = _config.basicSupportsUpdate;
    if (useUpdate) {
      call.session.hold(<String, dynamic>{'useUpdate': true});
    } else {
      call.hold();
    }
    updateLegState(sipCallId, LegState.held);
  }

  void unholdLeg(String sipCallId) {
    final call = sipHelper?.findCall(sipCallId);
    if (call == null) return;
    final useUpdate = _config.basicSupportsUpdate;
    if (useUpdate) {
      call.session.unhold(<String, dynamic>{'useUpdate': true});
    } else {
      call.unhold();
    }
    updateLegState(sipCallId, LegState.active);
  }

  // -- Merge (conference) ----------------------------------------------------

  Future<void> merge() async {
    if (_legs.length < 2) {
      _mergeError = 'Need at least 2 calls to merge';
      notifyListeners();
      return;
    }

    if (_config.provider == ConferenceProviderType.onDevice) {
      return _mergeLocal();
    }
    if (_config.provider == ConferenceProviderType.basic) {
      return _mergeBasic();
    }
  }

  // -- Basic merge (SIP REFER) ------------------------------------------------

  Future<void> _mergeBasic() async {
    _merging = true;
    _mergeError = null;
    notifyListeners();

    try {
      final callA = sipHelper?.findCall(_legs[0].sipCallId);
      final callB = sipHelper?.findCall(_legs[1].sipCallId);
      if (callA == null || callB == null) {
        throw StateError('Could not locate SIP calls for merge');
      }

      final targetUri = callB.remote_identity ?? '';
      if (targetUri.isEmpty) {
        throw StateError('Second leg has no remote identity for REFER');
      }

      debugPrint('[ConferenceService] Basic merge: REFER on leg '
          '${_legs[0].sipCallId} → $targetUri');

      callA.session.refer(targetUri);

      for (final leg in _legs) {
        leg.state = LegState.merged;
      }
      _conferenceId = 'basic-${DateTime.now().millisecondsSinceEpoch}';
      _conferenceName = 'Basic Conference';

      if (_config.basicRenegotiateMedia) {
        debugPrint('[ConferenceService] Renegotiating media after merge');
        callA.renegotiate(options: null);
      }

      debugPrint('[ConferenceService] Basic conference merge complete');
    } catch (e) {
      _mergeError = e.toString();
      debugPrint('[ConferenceService] basic merge failed: $e');
    } finally {
      _merging = false;
      notifyListeners();
    }
  }

  // -- On-device merge (local audio mixing) ------------------------------------

  Future<void> _mergeLocal() async {
    _merging = true;
    _mergeError = null;
    notifyListeners();

    try {
      for (final leg in _legs) {
        final call = sipHelper?.findCall(leg.sipCallId);
        if (call != null && call.state == CallStateEnum.HOLD) {
          debugPrint(
            '[ConferenceService] On-device merge: unholding ${leg.sipCallId} '
            '(${leg.remoteNumber})',
          );
          call.unhold();
          leg.state = LegState.active;
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 1500));

      if (_onConferenceModeChanged != null) {
        _onConferenceModeChanged!(true);
      }

      for (final leg in _legs) {
        leg.state = LegState.merged;
      }
      _conferenceId = 'local-${DateTime.now().millisecondsSinceEpoch}';
      _conferenceName = 'On-Device Mix';

      debugPrint(
        '[ConferenceService] On-device conference active with '
        '${_legs.length} legs',
      );
    } catch (e) {
      _mergeError = e.toString();
      debugPrint('[ConferenceService] on-device merge failed: $e');
    } finally {
      _merging = false;
      notifyListeners();
    }
  }

  // -- Reset ------------------------------------------------------------------

  void reset() {
    if (_conferenceId != null &&
        _conferenceId!.startsWith('local-') &&
        _onConferenceModeChanged != null) {
      _onConferenceModeChanged!(false);
    }
    _legs.clear();
    _focusedLegId = null;
    _conferenceId = null;
    _conferenceName = null;
    _merging = false;
    _mergeError = null;
    notifyListeners();
  }
}
