import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sip_ua/sip_ua.dart';

import 'agent_service.dart';
import 'callscreen.dart';
import 'conference/conference_service.dart';
import 'job_function_service.dart';
import 'manager_presence_service.dart';
import 'messaging/messaging_service.dart';
import 'models/job_function.dart';

/// Record of a caller that was on hold and hung up before we got back to them.
/// Used by the auto-callback queue.
class HeldHangupRecord {
  final String sipCallId;
  final String number;
  final String? displayName;
  final int? jobFunctionId;
  final DateTime hungUpAt;

  HeldHangupRecord({
    required this.sipCallId,
    required this.number,
    this.displayName,
    this.jobFunctionId,
    required this.hungUpAt,
  });
}

/// Centralized policy for "a second call arrived while the user is already on
/// a call". Owns the pending-inbound toast target, the held-hangup queue
/// (callers who hung up while on hold), and the actions the toast buttons
/// dispatch.
///
/// All SIP actions resolve the target `Call` by id before acting — we never
/// reach for `sipHelper.activeCall` so a rapid click can't hang up the wrong
/// call.
class InboundCallRouter extends ChangeNotifier {
  InboundCallRouter();

  SIPUAHelper? _sipHelper;
  JobFunctionService? _jobFunctionService;
  ManagerPresenceService? _managerPresence;
  MessagingService? _messaging;
  ConferenceService? _conference;
  AgentService? _agent;

  /// Provides access to the live `_calls` map owned by the dialpad. The
  /// router never mutates this map — it only reads to resolve a `Call` by id.
  Map<String?, Call> Function()? _callsLookup;

  /// Callback the dialpad registers so the router can request a focus switch
  /// when answering the new leg.
  void Function(String sipCallId)? _focusCall;

  /// Callback the dialpad registers so the router can request a dial on the
  /// primary outbound path. Accepts the destination number.
  Future<void> Function(String number)? _dial;

  /// Callback fired AFTER we successfully accept a pending inbound leg. The
  /// dialpad uses this to clear any lingering native mic-tap mute and kick
  /// the agent out of any "for-away" mute state so the operator can actually
  /// speak to the new caller.
  void Function(String sipCallId)? _onAnswered;

  Call? _pendingInbound;
  bool _inFlight = false;

  final List<HeldHangupRecord> _heldHangups = [];
  HeldHangupRecord? _activeCallbackPrompt;

  // ── Wiring ────────────────────────────────────────────────────────────────

  void attach({
    required SIPUAHelper sipHelper,
    required JobFunctionService jobFunctionService,
    required ManagerPresenceService managerPresence,
    required MessagingService messaging,
    required ConferenceService conference,
    required AgentService agent,
    required Map<String?, Call> Function() callsLookup,
    required void Function(String sipCallId) focusCall,
    required Future<void> Function(String number) dial,
    void Function(String sipCallId)? onAnswered,
  }) {
    _sipHelper = sipHelper;
    _jobFunctionService = jobFunctionService;
    _managerPresence = managerPresence;
    _messaging = messaging;
    _conference = conference;
    _agent = agent;
    _callsLookup = callsLookup;
    _focusCall = focusCall;
    _dial = dial;
    _onAnswered = onAnswered;
  }

  // ── Public state ──────────────────────────────────────────────────────────

  Call? get pendingInbound => _pendingInbound;
  bool get hasPendingInbound => _pendingInbound != null;
  HeldHangupRecord? get activeCallbackPrompt => _activeCallbackPrompt;
  bool get hasCallbackPrompt => _activeCallbackPrompt != null;
  List<HeldHangupRecord> get pendingCallbacks =>
      List.unmodifiable(_heldHangups);

  JobFunction? get _jobFunction => _jobFunctionService?.selected;

  // ── Event entrypoints (called from dialpad) ──────────────────────────────

  /// Called when a new inbound INVITE arrives. Returns true if the router has
  /// claimed the call (caller should NOT auto-swap focus to this call);
  /// returns false if the dialpad should continue its default handling.
  bool onInboundInitiation(Call call, {required bool hasExistingCall}) {
    if (!hasExistingCall) return false;
    if (_pendingInbound?.id == call.id) return true;

    final jf = _jobFunction;
    final away = _managerPresence?.isAway ?? false;

    // Manager-away + job function says "respond by SMS": auto-SMS and decline.
    if (away && jf != null && jf.respondBySmsWhenAway) {
      _autoSmsAndDecline(call, jf);
      return true;
    }

    _pendingInbound = call;
    notifyListeners();
    return true;
  }

  /// Called by the dialpad when any call reaches ENDED/FAILED.
  void onCallEnded(Call call, {required bool remoteHangup}) {
    // If the pending inbound itself ends (caller gave up, or we handled it),
    // clear the toast.
    if (_pendingInbound?.id == call.id) {
      _pendingInbound = null;
      notifyListeners();
    }
  }

  /// Called by the dialpad when a call that was on HOLD ends by remote
  /// hangup. Queues the caller for auto-callback / prompt later.
  void noteHeldEndedByRemote(Call call) {
    final number = (call.remote_identity ?? '').trim();
    if (number.isEmpty) return;
    if (_heldHangups.any((r) => r.sipCallId == call.id)) return;

    _heldHangups.add(HeldHangupRecord(
      sipCallId: call.id ?? '',
      number: number,
      displayName: call.remote_display_name,
      jobFunctionId: _jobFunction?.id,
      hungUpAt: DateTime.now(),
    ));
    debugPrint('[InboundCallRouter] Queued held-hangup for $number '
        '(total=${_heldHangups.length})');
    notifyListeners();
  }

  /// Called when the primary call ends. Drives the auto-callback policy:
  /// - Manager away: auto-dial the oldest queued held-hangup.
  /// - Manager present: surface the oldest queued held-hangup as a prompt.
  Future<void> primaryCallEnded() async {
    if (_heldHangups.isEmpty) return;
    if (_activeCallbackPrompt != null) return;

    final next = _heldHangups.removeAt(0);
    final away = _managerPresence?.isAway ?? false;
    debugPrint('[InboundCallRouter] primaryCallEnded → '
        '${away ? "auto-dial" : "prompt"} ${next.number}');

    if (away) {
      try {
        await _dial?.call(next.number);
      } catch (e) {
        debugPrint('[InboundCallRouter] auto-dial failed: $e');
      }
    } else {
      _activeCallbackPrompt = next;
      notifyListeners();
    }
  }

  // ── Toast actions ─────────────────────────────────────────────────────────

  /// The primary phone button in the toast. Always defaults to Hold+Answer —
  /// putting the existing caller on hold is the safe, reversible choice and
  /// matches the design intent that the operator never accidentally drops
  /// a call by tapping the big green answer button. If an operator really
  /// wants to hang up the current call, they use the dedicated call-end
  /// button on the toast or the agent panel.
  Future<void> answerDefault() async {
    await holdCurrentAndAnswer();
  }

  /// Hold the existing active call, optionally speak a polite hold notice
  /// first, then answer the pending inbound.
  Future<void> holdCurrentAndAnswer() async {
    if (_inFlight) return;
    final pending = _pendingInbound;
    final helper = _sipHelper;
    if (pending == null || helper == null) return;
    _inFlight = true;

    try {
      final existing = _activeConnectedCalls(excludeId: pending.id);
      final jf = _jobFunction;

      if (jf?.speakPoliteHoldNotice == true && existing.isNotEmpty) {
        await _agent?.speakToCurrentCaller(
          "One moment please, I need to take another call.",
          timeout: const Duration(seconds: 3),
        );
      }

      for (final c in existing) {
        _safeHold(c);
      }

      await _accept(pending);
      _pendingInbound = null;
      _focusCall?.call(pending.id ?? '');
      _onAnswered?.call(pending.id ?? '');
    } catch (e) {
      debugPrint('[InboundCallRouter] holdCurrentAndAnswer failed: $e');
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  /// Hang up the existing call (by id, never via `activeCall`) then answer
  /// the pending inbound.
  Future<void> hangupCurrentAndAnswer() async {
    if (_inFlight) return;
    final pending = _pendingInbound;
    final helper = _sipHelper;
    if (pending == null || helper == null) return;
    _inFlight = true;

    try {
      final existing = _activeConnectedCalls(excludeId: pending.id);
      for (final c in existing) {
        _safeHangup(c);
      }

      // Small delay so the BYE has a chance to go out before we tie up audio
      // on the new INVITE accept.
      await Future.delayed(const Duration(milliseconds: 120));
      await _accept(pending);
      _pendingInbound = null;
      _focusCall?.call(pending.id ?? '');
      _onAnswered?.call(pending.id ?? '');
    } catch (e) {
      debugPrint('[InboundCallRouter] hangupCurrentAndAnswer failed: $e');
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  /// Decline the pending inbound (user dismissed the toast).
  Future<void> decline() async {
    if (_inFlight) return;
    final pending = _pendingInbound;
    if (pending == null) return;
    _inFlight = true;
    try {
      _safeHangup(pending);
      _pendingInbound = null;
    } catch (e) {
      debugPrint('[InboundCallRouter] decline failed: $e');
    } finally {
      _inFlight = false;
      notifyListeners();
    }
  }

  /// Dismiss the pending inbound toast without taking SIP action (e.g. user
  /// acted via the agent panel instead). The SIP leg is left alone.
  void dismissPendingToast() {
    if (_pendingInbound == null) return;
    _pendingInbound = null;
    notifyListeners();
  }

  // ── Callback prompt actions ──────────────────────────────────────────────

  Future<void> callbackPromptDial() async {
    final r = _activeCallbackPrompt;
    if (r == null) return;
    _activeCallbackPrompt = null;
    notifyListeners();
    try {
      await _dial?.call(r.number);
    } catch (e) {
      debugPrint('[InboundCallRouter] callbackPromptDial failed: $e');
    }
    _maybeAdvanceCallbackPrompt();
  }

  Future<void> callbackPromptSms() async {
    final r = _activeCallbackPrompt;
    if (r == null) return;
    _activeCallbackPrompt = null;
    notifyListeners();
    final jf = _jobFunction;
    final template =
        (jf?.awaySmsTemplate ?? '').trim().isNotEmpty
            ? jf!.awaySmsTemplate!.trim()
            : JobFunction.defaultAwaySmsTemplate;
    try {
      await _messaging?.sendMessage(to: r.number, text: template);
    } catch (e) {
      debugPrint('[InboundCallRouter] callbackPromptSms failed: $e');
    }
    _maybeAdvanceCallbackPrompt();
  }

  void callbackPromptDismiss() {
    if (_activeCallbackPrompt == null) return;
    _activeCallbackPrompt = null;
    notifyListeners();
    _maybeAdvanceCallbackPrompt();
  }

  void _maybeAdvanceCallbackPrompt() {
    if (_heldHangups.isEmpty) return;
    if (_activeCallbackPrompt != null) return;
    _activeCallbackPrompt = _heldHangups.removeAt(0);
    notifyListeners();
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  List<Call> _activeConnectedCalls({required String? excludeId}) {
    final calls = _callsLookup?.call() ?? const <String?, Call>{};
    final result = <Call>[];
    calls.forEach((id, c) {
      if (id == excludeId) return;
      final s = c.state;
      if (s == CallStateEnum.ENDED || s == CallStateEnum.FAILED) return;
      if (s == CallStateEnum.CALL_INITIATION) return;
      result.add(c);
    });
    return result;
  }

  Future<void> _accept(Call call) async {
    final helper = _sipHelper;
    if (helper == null) return;
    await CallScreenWidget.acceptCall(call, helper);
  }

  void _safeHold(Call call) {
    try {
      if (call.state == CallStateEnum.HOLD) return;
      final useUpdate = _conference?.config.basicSupportsUpdate ?? false;
      if (useUpdate) {
        call.session.hold(<String, dynamic>{'useUpdate': true});
      } else {
        call.hold();
      }
      if (call.id != null) {
        _conference?.updateLegState(call.id!, LegState.held);
      }
    } catch (e) {
      debugPrint('[InboundCallRouter] hold failed for ${call.id}: $e');
    }
  }

  void _safeHangup(Call call) {
    try {
      call.hangup();
    } catch (e) {
      debugPrint('[InboundCallRouter] hangup failed for ${call.id}: $e');
    }
  }

  Future<void> _autoSmsAndDecline(Call call, JobFunction jf) async {
    final number = (call.remote_identity ?? '').trim();
    final template = (jf.awaySmsTemplate ?? '').trim().isNotEmpty
        ? jf.awaySmsTemplate!.trim()
        : JobFunction.defaultAwaySmsTemplate;
    debugPrint('[InboundCallRouter] Manager away → auto-SMS to $number '
        'and decline');
    try {
      if (number.isNotEmpty) {
        await _messaging?.sendMessage(to: number, text: template);
      }
    } catch (e) {
      debugPrint('[InboundCallRouter] auto-SMS failed: $e');
    }
    _safeHangup(call);
  }
}
