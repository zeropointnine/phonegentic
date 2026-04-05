import 'package:flutter/foundation.dart';
import 'package:sip_ua/sip_ua.dart';

import 'conference_config.dart';
import 'conference_provider.dart';
import 'telnyx_conference_provider.dart';

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

  /// Resolved after [ConferenceProvider.lookupActiveCalls].
  String? callControlId;

  ConferenceCallLeg({
    required this.sipCallId,
    required this.remoteNumber,
    this.displayName,
    this.isOutbound = true,
    this.state = LegState.ringing,
    this.callControlId,
  });
}

// ---------------------------------------------------------------------------
// Conference service
// ---------------------------------------------------------------------------

class ConferenceService extends ChangeNotifier {
  ConferenceService();

  // -- Provider ---------------------------------------------------------------

  ConferenceProvider? _provider;
  ConferenceConfig _config = const ConferenceConfig();

  ConferenceConfig get config => _config;
  bool get isProviderConfigured => _provider?.isConfigured ?? false;

  void applyConfig(ConferenceConfig config) {
    _config = config;
    _provider = _buildProvider(config);
    notifyListeners();
  }

  static ConferenceProvider? _buildProvider(ConferenceConfig config) {
    switch (config.provider) {
      case ConferenceProviderType.none:
      case ConferenceProviderType.basic:
        return null;
      case ConferenceProviderType.telnyx:
        if (!config.isConfigured) return null;
        return TelnyxConferenceProvider(
          apiKey: config.telnyxApiKey,
          connectionId: config.telnyxConnectionId,
          webhookUrl: config.telnyxWebhookUrl,
        );
    }
  }

  // -- SIP helper reference ---------------------------------------------------

  SIPUAHelper? sipHelper;

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
          isProviderConfigured);

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

  /// Merge all active legs into a conference.
  ///
  /// Dispatches to [_mergeBasic] (SIP REFER) or [_mergeTelnyx] (REST API)
  /// depending on [ConferenceConfig.provider].
  Future<void> merge() async {
    if (_legs.length < 2) {
      _mergeError = 'Need at least 2 calls to merge';
      notifyListeners();
      return;
    }

    if (_config.provider == ConferenceProviderType.basic) {
      return _mergeBasic();
    }
    return _mergeTelnyx();
  }

  // -- Basic merge (SIP REFER) ------------------------------------------------

  /// Merge via a standard SIP REFER sent on the first leg, pointing at the
  /// second leg's remote URI.  The platform is expected to bridge the two
  /// parties.
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

  // -- Telnyx merge (REST API) ------------------------------------------------

  /// Merge via Telnyx Call Control REST API — creates a server-side conference
  /// bridge and joins all legs.
  Future<void> _mergeTelnyx() async {
    if (_provider == null) {
      _mergeError = 'No conference provider configured';
      notifyListeners();
      return;
    }

    _merging = true;
    _mergeError = null;
    notifyListeners();

    try {
      final activeCalls = await _provider!.lookupActiveCalls();
      debugPrint(
          '[ConferenceService] Found ${activeCalls.length} active calls on provider');

      _resolveAllLegs(activeCalls);
      for (final leg in _legs) {
        if (leg.callControlId == null) {
          throw StateError(
              'Could not resolve call_control_id for leg ${leg.sipCallId} '
              '(remote: ${leg.remoteNumber})');
        }
      }

      final first = _legs.first;
      final bridge = await _provider!.createConference(
        first.callControlId!,
        name: 'phonegentic-${DateTime.now().millisecondsSinceEpoch}',
      );
      _conferenceId = bridge.conferenceId;
      _conferenceName = bridge.name;
      first.state = LegState.merged;

      for (int i = 1; i < _legs.length; i++) {
        await _provider!
            .joinConference(_conferenceId!, _legs[i].callControlId!);
        _legs[i].state = LegState.merged;
      }

      debugPrint('[ConferenceService] Conference $_conferenceId active '
          'with ${_legs.length} participants');
    } catch (e) {
      _mergeError = e.toString();
      debugPrint('[ConferenceService] merge failed: $e');
    } finally {
      _merging = false;
      notifyListeners();
    }
  }

  /// Two-pass matching of SIP legs to provider active calls.
  ///
  /// Pass 1: match by phone number (from/to).
  /// Pass 2: assign remaining legs by elimination.
  void _resolveAllLegs(List<ActiveCallInfo> activeCalls) {
    final assigned = <String>{}; // call_control_ids already taken

    // Pass 1: match by phone number
    for (final leg in _legs) {
      final normalized = _normalizeNumber(leg.remoteNumber);
      debugPrint(
        '[ConferenceService] Matching leg ${leg.sipCallId} '
        '(remote: ${leg.remoteNumber} → norm: $normalized)',
      );
      for (final ac in activeCalls) {
        if (assigned.contains(ac.callControlId)) continue;
        final normTo = _normalizeNumber(ac.to ?? '');
        final normFrom = _normalizeNumber(ac.from ?? '');
        if (normTo == normalized || normFrom == normalized) {
          leg.callControlId = ac.callControlId;
          assigned.add(ac.callControlId);
          debugPrint(
            '[ConferenceService]   ✓ matched → ${ac.callControlId} '
            '(from=$normFrom to=$normTo)',
          );
          break;
        }
      }
    }

    // Pass 2: elimination for unmatched legs
    final unmatched = _legs.where((l) => l.callControlId == null).toList();
    if (unmatched.isEmpty) return;

    final remaining = activeCalls
        .where((ac) => !assigned.contains(ac.callControlId))
        .toList();
    debugPrint(
      '[ConferenceService] Pass 2: ${unmatched.length} unmatched legs, '
      '${remaining.length} remaining API calls',
    );
    for (final ac in remaining) {
      debugPrint(
        '[ConferenceService]   remaining: ${ac.callControlId} '
        'from=${ac.from} to=${ac.to}',
      );
    }

    if (unmatched.length == 1 && remaining.length == 1) {
      unmatched.first.callControlId = remaining.first.callControlId;
      debugPrint(
        '[ConferenceService]   ✓ elimination → '
        '${remaining.first.callControlId} for ${unmatched.first.remoteNumber}',
      );
    } else if (remaining.length >= unmatched.length) {
      // Use the MOST RECENT calls (sorted ascending by createdAt from
      // provider), skipping older stale entries from previous sessions.
      final offset = remaining.length - unmatched.length;
      for (int i = 0; i < unmatched.length; i++) {
        unmatched[i].callControlId = remaining[offset + i].callControlId;
        debugPrint(
          '[ConferenceService]   ✓ greedy (newest) → '
          '${remaining[offset + i].callControlId} for ${unmatched[i].remoteNumber}'
          '${offset > 0 ? ' (skipped $offset stale)' : ''}',
        );
      }
    }
  }

  static String _normalizeNumber(String n) {
    final digits = n.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length > 10 && digits.startsWith('1')) {
      return digits.substring(1);
    }
    return digits;
  }

  // -- Reset ------------------------------------------------------------------

  void reset() {
    _legs.clear();
    _focusedLegId = null;
    _conferenceId = null;
    _conferenceName = null;
    _merging = false;
    _mergeError = null;
    notifyListeners();
  }
}
