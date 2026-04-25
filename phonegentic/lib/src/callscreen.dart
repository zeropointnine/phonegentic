import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'package:provider/provider.dart';

import 'agent_config_service.dart';
import 'agent_service.dart';
import 'call_history_service.dart';
import 'conference/conference_service.dart';
import 'contact_service.dart';
import 'db/call_history_db.dart';
import 'db/pocket_tts_voice_db.dart';
import 'demo_mode_service.dart';
import 'manager_presence_service.dart';
import 'messaging/messaging_service.dart';
import 'messaging/phone_numbers.dart';
import 'tear_sheet_service.dart';
import 'models/agent_context.dart';
import 'theme_provider.dart';
import 'widgets/action_button.dart';
import 'widgets/add_call_modal.dart';
import 'widgets/dialpad_contact_preview.dart';
import 'widgets/glass_plate_modal.dart';

import 'widgets/add_2_call_icon.dart';
import 'widgets/voice_clone_modal.dart';

class CallScreenWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  final Call? _call;
  final VoidCallback? onDismiss;

  CallScreenWidget(this._helper, this._call, {super.key, this.onDismiss});

  /// Accept an incoming call programmatically (e.g. agent auto-answer).
  /// Can be called without a mounted CallScreenWidget.
  static Future<void> acceptCall(Call call, SIPUAHelper helper) async {
    try {
      if (call.state != CallStateEnum.CALL_INITIATION &&
          call.state != CallStateEnum.PROGRESS) {
        debugPrint('[CallScreen] acceptCall skipped — state=${call.state}');
        return;
      }
      final mediaConstraints = <String, dynamic>{
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'channelCount': 2,
        },
        'video': false,
      };
      final mediaStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      call.answer(helper.buildCallOptions(true), mediaStream: mediaStream);
    } catch (e) {
      debugPrint('[CallScreen] Auto-answer failed: $e');
    }
  }

  @override
  State<CallScreenWidget> createState() => _MyCallScreenWidget();
}

class _MyCallScreenWidget extends State<CallScreenWidget>
    with TickerProviderStateMixin
    implements SipUaHelperListener {
  RTCVideoRenderer? _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer? _remoteRenderer = RTCVideoRenderer();
  double? _localVideoHeight;
  double? _localVideoWidth;
  EdgeInsetsGeometry? _localVideoMargin;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  bool _showNumPad = false;
  final ValueNotifier<String> _timeLabel = ValueNotifier<String>('00:00');
  bool _audioMuted = false;
  bool _softMute = false;
  bool _softMuteBeforeAway = false;
  bool _awaySoftMuteSaved = false;
  bool _videoMuted = false;
  bool _hold = false;
  bool _mirror = true;
  final bool _showLocalVideo = false;
  Originator? _holdOriginator;
  bool _callConfirmed = false;
  bool _enteredCallMode = false;
  Timer? _callConfirmTimer;
  bool _addCallReady = false;
  Timer? _addCallGraceTimer;
  CallStateEnum _state = CallStateEnum.NONE;

  String? _recordingPath;
  bool _isRecording = false;
  Timer? _recTimer;
  int _recSeconds = 0;
  String _recLabel = '0:00';
  int? _endingCallRecordId;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  Timer? _confLevelTimer;
  List<double> _confSlotLevels = [];
  List<double> _smoothedLevels = [];
  static const double _speechThreshold = 200;
  static const double _rmsMax = 3000;

  Timer? _singleLevelTimer;
  double _smoothedSingleRms = 0;

  // Voice sample capture for ElevenLabs voice cloning
  bool _isSampling = false;
  String? _sampleParty;
  String? _samplePath;
  Timer? _sampleTimer;
  int _sampleSeconds = 0;
  String _sampleLabel = '0:00';
  TtsConfig? _ttsConfig;

  late String _transferTarget;
  late Timer _timer;

  SIPUAHelper? get helper => widget._helper;
  bool get voiceOnly =>
      call!.voiceOnly ||
      (_remoteStream == null || _remoteStream!.getVideoTracks().isEmpty);
  String? get remoteIdentity {
    final uri = call!.remote_identity;
    if (uri != null && uri.isNotEmpty) return uri;
    final display = call!.remote_display_name;
    if (display != null && display.isNotEmpty) return display;
    return null;
  }

  Direction? get direction => call!.direction;
  Call? get call => widget._call;

  AgentService? _cachedAgent;
  AgentService get _agent =>
      _cachedAgent ??= Provider.of<AgentService>(context, listen: false);

  void _pushCallPhase(CallStateEnum state) {
    final phase = _sipStateToPhase(state);
    if (phase == null) return;

    final partyCount = (phase.isActive || phase == CallPhase.ringing)
        ? _bootContext.speakers.length
        : 1;
    _agent.notifyCallPhase(
      phase,
      partyCount: partyCount,
      remoteIdentity: remoteIdentity,
      remoteDisplayName: call?.remote_display_name,
      localIdentity: call?.local_identity,
      outbound: direction == Direction.outgoing,
    );
  }

  AgentBootContext get _bootContext => _agent.bootContext;

  static CallPhase? _sipStateToPhase(CallStateEnum state) {
    switch (state) {
      case CallStateEnum.CALL_INITIATION:
        return CallPhase.initiating;
      case CallStateEnum.CONNECTING:
        return CallPhase.connecting;
      case CallStateEnum.PROGRESS:
        return CallPhase.ringing;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        return CallPhase.settling;
      case CallStateEnum.HOLD:
        return CallPhase.onHold;
      case CallStateEnum.UNHOLD:
        return CallPhase.connected;
      case CallStateEnum.ENDED:
        return CallPhase.ended;
      case CallStateEnum.FAILED:
        return CallPhase.failed;
      default:
        return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutSine,
      reverseCurve: Curves.easeInOutSine,
    );
    _initRenderers();
    helper!.addSipUaHelperListener(this);
    _startTimer();
    _loadTtsConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncCallState();
      _initPresenceListener();
    });
    _callConfirmTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_callConfirmed) {
        debugPrint('[CallScreen] Delayed re-sync — _callConfirmed still false');
        _syncCallState();
      }
    });
  }

  void _syncCallState() {
    if (call == null) return;
    final s = call!.state;
    if (s == CallStateEnum.CONFIRMED || s == CallStateEnum.ACCEPTED) {
      _state = s;
      _callConfirmed = true;
      _addCallReady = true;
      _enterCallMode();
      _pushCallPhase(s);
    } else if (s == CallStateEnum.HOLD || s == CallStateEnum.UNHOLD) {
      _state = s;
      _callConfirmed = true;
      _hold = s == CallStateEnum.HOLD;
      _addCallReady = true;
      _enterCallMode();
      _pushCallPhase(s);
    } else if (s != CallStateEnum.NONE) {
      _state = s;
    }
  }

  @override
  void didUpdateWidget(covariant CallScreenWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget._call?.id != widget._call?.id) {
      debugPrint('[CallScreen] Call object swapped (fork replacement): '
          '${oldWidget._call?.id} → ${widget._call?.id}');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncCallState();
      });
    }
  }

  Future<void> _loadTtsConfig() async {
    final config = await AgentConfigService.loadTtsConfig();
    if (mounted) setState(() => _ttsConfig = config);
  }

  @override
  void deactivate() {
    _disposePresenceListener();
    _pulseController.dispose();
    _confLevelTimer?.cancel();
    _singleLevelTimer?.cancel();
    super.deactivate();
    _addCallGraceTimer?.cancel();
    _callConfirmTimer?.cancel();
    helper!.removeSipUaHelperListener(this);
    _deferDisposeRenderers();
  }

  void _startConfLevelPolling() {
    if (_confLevelTimer != null) return;
    _confLevelTimer =
        Timer.periodic(const Duration(milliseconds: 80), (_) async {
      try {
        final result =
            await _tapChannel.invokeMethod('getConferenceAudioLevels');
        if (result is List && mounted) {
          final raw = result.cast<num>().map((n) => n.toDouble()).toList();
          setState(() {
            _confSlotLevels = raw;
            while (_smoothedLevels.length < raw.length) {
              _smoothedLevels.add(0);
            }
            for (int i = 0; i < raw.length; i++) {
              final target = raw[i];
              final current = _smoothedLevels[i];
              final k = target > current ? 0.35 : 0.15;
              _smoothedLevels[i] = current + (target - current) * k;
            }
          });
        }
      } catch (_) {}
    });
  }

  void _stopConfLevelPolling() {
    _confLevelTimer?.cancel();
    _confLevelTimer = null;
    if (_confSlotLevels.isNotEmpty) {
      setState(() {
        _confSlotLevels = [];
        _smoothedLevels = [];
      });
    }
  }

  void _startSingleLevelPolling() {
    if (_singleLevelTimer != null) return;
    _singleLevelTimer =
        Timer.periodic(const Duration(milliseconds: 80), (_) async {
      try {
        final result = await _tapChannel.invokeMethod('getRemoteAudioLevel');
        if (result is num && mounted) {
          final raw = result.toDouble();
          setState(() {
            final k = raw > _smoothedSingleRms ? 0.35 : 0.15;
            _smoothedSingleRms += (raw - _smoothedSingleRms) * k;
          });
        }
      } catch (_) {}
    });
  }

  void _stopSingleLevelPolling() {
    _singleLevelTimer?.cancel();
    _singleLevelTimer = null;
    if (_smoothedSingleRms > 0) {
      setState(() {
        _smoothedSingleRms = 0;
      });
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      Duration duration = Duration(seconds: timer.tick);
      if (mounted) {
        _timeLabel.value = [duration.inMinutes, duration.inSeconds]
            .map((seg) => seg.remainder(60).toString().padLeft(2, '0'))
            .join(':');
      } else {
        _timer.cancel();
      }
    });
  }

  void _initRenderers() async {
    if (_localRenderer != null) await _localRenderer!.initialize();
    if (_remoteRenderer != null) await _remoteRenderer!.initialize();
  }

  void _deferDisposeRenderers() {
    final local = _localRenderer;
    final remote = _remoteRenderer;
    _localRenderer = null;
    _remoteRenderer = null;
    // Defer heavy native-texture teardown so it doesn't block the UI frame.
    Future.microtask(() {
      local?.dispose();
      remote?.dispose();
    });
  }

  @override
  void callStateChanged(Call call, CallState callState) {
    if (call.id != widget._call?.id) {
      debugPrint('[CallScreen] callStateChanged ignored: '
          'event callId=${call.id} != widget callId=${widget._call?.id} '
          'state=${callState.state}');
      return;
    }
    if (!mounted) return;

    debugPrint('[CallScreen] callStateChanged: ${callState.state}');

    // ACCEPTED and CONFIRMED both map to settling. If we already handled
    // one, skip the other to avoid re-entering settling and generating a
    // duplicate greeting.
    if (_callConfirmed &&
        (callState.state == CallStateEnum.ACCEPTED ||
            callState.state == CallStateEnum.CONFIRMED)) {
      _enterCallMode();
      return;
    }

    // Capture the call record ID before _pushCallPhase clears it, so
    // _stopRecording can save the recording path after the file is finalized.
    if (callState.state == CallStateEnum.ENDED ||
        callState.state == CallStateEnum.FAILED) {
      final history = Provider.of<CallHistoryService>(context, listen: false);
      _endingCallRecordId = history.activeCallRecordId;
    }
    _pushCallPhase(callState.state);

    if (callState.state == CallStateEnum.HOLD ||
        callState.state == CallStateEnum.UNHOLD) {
      _hold = callState.state == CallStateEnum.HOLD;
      _holdOriginator = callState.originator;
      setState(() {});
      return;
    }
    if (callState.state == CallStateEnum.MUTED) {
      if (callState.audio!) _audioMuted = true;
      if (callState.video!) _videoMuted = true;
      setState(() {});
      return;
    }
    if (callState.state == CallStateEnum.UNMUTED) {
      if (callState.audio!) _audioMuted = false;
      if (callState.video!) _videoMuted = false;
      setState(() {});
      return;
    }
    switch (callState.state) {
      case CallStateEnum.STREAM:
        _handleStreams(callState);
        break;
      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        // During fork coalescing, individual forks fail but the logical
        // call is still alive — don't update _state or tear down.
        if (_agent.forkCoalescing) {
          debugPrint('[CallScreen] Suppressed teardown during fork coalescing');
          break;
        }
        _state = callState.state;
        _stopRecording();
        final tearSheet = Provider.of<TearSheetService>(context, listen: false);
        if (tearSheet.isActive) {
          final status =
              callState.state == CallStateEnum.FAILED ? 'failed' : 'completed';
          tearSheet.onCallEnded(status);
        }
        _backToDialPad();
        break;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        _state = callState.state;
        _callConfirmTimer?.cancel();
        setState(() => _callConfirmed = true);
        _enterCallMode();
        _maybeAutoRecord();
        _startAddCallGrace();
        break;
      default:
        _state = callState.state;
        setState(() {});
    }
  }

  @override
  void transportStateChanged(TransportState state) {}

  @override
  void registrationStateChanged(RegistrationState state) {}

  void _cleanUp() {
    if (_localStream == null) return;
    final stream = _localStream!;
    _localStream = null;
    Future.microtask(() {
      stream.getTracks().forEach((track) => track.stop());
      stream.dispose();
    });
  }

  void _backToDialPad() {
    _timer.cancel();
    _addCallGraceTimer?.cancel();
    _recTimer?.cancel();
    _recTimer = null;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    if (_isSampling) {
      _tapChannel.invokeMethod('stopVoiceSample');
      _isSampling = false;
    }
    // Delay exitCallMode so the WebRTC signaling thread finishes pending
    // peer connection teardown before we unregister audio processors.
    Future.delayed(const Duration(milliseconds: 500), () => _exitCallMode());
    Timer(const Duration(seconds: 2), () {
      if (mounted) {
        widget.onDismiss?.call();
      }
    });
    _cleanUp();
  }

  void _handleStreams(CallState event) async {
    MediaStream? stream = event.stream;
    if (event.originator == Originator.local) {
      try {
        if (_localRenderer != null) {
          _localRenderer!.srcObject =
              (stream != null && stream.getVideoTracks().isNotEmpty)
                  ? stream
                  : null;
        }
      } catch (e) {
        debugPrint('[CallScreen] localRenderer.srcObject failed: $e');
      }
      if (!kIsWeb &&
          !WebRTC.platformIsDesktop &&
          event.stream?.getAudioTracks().isNotEmpty == true) {
        event.stream?.getAudioTracks().first.enableSpeakerphone(false);
      }
      _localStream = stream;
    }
    if (event.originator == Originator.remote) {
      try {
        if (_remoteRenderer != null) {
          _remoteRenderer!.srcObject =
              (stream != null && stream.getVideoTracks().isNotEmpty)
                  ? stream
                  : null;
        }
      } catch (e) {
        debugPrint('[CallScreen] remoteRenderer.srcObject failed: $e');
      }
      _remoteStream = stream;
    }
    if (mounted) setState(() => _resizeLocalVideo());
  }

  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');

  Future<void> _enterCallMode() async {
    if (_enteredCallMode) return;
    _enteredCallMode = true;
    try {
      await _tapChannel.invokeMethod('enterCallMode');
      await _tapChannel.invokeMethod('setRemoteGain', {'gain': 1.19});
      await _tapChannel
          .invokeMethod('setCompressorStrength', {'strength': 0.6});
      debugPrint(
          '[CallScreen] enterCallMode — AI audio routed through WebRTC pipeline');
    } catch (e) {
      debugPrint('[CallScreen] enterCallMode failed: $e');
    }
  }

  Future<void> _exitCallMode() async {
    if (!_enteredCallMode) return;
    _enteredCallMode = false;
    try {
      await _tapChannel.invokeMethod('exitCallMode');
      debugPrint('[CallScreen] exitCallMode — reverted to direct mic capture');
    } catch (e) {
      debugPrint('[CallScreen] exitCallMode failed: $e');
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    _isRecording = true;
    _recSeconds = 0;
    _recLabel = '0:00';
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recSeconds++;
      final m = _recSeconds ~/ 60;
      final s = _recSeconds % 60;
      if (mounted) {
        setState(() => _recLabel = '$m:${s.toString().padLeft(2, '0')}');
      }
    });
    if (mounted) setState(() {});

    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir = Directory(p.join(dir.path, 'phonegentic', 'recordings'));
      await recDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _recordingPath = p.join(recDir.path, 'call_$timestamp.wav');

      await _tapChannel
          .invokeMethod('startCallRecording', {'path': _recordingPath});
      debugPrint('[CallScreen] Recording started → $_recordingPath');
    } catch (e) {
      debugPrint('[CallScreen] Recording failed to start: $e');
      _recordingPath = null;
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _recTimer?.cancel();
    _recTimer = null;
    _isRecording = false;
    if (mounted) setState(() {});

    final savedPath = _recordingPath;
    final savedRecordId = _endingCallRecordId;

    try {
      await _tapChannel.invokeMethod('stopCallRecording');
      debugPrint('[CallScreen] Recording stopped → $savedPath');
    } catch (e) {
      debugPrint('[CallScreen] Recording stop failed: $e');
    }

    if (savedPath != null) {
      final recordId = savedRecordId ??
          (mounted
              ? Provider.of<CallHistoryService>(context, listen: false)
                  .activeCallRecordId
              : null);
      if (recordId != null) {
        try {
          await CallHistoryDb.updateRecordingPath(recordId, savedPath);
          debugPrint('[CallScreen] Recording path saved for record #$recordId');
        } catch (e) {
          debugPrint('[CallScreen] Failed to save recording path: $e');
        }
      } else {
        debugPrint('[CallScreen] WARNING: No recordId for recording path');
      }
    }
    _endingCallRecordId = null;
  }

  void _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
      _agent.announceRecording();
    }
    setState(() {});
  }

  // ───── Voice Sample Capture ─────

  Future<void> _startVoiceSample(String party) async {
    if (_isSampling) return;

    _isSampling = true;
    _sampleParty = party;
    _sampleSeconds = 0;
    _sampleLabel = '0:00';
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sampleSeconds++;
      final m = _sampleSeconds ~/ 60;
      final s = _sampleSeconds % 60;
      if (mounted) {
        setState(() => _sampleLabel = '$m:${s.toString().padLeft(2, '0')}');
      }
    });
    if (mounted) setState(() {});

    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir =
          Directory(p.join(dir.path, 'phonegentic', 'voice_samples'));
      await recDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _samplePath = p.join(recDir.path, 'sample_${party}_$timestamp.wav');

      await _tapChannel.invokeMethod(
          'startVoiceSample', {'path': _samplePath, 'party': party});
      debugPrint('[CallScreen] Voice sample started → $_samplePath ($party)');
    } catch (e) {
      debugPrint('[CallScreen] Voice sample failed to start: $e');
      _samplePath = null;
      _isSampling = false;
      _sampleTimer?.cancel();
      if (mounted) setState(() {});
    }
  }

  Future<void> _stopVoiceSample() async {
    if (!_isSampling) return;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _isSampling = false;
    if (mounted) setState(() {});

    try {
      await _tapChannel.invokeMethod('stopVoiceSample');
      debugPrint('[CallScreen] Voice sample stopped → $_samplePath');
    } catch (e) {
      debugPrint('[CallScreen] Voice sample stop failed: $e');
    }

    if (_samplePath != null && mounted) {
      if (_ttsConfig?.provider == TtsProvider.pocketTts) {
        await _savePocketTtsVoiceSample(_samplePath!, _sampleParty);
      } else {
        final result = await showVoiceCloneModal(
          context,
          apiKey: _ttsConfig?.elevenLabsApiKey ?? '',
          preRecordedPath: _samplePath,
          sampleParty: _sampleParty,
        );
        if (result != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Voice "${result.name}" created'),
              backgroundColor: AppColors.green,
            ),
          );
        }
      }
    }
    _samplePath = null;
    _sampleParty = null;
  }

  Future<void> _savePocketTtsVoiceSample(
      String samplePath, String? party) async {
    final defaultName = party == 'host' ? 'My Voice' : 'Remote Voice';
    final nameCtrl = TextEditingController(text: defaultName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Save Voice',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Voice name',
            hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.card,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.accent, width: 1),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child:
                Text('Cancel', style: TextStyle(color: AppColors.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: Text('Save', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    nameCtrl.dispose();

    if (result != null && result.isNotEmpty && mounted) {
      try {
        await PocketTtsVoiceDb.addUserVoice(
          name: result,
          audioPath: samplePath,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Voice "$result" saved'),
              backgroundColor: AppColors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to save voice: $e'),
              backgroundColor: AppColors.red,
            ),
          );
        }
      }
    }
  }

  void _toggleVoiceSample(String party) async {
    if (_isSampling && _sampleParty == party) {
      await _stopVoiceSample();
    } else if (_isSampling) {
      await _stopVoiceSample();
      await _startVoiceSample(party);
    } else {
      await _startVoiceSample(party);
    }
  }

  Future<void> _maybeAutoRecord() async {
    final config = await AgentConfigService.loadCallRecordingConfig();
    if (!mounted) return;
    if (config.autoRecord) {
      await _startRecording();
      _agent.announceRecording();
      if (mounted) setState(() {});
    }
  }

  void _resizeLocalVideo() {
    _localVideoMargin = _remoteStream != null
        ? const EdgeInsets.only(top: 15, right: 15)
        : EdgeInsets.zero;
    _localVideoWidth = _remoteStream != null
        ? MediaQuery.of(context).size.width / 4
        : MediaQuery.of(context).size.width;
    _localVideoHeight = _remoteStream != null
        ? MediaQuery.of(context).size.height / 4
        : MediaQuery.of(context).size.height;
  }

  void _handleHangup() {
    final c = call;
    if (c == null) {
      _timer.cancel();
      return;
    }
    // Guard against tapping hangup on a call whose RTCSession has already
    // terminated — happens when the focused leg is a dead SIP fork or the
    // user double-taps. `Call.hangup` throws `Invalid status: terminated`
    // in that case; swallow it since the user's intent ("end this call")
    // is already satisfied.
    final state = c.state;
    if (state == CallStateEnum.ENDED || state == CallStateEnum.FAILED) {
      debugPrint('[CallScreen] _handleHangup skipped — already $state');
      _timer.cancel();
      return;
    }
    try {
      c.hangup({'status_code': 603});
    } catch (e) {
      debugPrint('[CallScreen] _handleHangup swallowed: $e');
    }
    _timer.cancel();
  }

  void _handleAccept() async {
    if (call!.state != CallStateEnum.CALL_INITIATION &&
        call!.state != CallStateEnum.PROGRESS) {
      debugPrint('[CallScreen] _handleAccept skipped — state=${call!.state}');
      return;
    }
    bool remoteHasVideo = call!.remote_has_video;
    final mediaConstraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'channelCount': 2,
      },
      'video': remoteHasVideo
          ? {
              'mandatory': <String, dynamic>{
                'minWidth': '640',
                'minHeight': '480',
                'minFrameRate': '30',
              },
              'facingMode': 'user',
              'optional': <dynamic>[],
            }
          : false
    };
    MediaStream mediaStream;
    if (kIsWeb && remoteHasVideo) {
      mediaStream =
          await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
      MediaStream userStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      mediaStream.addTrack(userStream.getAudioTracks()[0], addToNative: true);
    } else {
      if (!remoteHasVideo) mediaConstraints['video'] = false;
      mediaStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    }
    call!.answer(helper!.buildCallOptions(!remoteHasVideo),
        mediaStream: mediaStream);
  }

  void _switchCamera() {
    if (_localStream != null) {
      Helper.switchCamera(_localStream!.getVideoTracks()[0]);
      setState(() => _mirror = !_mirror);
    }
  }

  void _muteAudio() {
    if (_audioMuted) {
      call!.unmute(true, false);
    } else {
      call!.mute(true, false);
    }
  }

  void _softMuteAudio() async {
    _softMute = !_softMute;
    setState(() {});
    try {
      await _tapChannel.invokeMethod('setMicMute', {'muted': _softMute});
      debugPrint('[CallScreen] setMicMute=$_softMute');
    } catch (e) {
      debugPrint('[CallScreen] setMicMute failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Away-aware soft mute: mute mic when away, restore on return
  // ---------------------------------------------------------------------------

  ManagerPresenceService? _presence;
  bool _wasAway = false;

  void _initPresenceListener() {
    _presence = Provider.of<ManagerPresenceService>(context, listen: false);
    _wasAway = _presence!.isAway;
    _presence!.addListener(_onPresenceChanged);
  }

  void _disposePresenceListener() {
    _presence?.removeListener(_onPresenceChanged);
  }

  void _onPresenceChanged() {
    final away = _presence?.isAway ?? false;
    if (away && !_wasAway) {
      _softMuteForAway();
    } else if (!away && _wasAway) {
      _softUnmuteFromAway();
    }
    _wasAway = away;
  }

  void _softMuteForAway() {
    _softMuteBeforeAway = _softMute;
    _awaySoftMuteSaved = true;
    if (!_softMute) {
      _softMute = true;
      setState(() {});
      _tapChannel.invokeMethod('setMicMute', {'muted': true}).catchError(
          (e) => debugPrint('[CallScreen] setMicMute failed: $e'));
    }
    debugPrint('[CallScreen] Soft-muted for away '
        '(was ${_softMuteBeforeAway ? "muted" : "unmuted"})');
  }

  void _softUnmuteFromAway() {
    if (!_awaySoftMuteSaved) return;
    _awaySoftMuteSaved = false;
    if (!_softMuteBeforeAway && _softMute) {
      _softMute = false;
      setState(() {});
      _tapChannel.invokeMethod('setMicMute', {'muted': false}).catchError(
          (e) => debugPrint('[CallScreen] setMicMute failed: $e'));
    }
    debugPrint('[CallScreen] Restored from away (softMute=$_softMute)');
  }

  void _muteVideo() {
    if (_videoMuted) {
      call!.unmute(false, true);
    } else {
      call!.mute(false, true);
    }
  }

  void _handleHold() {
    if (_hold) {
      call!.unhold();
    } else {
      call!.hold();
    }
  }

  void _handleTransfer() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppColors.card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Transfer Call'),
          content: TextField(
            onChanged: (text) => setState(() => _transferTarget = text),
            decoration: const InputDecoration(hintText: 'URI or Username'),
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.of(context).pop()),
            TextButton(
                child: const Text('Transfer'),
                onPressed: () {
                  call!.refer(_transferTarget);
                  Navigator.of(context).pop();
                }),
          ],
        );
      },
    );
  }

  bool _placingConferenceLeg = false;

  void _startAddCallGrace() {
    _addCallGraceTimer?.cancel();
    _addCallGraceTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _addCallReady = true);
    });
  }

  void _handleAddCall() async {
    if (!_addCallReady) return;
    if (!_hold && call != null) {
      _handleHold();
    }
    const double diameter = 660;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Size screen = MediaQuery.of(context).size;
    Alignment plateAlignment = Alignment.center;
    if (box != null) {
      final Offset center = box.localToGlobal(box.size.center(Offset.zero));
      final double freeX = screen.width - diameter;
      final double freeY = screen.height - diameter;
      plateAlignment = Alignment(
        freeX > 0 ? ((center.dx - diameter / 2) / freeX) * 2 - 1 : 0,
        freeY > 0 ? ((center.dy - diameter / 2) / freeY) * 2 - 1 : 0,
      );
    }
    await GlassPlateModal.show<void>(
      context: context,
      diameter: diameter,
      alignment: plateAlignment,
      builder: (BuildContext ctx) => AddCallModal(
        onCall: _placeConferenceLeg,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
    if (mounted) {
      setState(() => _placingConferenceLeg = false);
    }
  }

  Future<void> _placeConferenceLeg(String number) async {
    if (_placingConferenceLeg) return;
    final cleaned = ensureE164(number);
    if (cleaned.isEmpty) return;
    _placingConferenceLeg = true;
    try {
      final stream = await navigator.mediaDevices
          .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
      await helper!.call(cleaned, voiceOnly: true, mediaStream: stream);
      debugPrint('[CallScreen] Conference leg initiated → $cleaned');
    } catch (e) {
      debugPrint('[CallScreen] Add call failed: $e');
      _placingConferenceLeg = false;
    }
  }

  void _handleAddContact() async {
    debugPrint(
        '[CallScreen] _handleAddContact tapped, remoteIdentity=$remoteIdentity');
    if (remoteIdentity == null || remoteIdentity!.isEmpty) return;
    final contactService = context.read<ContactService>();
    await contactService.openContactForPhone(remoteIdentity!);
    debugPrint(
        '[CallScreen] openContactForPhone done, isOpen=${contactService.isOpen} autoFocus=${contactService.autoFocusName}');
  }

  void _handleSendMessage() {
    final messaging = context.read<MessagingService>();
    if (remoteIdentity != null && remoteIdentity!.isNotEmpty) {
      messaging.openToConversation(remoteIdentity!);
    } else if (!messaging.isOpen) {
      messaging.toggleOpen();
    }
  }

  /// In-call DTMF press — local touchtone synthesis is intentionally not
  /// performed here; only the main pre-call dialer triggers the
  /// `ToneGenerator`. This keeps the in-call audio path free of
  /// locally-synthesised tones (the SIP RFC2833 DTMF the carrier sends
  /// back is what the operator typically hears) and avoids any chance
  /// of the local tone leaking into the outbound mix on platforms
  /// where call audio is rendered through the same engine.
  void _handleDtmf(String tone) {
    if (call != null) {
      try {
        call!.sendDTMF(tone);
      } catch (e) {
        debugPrint('[CallScreen] sendDTMF($tone) failed: $e');
      }
    }
  }

  void _handleKeyPad() => setState(() => _showNumPad = !_showNumPad);

  // ignore: unused_element
  void _handleVideoUpgrade() {
    if (voiceOnly) {
      setState(() => call!.voiceOnly = false);
      helper!.renegotiate(
          call: call!, voiceOnly: false, done: (IncomingMessage? msg) {});
    } else {
      helper!.renegotiate(
          call: call!, voiceOnly: true, done: (IncomingMessage? msg) {});
    }
  }

  // -- State label --
  String get _stateLabel {
    switch (_state) {
      case CallStateEnum.CONNECTING:
      case CallStateEnum.PROGRESS:
        return 'Connecting...';
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        if (_hold) return 'On Hold';
        return 'Connected';
      case CallStateEnum.FAILED:
        return 'Failed';
      case CallStateEnum.ENDED:
        return 'Call Ended';
      default:
        return direction == Direction.incoming ? 'Incoming Call' : 'Calling...';
    }
  }

  // -------- BUILD --------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _buildContent()),
        _buildActionButtons(),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildSingleCallAvatar(String seed, String? thumbnailPath) {
    final isSpeaking = _smoothedSingleRms > _speechThreshold;
    final intensity = isSpeaking
        ? ((_smoothedSingleRms - _speechThreshold) /
                (_rmsMax - _speechThreshold))
            .clamp(0.0, 1.0)
        : 0.0;

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final v = _pulseAnimation.value;
        final vInv = 1.0 - v;
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: intensity > 0
                ? [
                    BoxShadow(
                      color: AppColors.green
                          .withValues(alpha: 0.12 + 0.18 * intensity),
                      blurRadius: 6 + 10 * intensity,
                      spreadRadius: 1 + 3 * intensity,
                    ),
                    BoxShadow(
                      color: AppColors.green
                          .withValues(alpha: (0.08 + 0.22 * intensity) * v),
                      blurRadius: 18 + 16 * v * intensity,
                      spreadRadius: 3 + 8 * v * intensity,
                    ),
                    BoxShadow(
                      color: AppColors.green
                          .withValues(alpha: (0.04 + 0.10 * intensity) * vInv),
                      blurRadius: 28 + 14 * vInv * intensity,
                      spreadRadius: 5 + 10 * vInv * intensity,
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      child: ContactIdenticon(
        seed: seed,
        size: 88,
        thumbnailPath: thumbnailPath,
      ),
    );
  }

  Widget _buildConferenceAvatars(
    ConferenceService conf,
    ContactService contactService,
    DemoModeService demoMode,
  ) {
    // Exclude ringing legs from the center-of-screen "conference" avatars.
    // See the comment in the voice-overlay branch above: a ringing leg is
    // a second inbound waiting on the InboundCallRouter toast, not a
    // connected peer in the current call.
    final legs =
        conf.legs.where((l) => l.state != LegState.ringing).toList();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < legs.length; i++) ...[
          () {
            final leg = legs[i];
            final match = leg.remoteNumber.isNotEmpty
                ? contactService.lookupByPhone(leg.remoteNumber)
                : null;
            final rawNameRaw =
                match?['display_name'] as String? ?? leg.displayName;
            final rawName = (rawNameRaw != null && rawNameRaw.trim().isNotEmpty)
                ? rawNameRaw
                : null;
            final seed = rawName ?? leg.remoteNumber;
            final nameIsPhone = rawName != null &&
                rawName.replaceAll(RegExp(r'[^\d]'), '').length >= 7 &&
                RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(rawName);
            final hasRealName = rawName != null && !nameIsPhone;
            final label = hasRealName
                ? demoMode.maskDisplayName(rawName)
                : demoMode.maskPhone(leg.remoteNumber);
            final phoneLabel =
                hasRealName ? demoMode.maskPhone(leg.remoteNumber) : null;

            final smoothRms =
                i < _smoothedLevels.length ? _smoothedLevels[i] : 0.0;
            final isSpeaking = smoothRms > _speechThreshold;
            final intensity = isSpeaking
                ? ((smoothRms - _speechThreshold) /
                        (_rmsMax - _speechThreshold))
                    .clamp(0.0, 1.0)
                : 0.0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      final v = _pulseAnimation.value;
                      final vInv = 1.0 - v;
                      return Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: intensity > 0
                              ? [
                                  BoxShadow(
                                    color: AppColors.green.withValues(
                                        alpha: 0.12 + 0.18 * intensity),
                                    blurRadius: 4 + 8 * intensity,
                                    spreadRadius: 1 + 2 * intensity,
                                  ),
                                  BoxShadow(
                                    color: AppColors.green.withValues(
                                        alpha: (0.08 + 0.22 * intensity) * v),
                                    blurRadius: 14 + 14 * v * intensity,
                                    spreadRadius: 2 + 6 * v * intensity,
                                  ),
                                  BoxShadow(
                                    color: AppColors.green.withValues(
                                        alpha:
                                            (0.04 + 0.10 * intensity) * vInv),
                                    blurRadius: 22 + 10 * vInv * intensity,
                                    spreadRadius: 4 + 8 * vInv * intensity,
                                  ),
                                ]
                              : null,
                        ),
                        child: child,
                      );
                    },
                    child: ContactIdenticon(
                      seed: seed,
                      size: 76,
                      thumbnailPath: match?['thumbnail_path'] as String?,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      if (phoneLabel != null)
                        Text(
                          phoneLabel,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }(),
        ],
      ],
    );
  }

  Widget _buildContent() {
    final stackWidgets = <Widget>[];

    if (!voiceOnly && _remoteStream != null) {
      stackWidgets.add(Center(
        child: RTCVideoView(
          _remoteRenderer!,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ));
    }

    if (!voiceOnly && _localStream != null && _showLocalVideo) {
      stackWidgets.add(AnimatedContainer(
        height: _localVideoHeight,
        width: _localVideoWidth,
        alignment: Alignment.topRight,
        duration: const Duration(milliseconds: 300),
        margin: _localVideoMargin,
        child: RTCVideoView(
          _localRenderer!,
          mirror: _mirror,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ));
    }

    // Voice / pre-connect overlay
    if (voiceOnly || !_callConfirmed) {
      final contactService = context.read<ContactService>();
      final demoMode = context.watch<DemoModeService>();
      final conf = context.watch<ConferenceService>();
      // A "ringing" leg is one that hasn't been accepted yet — typically a
      // second inbound call waiting on the InboundCallRouter toast. It
      // lives in conf so the agent panel can render a ringing row, but the
      // main call screen must NOT treat it as a fellow conference
      // participant (that's the "multiple participants in the same call"
      // bug). Only legs that have actually connected count as conference
      // slots for the center avatars.
      final activeLegCount =
          conf.legs.where((l) => l.state != LegState.ringing).length;
      final isConference = activeLegCount >= 2;

      if (isConference) {
        _startConfLevelPolling();
        _stopSingleLevelPolling();
      } else {
        _stopConfLevelPolling();
        if (_callConfirmed && !_hold) {
          _startSingleLevelPolling();
        } else {
          _stopSingleLevelPolling();
        }
      }

      final matchedContact = remoteIdentity != null
          ? contactService.lookupByPhone(remoteIdentity!)
          : null;
      final rawContactName = matchedContact?['display_name'] as String?;
      final nameIsPhone = rawContactName != null &&
          rawContactName.replaceAll(RegExp(r'[^\d]'), '').length >= 7 &&
          RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(rawContactName);
      final contactName = (rawContactName != null && !nameIsPhone)
          ? demoMode.maskDisplayName(rawContactName)
          : null;
      final formattedRemote =
          remoteIdentity != null ? demoMode.maskPhone(remoteIdentity!) : null;

      stackWidgets.add(
        Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status + timer row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isConference && conf.hasConference
                          ? 'In Conference'
                          : _stateLabel +
                              (_hold
                                  ? ' by ${_holdOriginator?.name ?? 'unknown'}'
                                  : ''),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<String>(
                      valueListenable: _timeLabel,
                      builder: (context, value, _) {
                        if (value.isEmpty) return const SizedBox.shrink();
                        return Text(
                          value,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                            fontFamily: AppColors.timerFontFamily,
                            fontFamilyFallback:
                                AppColors.timerFontFamilyFallback,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (isConference)
                  _buildConferenceAvatars(conf, contactService, demoMode)
                else
                  _buildSingleCallAvatar(
                    rawContactName ?? remoteIdentity ?? '?',
                    matchedContact?['thumbnail_path'] as String?,
                  ),
                const SizedBox(height: 20),
                if (!isConference) ...[
                  if (contactName != null) ...[
                    Text(
                      contactName,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formattedRemote ?? '',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ] else
                    Text(
                      formattedRemote ?? 'Unknown',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (_callConfirmed && !voiceOnly) {
      stackWidgets.add(
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: ValueListenableBuilder<String>(
              valueListenable: _timeLabel,
              builder: (context, value, _) {
                if (value.isEmpty) return const SizedBox.shrink();
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.card.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                      fontFamily: AppColors.timerFontFamily,
                      fontFamilyFallback: AppColors.timerFontFamilyFallback,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    return Stack(children: stackWidgets);
  }

  Widget _buildActionButtons() {
    if (_showNumPad) return _buildDtmfPad();

    final conf = context.watch<ConferenceService>();
    final actions = <Widget>[];
    final bottomRow = <Widget>[];

    switch (_state) {
      case CallStateEnum.NONE:
      case CallStateEnum.CONNECTING:
      case CallStateEnum.CALL_INITIATION:
        if (direction == Direction.incoming) {
          bottomRow.add(_circleBtn(
              Icons.phone, AppColors.green, 'Accept', _handleAccept));
          bottomRow.add(_circleBtn(
              Icons.call_end, AppColors.red, 'Decline', _handleHangup));
        } else {
          bottomRow.add(_circleBtn(
              Icons.call_end, AppColors.red, 'Cancel', _handleHangup));
        }
        break;

      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        // Row 1: Mute - Hold - Record - Transfer - Add Call
        actions.addAll([
          ActionButton(
            title: _softMute ? 'Unmute' : 'Mute',
            icon: _softMute ? Icons.mic_off : Icons.mic,
            checked: _softMute,
            onPressed: _softMuteAudio,
            onLongPress: _muteAudio,
          ),
          ActionButton(
            title: (conf.hasConference ? false : _hold) ? 'Resume' : 'Hold',
            icon: (conf.hasConference ? false : _hold)
                ? Icons.play_arrow
                : Icons.pause,
            checked: conf.hasConference ? false : _hold,
            onPressed: _handleHold,
          ),
          if (voiceOnly)
            ActionButton(
              title: _isRecording ? _recLabel : 'Record',
              icon:
                  _isRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
              checked: _isRecording,
              fillColor: _isRecording ? AppColors.red : null,
              titleStyle: _isRecording
                  ? TextStyle(
                      fontFamily: AppColors.timerFontFamily,
                      fontFamilyFallback: AppColors.timerFontFamilyFallback,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )
                  : null,
              onPressed: _toggleRecording,
            )
          else
            ActionButton(
              title: _videoMuted ? 'Cam On' : 'Cam Off',
              icon: _videoMuted ? Icons.videocam : Icons.videocam_off,
              checked: _videoMuted,
              onPressed: _muteVideo,
            ),
          ActionButton(
            title: 'Transfer',
            icon: Icons.phone_forwarded,
            onPressed: _handleTransfer,
          ),
          ActionButton(
            title: 'Add Call',
            iconWidget: Add2CallIcon(color: AppColors.textSecondary),
            onPressed:
                _addCallReady && !conf.atCapacity ? _handleAddCall : null,
          ),
        ]);
        // Row 2: Contact - Keypad - [Hangup] - Clone - Message
        final hasExistingContact = remoteIdentity != null &&
            context.read<ContactService>().lookupByPhone(remoteIdentity!) !=
                null;
        bottomRow.addAll([
          ActionButton(
            title: 'Contact',
            icon: hasExistingContact
                ? Icons.person_outline_rounded
                : Icons.person_add_outlined,
            onPressed: _handleAddContact,
          ),
          if (voiceOnly)
            ActionButton(
              title: 'Keypad',
              icon: Icons.dialpad,
              onPressed: _handleKeyPad,
            )
          else
            ActionButton(
              title: 'Flip',
              icon: Icons.switch_video,
              onPressed: _switchCamera,
            ),
          _circleBtn(Icons.call_end, AppColors.red, '', _handleHangup),
          if (voiceOnly && _ttsConfig != null && _ttsConfig!.isConfigured)
            _isSampling
                ? ActionButton(
                    title: _sampleLabel,
                    icon: Icons.stop_rounded,
                    checked: true,
                    fillColor: AppColors.accent,
                    onPressed: () => _stopVoiceSample(),
                  )
                : _VoiceCloneMouthButton(
                    onSelected: (party) => _toggleVoiceSample(party),
                  )
          else
            const SizedBox(width: 48),
          ActionButton(
            title: 'Message',
            icon: Icons.message_rounded,
            onPressed: _handleSendMessage,
          ),
        ]);
        break;

      case CallStateEnum.FAILED:
      case CallStateEnum.ENDED:
        bottomRow.add(_circleBtn(Icons.call_end,
            AppColors.burntAmber.withValues(alpha: 0.4), '', () {}));
        break;

      case CallStateEnum.PROGRESS:
        if (direction == Direction.incoming) {
          bottomRow.add(_circleBtn(
              Icons.phone, AppColors.green, 'Accept', _handleAccept));
          bottomRow.add(_circleBtn(
              Icons.call_end, AppColors.red, 'Decline', _handleHangup));
        } else {
          bottomRow.add(_circleBtn(
              Icons.call_end, AppColors.red, 'Cancel', _handleHangup));
        }
        break;

      default:
        break;
    }

    Widget wrapRow(List<Widget> items) {
      return Row(
        children: items.map((w) => Expanded(child: Center(child: w))).toList(),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: wrapRow(actions),
            ),
          wrapRow(bottomRow),
        ],
      ),
    );
  }

  Widget _circleBtn(
      IconData icon, Color color, String label, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        HoverButton(
          onTap: onTap,
          borderRadius: BorderRadius.circular(32),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(icon, size: 28, color: AppColors.onAccent),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ],
      ],
    );
  }

  Widget _buildDtmfPad() {
    const labels = [
      [
        {'1': ''},
        {'2': 'ABC'},
        {'3': 'DEF'}
      ],
      [
        {'4': 'GHI'},
        {'5': 'JKL'},
        {'6': 'MNO'}
      ],
      [
        {'7': 'PQRS'},
        {'8': 'TUV'},
        {'9': 'WXYZ'}
      ],
      [
        {'*': ''},
        {'0': '+'},
        {'#': ''}
      ],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...labels.map((row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: row
                      .map((l) => ActionButton(
                            title: l.keys.first,
                            subTitle: l.values.first,
                            onPressed: () => _handleDtmf(l.keys.first),
                            number: true,
                          ))
                      .toList(),
                ),
              )),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ActionButton(
                title: 'Back',
                icon: Icons.keyboard_arrow_down,
                onPressed: _handleKeyPad,
              ),
              _circleBtn(Icons.call_end, AppColors.red, '', _handleHangup),
              const SizedBox(width: 56),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void onNewReinvite(ReInvite event) {
    if (event.accept == null || event.reject == null) return;

    // Audio-only re-INVITEs are handled globally by DialPadWidget so they
    // are accepted even when no CallScreen is mounted. Only handle video
    // re-INVITEs here (user prompt / auto-accept when already in video).
    if (!(event.hasVideo ?? false)) return;

    if (voiceOnly) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Video Request'),
          content: Text('$remoteIdentity wants to switch to video'),
          actions: [
            TextButton(
              child: const Text('Decline'),
              onPressed: () {
                event.reject!.call({'status_code': 607});
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Accept'),
              onPressed: () {
                event.accept!.call({});
                setState(() {
                  call!.voiceOnly = false;
                  _resizeLocalVideo();
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      );
    } else {
      debugPrint(
          '[CallScreen] Auto-accepting video re-INVITE (already in video mode)');
      event.accept!({});
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}
}

class _VoiceCloneMouthButton extends StatelessWidget {
  final ValueChanged<String> onSelected;
  const _VoiceCloneMouthButton({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip: 'Clone voice',
          offset: const Offset(0, -100),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: AppColors.surface,
          onSelected: onSelected,
          itemBuilder: (_) => [
            _item('host', Icons.person_rounded, 'Sample Me'),
            _item('remote', Icons.group_rounded, 'Sample Them'),
          ],
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.card,
              border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.5), width: 0.5),
            ),
            child: Center(
              child: CustomPaint(
                size: const Size(24, 20),
                painter: _CallScreenMouthPainter(color: AppColors.accent),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Clone',
          style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  static PopupMenuEntry<String> _item(
      String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.accent),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

/// Open mouth icon: upper lip with cupid's bow, lower lip curve, tongue hint.
class _CallScreenMouthPainter extends CustomPainter {
  final Color color;
  _CallScreenMouthPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    // Upper lip with cupid's bow dip in the center
    final upper = Path()
      ..moveTo(w * 0.02, h * 0.38)
      ..quadraticBezierTo(w * 0.15, h * 0.05, w * 0.35, h * 0.15)
      ..quadraticBezierTo(w * 0.42, h * 0.22, w * 0.5, h * 0.28)
      ..quadraticBezierTo(w * 0.58, h * 0.22, w * 0.65, h * 0.15)
      ..quadraticBezierTo(w * 0.85, h * 0.05, w * 0.98, h * 0.38);

    // Lower lip — open mouth curve
    final lower = Path()
      ..moveTo(w * 0.02, h * 0.38)
      ..quadraticBezierTo(w * 0.5, h * 1.15, w * 0.98, h * 0.38);

    // Horizontal line across the mouth opening (teeth line)
    final teeth = Path()
      ..moveTo(w * 0.12, h * 0.42)
      ..lineTo(w * 0.88, h * 0.42);

    // Tongue hint — small bump at bottom center
    final tongue = Path()
      ..moveTo(w * 0.32, h * 0.72)
      ..quadraticBezierTo(w * 0.5, h * 0.88, w * 0.68, h * 0.72);

    canvas.drawPath(upper, paint);
    canvas.drawPath(lower, paint);
    canvas.drawPath(teeth, paint);
    canvas.drawPath(tongue, paint);
  }

  @override
  bool shouldRepaint(_CallScreenMouthPainter old) => old.color != color;
}
