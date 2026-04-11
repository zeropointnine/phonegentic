import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sip_ua/sip_ua.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  /// The B-leg (PSTN side) call_control_id, captured via webhook when call
  /// parking is enabled on the credential connection.
  String? bLegCallControlId;

  ConferenceCallLeg({
    required this.sipCallId,
    required this.remoteNumber,
    this.displayName,
    this.isOutbound = true,
    this.state = LegState.ringing,
    this.callControlId,
    this.bLegCallControlId,
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

  // -- WebSocket relay for B-leg discovery ------------------------------------

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  Timer? _wsReconnect;
  String? _wsUrl;

  ConferenceConfig get config => _config;
  bool get isProviderConfigured => _provider?.isConfigured ?? false;

  void applyConfig(ConferenceConfig config) {
    _config = config;
    _provider = _buildProvider(config);
    notifyListeners();

    if (_provider is TelnyxConferenceProvider) {
      // Enable call parking so B-leg ccids are surfaced via webhook.
      (_provider! as TelnyxConferenceProvider)
          .enableCallParking()
          .then((ok) {
        if (ok) {
          debugPrint('[ConferenceService] Call parking enabled at startup');
        }
      });

      // Auto-connect to the webhook relay WebSocket for B-leg discovery.
      final wsUrl = _wsUrlFromWebhook(config.telnyxWebhookUrl);
      if (wsUrl != null) {
        connectWebSocket(wsUrl);
      }
    } else {
      _disconnectWebSocket();
    }
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

  // -- B-leg webhook capture --------------------------------------------------

  /// Called from the webhook listener when a Telnyx `call.initiated` event
  /// fires for the B-leg (direction=outgoing).  Stores the B-leg ccid on the
  /// most recently added leg so that [_joinBLegs] can use it even if the
  /// session-based API lookup fails.
  void onBLegDetected(String bLegCcid) {
    // Attach to the newest leg that doesn't already have a B-leg ccid.
    for (int i = _legs.length - 1; i >= 0; i--) {
      if (_legs[i].bLegCallControlId == null) {
        _legs[i].bLegCallControlId = bLegCcid;
        debugPrint(
          '[ConferenceService] Stored B-leg $bLegCcid '
          'for leg ${_legs[i].sipCallId}',
        );
        return;
      }
    }
    debugPrint(
      '[ConferenceService] B-leg $bLegCcid detected but no unmatched leg',
    );
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
      // Unhold every held leg via SIP *before* touching the conference API.
      // This sends a re-INVITE with sendrecv so both the A-leg (SIP) and
      // B-leg (PSTN) transition back to active media. Without this the B-leg
      // stays in hold state inside the conference and remote parties hear
      // silence then disconnect.
      for (final leg in _legs) {
        final call = sipHelper?.findCall(leg.sipCallId);
        if (call != null && call.state == CallStateEnum.HOLD) {
          debugPrint(
            '[ConferenceService] Pre-unholding held leg ${leg.sipCallId} '
            '(${leg.remoteNumber})',
          );
          call.unhold();
          leg.state = LegState.active;
        }
      }
      // Wait for the SIP re-INVITE round-trip to complete so Telnyx's
      // FreeSWITCH has transitioned the B-leg back to sendrecv.
      await Future<void>.delayed(const Duration(milliseconds: 2000));

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

      final bridge = await _provider!.createConference(
        _legs.first.callControlId!,
        name: 'phonegentic-${DateTime.now().millisecondsSinceEpoch}',
      );
      _conferenceId = bridge.conferenceId;
      _conferenceName = bridge.name;
      _legs.first.state = LegState.merged;

      // Give the conference bridge time to send its re-INVITE for the first
      // leg and for our SIP stack to process/answer it before we join the
      // remaining legs.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      for (final leg in _legs.skip(1)) {
        await _provider!.joinConference(_conferenceId!, leg.callControlId!);
        leg.state = LegState.merged;
      }

      debugPrint('[ConferenceService] Conference $_conferenceId active '
          'with ${_legs.length} participants');

      await _joinBLegs(activeCalls);

      // Wait for the conference bridge to finish its internal media
      // redirection before we force-renegotiate.
      await Future<void>.delayed(const Duration(milliseconds: 2000));

      // Force a re-INVITE on each SIP leg so Telnyx returns the conference
      // bridge's SDP (new IP/port) instead of the original FreeSWITCH
      // server. Without this, our RTP keeps flowing to the pre-conference
      // endpoint which may no longer route to the PSTN B-legs.
      for (final leg in _legs) {
        final call = sipHelper?.findCall(leg.sipCallId);
        if (call == null) continue;
        debugPrint(
          '[ConferenceService] Renegotiating media for ${leg.sipCallId} '
          '(${leg.remoteNumber})',
        );
        call.renegotiate(options: null);
        // Stagger so we don't fire two re-INVITEs in parallel on the
        // same SIP transport — some proxies reject overlapping transactions.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }

      await _verifyParticipants();
    } catch (e) {
      _mergeError = e.toString();
      debugPrint('[ConferenceService] merge failed: $e');
    } finally {
      _merging = false;
      notifyListeners();
    }
  }

  /// Three-pass matching of SIP legs to provider active calls.
  ///
  /// Pass 0: use X-Telnyx-Call-Control-ID captured from SIP headers (most
  ///         reliable — the ccid is embedded in the 200 OK response).
  /// Pass 1: match by phone number (from/to).
  /// Pass 2: assign remaining legs by elimination / greedy.
  void _resolveAllLegs(List<ActiveCallInfo> activeCalls) {
    final assigned = <String>{}; // call_control_ids already taken

    // Pass 0: SIP-header ccid (captured by SIPUAHelper from X-Telnyx-*
    // headers). This is the most reliable strategy because the ccid comes
    // directly from the SIP signaling for that specific dialog.
    for (final leg in _legs) {
      final call = sipHelper?.findCall(leg.sipCallId);
      final sipCcid = call?.telnyxCallControlId;
      if (sipCcid != null && sipCcid.isNotEmpty) {
        leg.callControlId = sipCcid;
        assigned.add(sipCcid);
        debugPrint(
          '[ConferenceService]   ✓ SIP header → $sipCcid '
          'for ${leg.remoteNumber} (${leg.sipCallId})',
        );
      }
    }

    // Pass 1: match by phone number (from/to)
    for (final leg in _legs) {
      if (leg.callControlId != null) continue;
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

  // -- B-leg discovery --------------------------------------------------------

  /// Join B-leg (PSTN side) call_control_ids to the conference.
  ///
  /// Credential connections only surface A-legs via the active_calls endpoint.
  /// B-legs must be captured from webhook events (requires call_parking_enabled
  /// on the credential connection) and explicitly joined.
  Future<void> _joinBLegs(List<ActiveCallInfo> activeCalls) async {
    if (_provider == null || _conferenceId == null) return;

    // Collect A-leg ccids already in the conference so we can skip duplicates.
    // For credential connections the webhook "B-leg" ccid is often the same as
    // the A-leg ccid (Telnyx uses a single call_control_id for the whole call).
    final alreadyJoined = <String>{
      for (final leg in _legs)
        if (leg.callControlId != null) leg.callControlId!,
    };

    final joinedBLegs = <String>{};

    for (final leg in _legs) {
      final bCcid = leg.bLegCallControlId;
      if (bCcid == null || bCcid.isEmpty) continue;
      if (joinedBLegs.contains(bCcid)) continue;
      if (alreadyJoined.contains(bCcid)) {
        debugPrint(
          '[ConferenceService] B-leg $bCcid is same as A-leg (credential '
          'connection) — already in conference, skipping',
        );
        joinedBLegs.add(bCcid);
        continue;
      }
      debugPrint(
        '[ConferenceService] Using webhook-cached B-leg $bCcid '
        'for leg ${leg.sipCallId}',
      );
      await _tryJoinBLeg(bCcid, null, leg.remoteNumber);
      joinedBLegs.add(bCcid);
    }

    if (joinedBLegs.isEmpty) {
      debugPrint(
        '[ConferenceService] ⚠ No B-legs discovered or joined. '
        'Remote parties may lose audio if the conference bridge does not '
        'automatically handle B-leg media routing. Enable call_parking '
        'on the credential connection for explicit B-leg management.',
      );
    }
  }

  Future<void> _tryJoinBLeg(String ccid, String? from, String? to) async {
    debugPrint(
      '[ConferenceService] Joining B-leg $ccid '
      '(from=$from, to=$to) to conference $_conferenceId',
    );
    try {
      await _provider!.joinConference(_conferenceId!, ccid);
      debugPrint('[ConferenceService]   ✓ B-leg $ccid joined');
    } catch (e) {
      debugPrint('[ConferenceService]   ✗ B-leg join failed: $e');
    }
  }

  // -- Conference verification ------------------------------------------------

  Future<void> _verifyParticipants() async {
    if (_provider == null || _conferenceId == null) return;

    try {
      final participants =
          await _provider!.listParticipants(_conferenceId!);
      debugPrint(
        '[ConferenceService] Conference $_conferenceId has '
        '${participants.length} participant(s):',
      );
      for (final p in participants) {
        debugPrint(
          '[ConferenceService]   participant: ccid=${p.callControlId} '
          'session=${p.callSessionId} leg=${p.callLegId} '
          'status=${p.status} muted=${p.muted} hold=${p.onHold}',
        );
      }
    } catch (e) {
      debugPrint(
        '[ConferenceService] listParticipants failed: $e',
      );
    }
  }

  // -- WebSocket relay --------------------------------------------------------

  /// Derive the WS URL from the configured webhook URL.
  /// e.g. `https://example.com/web_hooks/telnyx` → `wss://example.com/ws/call_control`
  static String? _wsUrlFromWebhook(String webhookUrl) {
    if (webhookUrl.isEmpty) return null;
    try {
      final uri = Uri.parse(webhookUrl);
      if (uri.host.isEmpty) return null;
      final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      return '$scheme://${uri.host}:$port/ws/call_control';
    } catch (_) {
      return null;
    }
  }

  /// Connect to the Rust relay server's WebSocket to receive Telnyx
  /// call-control webhook events (B-leg discovery, etc.).
  void connectWebSocket(String url) {
    if (url == _wsUrl && _wsChannel != null) return;
    _disconnectWebSocket();
    _wsUrl = url;
    _wsConnect();
  }

  void _wsConnect() {
    if (_wsUrl == null || _wsUrl!.isEmpty) return;
    try {
      debugPrint('[ConferenceService] WS connecting to $_wsUrl');
      _wsChannel = WebSocketChannel.connect(Uri.parse(_wsUrl!));
      _wsSub = _wsChannel!.stream.listen(
        _onWsMessage,
        onError: (Object err) {
          debugPrint('[ConferenceService] WS error: $err');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[ConferenceService] WS closed');
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('[ConferenceService] WS connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _onWsMessage(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final bLegCcid = TelnyxConferenceProvider.extractBLegFromWebhook(json);
      if (bLegCcid != null) {
        onBLegDetected(bLegCcid);
      }
    } catch (e) {
      debugPrint('[ConferenceService] WS parse error: $e');
    }
  }

  void _scheduleReconnect() {
    _wsChannel = null;
    _wsSub?.cancel();
    _wsSub = null;
    _wsReconnect?.cancel();
    _wsReconnect = Timer(const Duration(seconds: 5), _wsConnect);
  }

  void _disconnectWebSocket() {
    _wsReconnect?.cancel();
    _wsReconnect = null;
    _wsSub?.cancel();
    _wsSub = null;
    _wsChannel?.sink.close();
    _wsChannel = null;
    _wsUrl = null;
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

  @override
  void dispose() {
    _disconnectWebSocket();
    super.dispose();
  }
}
