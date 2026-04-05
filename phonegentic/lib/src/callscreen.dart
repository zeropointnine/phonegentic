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
import 'audio_device_service.dart';
import 'calendar_sync_service.dart';
import 'call_history_service.dart';
import 'conference/conference_service.dart';
import 'contact_service.dart';
import 'db/call_history_db.dart';
import 'demo_mode_service.dart';
import 'messaging/messaging_service.dart';
import 'messaging/phone_numbers.dart';
import 'tear_sheet_service.dart';
import 'models/agent_context.dart';
import 'theme_provider.dart';
import 'widgets/action_button.dart';
import 'widgets/add_call_modal.dart';
import 'widgets/audio_device_sheet.dart';
import 'widgets/phonegentic_logo.dart';
import 'widgets/voice_clone_modal.dart';

class CallScreenWidget extends StatefulWidget {
  final SIPUAHelper? _helper;
  final Call? _call;
  final VoidCallback? onDismiss;

  CallScreenWidget(this._helper, this._call, {Key? key, this.onDismiss})
      : super(key: key);

  @override
  State<CallScreenWidget> createState() => _MyCallScreenWidget();
}

class _MyCallScreenWidget extends State<CallScreenWidget>
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
  bool _videoMuted = false;
  bool _hold = false;
  bool _mirror = true;
  Originator? _holdOriginator;
  bool _callConfirmed = false;
  bool _enteredCallMode = false;
  bool _addCallReady = false;
  Timer? _addCallGraceTimer;
  CallStateEnum _state = CallStateEnum.NONE;

  String? _recordingPath;
  bool _isRecording = false;
  Timer? _recTimer;
  int _recSeconds = 0;
  String _recLabel = '0:00';
  int? _endingCallRecordId;

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
  bool get voiceOnly => call!.voiceOnly && !call!.remote_has_video;
  String? get remoteIdentity => call!.remote_identity;
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
        return CallPhase.answered;
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
    _initRenderers();
    helper!.addSipUaHelperListener(this);
    _startTimer();
    _loadTtsConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCallState());
  }

  void _syncCallState() {
    if (call == null) return;
    final s = call!.state;
    if (s == CallStateEnum.CONFIRMED || s == CallStateEnum.ACCEPTED) {
      _state = s;
      _callConfirmed = true;
      _enteredCallMode = true;
      _addCallReady = true;
      _pushCallPhase(s);
    } else if (s == CallStateEnum.HOLD || s == CallStateEnum.UNHOLD) {
      _state = s;
      _callConfirmed = true;
      _hold = s == CallStateEnum.HOLD;
      _enteredCallMode = true;
      _addCallReady = true;
      _pushCallPhase(s);
    } else if (s != CallStateEnum.NONE) {
      _state = s;
    }
  }

  Future<void> _loadTtsConfig() async {
    final config = await AgentConfigService.loadTtsConfig();
    if (mounted) setState(() => _ttsConfig = config);
  }

  @override
  void deactivate() {
    super.deactivate();
    _addCallGraceTimer?.cancel();
    helper!.removeSipUaHelperListener(this);
    _disposeRenderers();
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

  void _disposeRenderers() {
    if (_localRenderer != null) {
      _localRenderer!.dispose();
      _localRenderer = null;
    }
    if (_remoteRenderer != null) {
      _remoteRenderer!.dispose();
      _remoteRenderer = null;
    }
  }

  @override
  void callStateChanged(Call call, CallState callState) {
    if (call.id != widget._call?.id) return;
    if (!mounted) return;

    // Capture the call record ID before _pushCallPhase clears it, so
    // _stopRecording can save the recording path after the file is finalized.
    if (callState.state == CallStateEnum.ENDED ||
        callState.state == CallStateEnum.FAILED) {
      final history =
          Provider.of<CallHistoryService>(context, listen: false);
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
    if (callState.state != CallStateEnum.STREAM) {
      _state = callState.state;
    }
    switch (callState.state) {
      case CallStateEnum.STREAM:
        _handleStreams(callState);
        break;
      case CallStateEnum.ENDED:
      case CallStateEnum.FAILED:
        _stopRecording();
        final tearSheet =
            Provider.of<TearSheetService>(context, listen: false);
        if (tearSheet.isActive) {
          final status = callState.state == CallStateEnum.FAILED
              ? 'failed'
              : 'completed';
          tearSheet.onCallEnded(status);
        }
        _backToDialPad();
        break;
      case CallStateEnum.CONFIRMED:
        setState(() => _callConfirmed = true);
        _enterCallMode();
        _maybeAutoRecord();
        _startAddCallGrace();
        break;
      default:
        setState(() {});
    }
  }

  @override
  void transportStateChanged(TransportState state) {}

  @override
  void registrationStateChanged(RegistrationState state) {}

  void _cleanUp() {
    if (_localStream == null) return;
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream!.dispose();
    _localStream = null;
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
      debugPrint('[CallScreen] enterCallMode — AI audio routed through WebRTC pipeline');
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
      if (mounted) setState(() => _recLabel = '$m:${s.toString().padLeft(2, '0')}');
    });
    if (mounted) setState(() {});

    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir = Directory(p.join(dir.path, 'phonegentic', 'recordings'));
      await recDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _recordingPath = p.join(recDir.path, 'call_$timestamp.wav');

      await _tapChannel.invokeMethod(
          'startCallRecording', {'path': _recordingPath});
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
          debugPrint(
              '[CallScreen] Recording path saved for record #$recordId');
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
      if (mounted) setState(() => _sampleLabel = '$m:${s.toString().padLeft(2, '0')}');
    });
    if (mounted) setState(() {});

    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir =
          Directory(p.join(dir.path, 'phonegentic', 'voice_samples'));
      await recDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _samplePath =
          p.join(recDir.path, 'sample_${party}_$timestamp.wav');

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
    _samplePath = null;
    _sampleParty = null;
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
    call!.hangup({'status_code': 603});
    _timer.cancel();
  }

  void _handleAccept() async {
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
            decoration:
                const InputDecoration(hintText: 'URI or Username'),
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

  bool _showAddCallModal = false;
  bool _placingConferenceLeg = false;

  void _startAddCallGrace() {
    _addCallGraceTimer?.cancel();
    _addCallGraceTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _addCallReady = true);
    });
  }

  void _handleAddCall() {
    if (!_addCallReady) return;
    if (!_hold && call != null) {
      _handleHold();
    }
    setState(() => _showAddCallModal = true);
  }

  void _closeAddCallModal() {
    setState(() {
      _showAddCallModal = false;
      _placingConferenceLeg = false;
    });
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

  void _handleDtmf(String tone) => call!.sendDTMF(tone);

  void _handleKeyPad() => setState(() => _showNumPad = !_showNumPad);

  void _handleVideoUpgrade() {
    if (voiceOnly) {
      setState(() => call!.voiceOnly = false);
      helper!.renegotiate(
          call: call!,
          voiceOnly: false,
          done: (IncomingMessage? msg) {});
    } else {
      helper!.renegotiate(
          call: call!,
          voiceOnly: true,
          done: (IncomingMessage? msg) {});
    }
  }

  void _showAudioDevices() {
    showAudioDeviceSheet(
      context,
      onDeviceSelected: _onAudioDeviceSelected,
    );
  }

  Future<void> _onAudioDeviceSelected(AudioDevice device, bool isOutput) async {
    if (isOutput) {
      await AudioDeviceService.setDefaultOutputDevice(device.id);
    } else {
      await AudioDeviceService.setDefaultInputDevice(device.id);
      if (_localStream != null) {
        final newStream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'deviceId': device.uid,
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
            'channelCount': 2,
          },
          'video': false,
        });
        final newTrack = newStream.getAudioTracks().first;
        final oldTrack = _localStream!.getAudioTracks().first;
        final senders = await call?.peerConnection?.getSenders() ?? [];
        for (final sender in senders) {
          if (sender.track?.kind == 'audio') {
            await sender.replaceTrack(newTrack);
            break;
          }
        }
        await oldTrack.stop();
        _localStream!.removeTrack(oldTrack);
        _localStream!.addTrack(newTrack);
        newStream.removeTrack(newTrack);
        await newStream.dispose();
      }
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
    return Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              _buildCallTopBar(),
              Expanded(child: _buildContent()),
              _buildActionButtons(),
              const SizedBox(height: 32),
            ],
          ),
        ),
        if (_showAddCallModal)
          Positioned.fill(
            child: AddCallModal(
              onCall: _placeConferenceLeg,
              onClose: _closeAddCallModal,
            ),
          ),
      ],
    );
  }

  static const double _collapseThreshold = 480;

  Widget _buildCallTopBar() {
    final agent = context.watch<AgentService>();
    final conf = context.watch<ConferenceService>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _collapseThreshold;
        return Padding(
          padding:
              const EdgeInsets.only(left: 90, right: 16, top: 18, bottom: 15),
          child: Row(
            children: [
              const PhonegenticLogo(size: 30),
              const SizedBox(width: 10),
              Text(
                'Phonegentic',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'AI',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: -0.5,
                  shadows: [
                    Shadow(
                      color: AppColors.phosphor.withOpacity(0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              _buildCallConferenceBadge(conf),
              if (agent.whisperMode)
                _buildWhisperBadge(),
              const Spacer(),
              if (wide) ...[
                _buildBarBtn(
                  icon: Icons.chat_bubble_outline_rounded,
                  onTap: () =>
                      context.read<MessagingService>().toggleOpen(),
                  active: context.read<MessagingService>().isOpen,
                  badge: context.read<MessagingService>().unreadCount,
                ),
                const SizedBox(width: 4),
                _buildBarBtn(
                  icon: Icons.receipt_long_rounded,
                  onTap: () {
                    final ts = context.read<TearSheetService>();
                    ts.isActive ? ts.dismissSheet() : ts.openEditor();
                  },
                  active: context.read<TearSheetService>().isActive,
                ),
                const SizedBox(width: 4),
                _buildBarBtn(
                  icon: Icons.contacts_rounded,
                  onTap: () =>
                      context.read<ContactService>().toggleContacts(),
                ),
                const SizedBox(width: 4),
                _buildBarBtn(
                  icon: Icons.history_rounded,
                  onTap: () =>
                      context.read<CallHistoryService>().toggleHistory(),
                ),
                const SizedBox(width: 4),
                _buildBarBtn(
                  icon: Icons.headphones_rounded,
                  onTap: _showAudioDevices,
                ),
                const SizedBox(width: 4),
              ],
              _buildCallMenuButton(context, collapsed: !wide),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWhisperBadge() {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.burntAmber.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: AppColors.burntAmber.withOpacity(0.4), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hearing_disabled,
                size: 12, color: AppColors.burntAmber),
            const SizedBox(width: 4),
            Text(
              'Whisper',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.burntAmber,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallConferenceBadge(ConferenceService conf) {
    if (!conf.hasConference && conf.legCount < 2) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: conf.hasConference
              ? AppColors.green.withOpacity(0.12)
              : AppColors.burntAmber.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: conf.hasConference
                ? AppColors.green.withOpacity(0.3)
                : AppColors.burntAmber.withOpacity(0.3),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              conf.hasConference
                  ? Icons.groups_rounded
                  : Icons.call_split_rounded,
              size: 12,
              color: conf.hasConference
                  ? AppColors.green
                  : AppColors.burntAmber,
            ),
            const SizedBox(width: 4),
            Text(
              conf.hasConference
                  ? 'Conference (${conf.legCount})'
                  : '${conf.legCount} calls',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: conf.hasConference
                    ? AppColors.green
                    : AppColors.burntAmber,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    int badge = 0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: active
                  ? AppColors.accent.withOpacity(0.12)
                  : AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active
                    ? AppColors.accent.withOpacity(0.4)
                    : AppColors.border.withOpacity(0.5),
                width: 0.5,
              ),
            ),
            child: Icon(icon,
                size: 16,
                color:
                    active ? AppColors.accent : AppColors.textSecondary),
          ),
          if (badge > 0)
            Positioned(
              top: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                ),
                constraints:
                    const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onAccent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCallMenuButton(BuildContext context, {bool collapsed = false}) {
    return PopupMenuButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'tear_sheet':
            final ts = context.read<TearSheetService>();
            ts.isActive ? ts.dismissSheet() : ts.openEditor();
            break;
          case 'contacts':
            context.read<ContactService>().toggleContacts();
            break;
          case 'history':
            context.read<CallHistoryService>().toggleHistory();
            break;
          case 'audio':
            _showAudioDevices();
            break;
          case 'messages':
            context.read<MessagingService>().toggleOpen();
            break;
          case 'calendar':
            context.read<CalendarSyncService>().toggleOpen();
            break;
          case 'settings':
            Navigator.pushNamed(context, '/register');
            break;
        }
      },
      icon: Icon(Icons.more_horiz, color: AppColors.textSecondary, size: 20),
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.border, width: 0.5),
      ),
      itemBuilder: (_) => [
        if (collapsed) ...[
          PopupMenuItem(
            value: 'history',
            child: Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Call History', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'contacts',
            child: Row(
              children: [
                Icon(Icons.contacts_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Contacts', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'tear_sheet',
            child: Row(
              children: [
                Icon(Icons.receipt_long_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Text(
                  context.read<TearSheetService>().isActive
                      ? 'Dismiss Tear Sheet'
                      : 'New Tear Sheet',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'audio',
            child: Row(
              children: [
                Icon(Icons.headphones_rounded,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                const Text('Audio Devices', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
        PopupMenuItem(
          value: 'messages',
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Text(
                'Messages${context.read<MessagingService>().unreadCount > 0 ? ' (${context.read<MessagingService>().unreadCount})' : ''}',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'calendar',
          child: Row(
            children: [
              Icon(Icons.calendar_month_rounded,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              const Text('Calendar', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              const Text('Settings', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
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

    if (!voiceOnly && _localStream != null) {
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
      final matchedContact = remoteIdentity != null
          ? contactService.lookupByPhone(remoteIdentity!)
          : null;
      final rawContactName =
          matchedContact?['display_name'] as String?;
      final contactName = rawContactName != null
          ? demoMode.maskDisplayName(rawContactName)
          : null;
      final displayInitial = (contactName ?? remoteIdentity ?? '?')
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      final initial = displayInitial.isEmpty
          ? '?'
          : displayInitial.substring(0, 1).toUpperCase();

      final formattedRemote = remoteIdentity != null
          ? demoMode.maskPhone(remoteIdentity!)
          : null;

      stackWidgets.add(
        Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent.withOpacity(0.15),
                    border: Border.all(
                        color: AppColors.accent.withOpacity(0.3), width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w300,
                        color: AppColors.accentLight,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
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
                const SizedBox(height: 8),
                Text(
                  _stateLabel +
                      (_hold
                          ? ' by ${_holdOriginator?.name ?? 'unknown'}'
                          : ''),
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 6),
                ValueListenableBuilder<String>(
                  valueListenable: _timeLabel,
                  builder: (context, value, _) {
                    return Text(
                      value,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(children: stackWidgets);
  }

  Widget _buildActionButtons() {
    if (_showNumPad) return _buildDtmfPad();

    final actions = <Widget>[];
    final bottomRow = <Widget>[];

    switch (_state) {
      case CallStateEnum.NONE:
      case CallStateEnum.CONNECTING:
        if (direction == Direction.incoming) {
          bottomRow.add(_circleBtn(
              Icons.phone, AppColors.green, 'Accept', _handleAccept));
          bottomRow
              .add(_circleBtn(Icons.call_end, AppColors.red, 'Decline', _handleHangup));
        } else {
          bottomRow
              .add(_circleBtn(Icons.call_end, AppColors.red, 'Cancel', _handleHangup));
        }
        break;

      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        actions.addAll([
          ActionButton(
            title: _softMute ? 'Unmute' : 'Mute',
            icon: _softMute ? Icons.mic_off : Icons.mic,
            checked: _softMute,
            onPressed: _softMuteAudio,
            onLongPress: _muteAudio,
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
          if (voiceOnly)
            ActionButton(
              title: _isRecording ? _recLabel : 'Record',
              icon: _isRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
              checked: _isRecording,
              fillColor: _isRecording ? AppColors.red : null,
              onPressed: _toggleRecording,
            )
          else
            ActionButton(
              title: _videoMuted ? 'Cam On' : 'Cam Off',
              icon: _videoMuted ? Icons.videocam : Icons.videocam_off,
              checked: _videoMuted,
              onPressed: _muteVideo,
            ),
        ]);
        if (voiceOnly && _ttsConfig != null && _ttsConfig!.isConfigured)
          actions.addAll([
            ActionButton(
              title: _isSampling && _sampleParty == 'host'
                  ? _sampleLabel
                  : 'Sample Me',
              icon: _isSampling && _sampleParty == 'host'
                  ? Icons.stop_rounded
                  : Icons.person_rounded,
              checked: _isSampling && _sampleParty == 'host',
              fillColor: _isSampling && _sampleParty == 'host'
                  ? AppColors.accent
                  : null,
              onPressed: () => _toggleVoiceSample('host'),
            ),
            ActionButton(
              title: _isSampling && _sampleParty == 'remote'
                  ? _sampleLabel
                  : 'Sample Them',
              icon: _isSampling && _sampleParty == 'remote'
                  ? Icons.stop_rounded
                  : Icons.group_rounded,
              checked: _isSampling && _sampleParty == 'remote',
              fillColor: _isSampling && _sampleParty == 'remote'
                  ? AppColors.accent
                  : null,
              onPressed: () => _toggleVoiceSample('remote'),
            ),
          ]);
        bottomRow.addAll([
          ActionButton(
            title: _hold ? 'Resume' : 'Hold',
            icon: _hold ? Icons.play_arrow : Icons.pause,
            checked: _hold,
            onPressed: _handleHold,
          ),
          ActionButton(
            title: 'Add Call',
            icon: Icons.person_add,
            onPressed: _addCallReady ? _handleAddCall : null,
          ),
          _circleBtn(Icons.call_end, AppColors.red, '', _handleHangup),
          ActionButton(
            title: 'Transfer',
            icon: Icons.phone_forwarded,
            onPressed: _handleTransfer,
          ),
        ]);
        break;

      case CallStateEnum.FAILED:
      case CallStateEnum.ENDED:
        bottomRow.add(_circleBtn(Icons.call_end, AppColors.burntAmber.withOpacity(0.4), '', () {}));
        break;

      case CallStateEnum.PROGRESS:
        bottomRow
            .add(_circleBtn(Icons.call_end, AppColors.red, 'Cancel', _handleHangup));
        break;

      default:
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: actions),
            ),
          Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: bottomRow),
        ],
      ),
    );
  }

  Widget _circleBtn(
      IconData icon, Color color, String label, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.35),
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
              style:
                  TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ],
      ],
    );
  }

  Widget _buildDtmfPad() {
    const labels = [
      [{'1': ''}, {'2': 'ABC'}, {'3': 'DEF'}],
      [{'4': 'GHI'}, {'5': 'JKL'}, {'6': 'MNO'}],
      [{'7': 'PQRS'}, {'8': 'TUV'}, {'9': 'WXYZ'}],
      [{'*': ''}, {'0': '+'}, {'#': ''}],
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

    // Auto-accept audio-only re-INVITEs (session timer refresh, conference
    // media redirect, hold/unhold from remote). Without this the 200 OK is
    // never sent and Telnyx tears down the call after the INVITE timeout.
    if (!(event.hasVideo ?? false)) {
      debugPrint('[CallScreen] Auto-accepting audio re-INVITE');
      event.accept!({});
      return;
    }

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
      debugPrint('[CallScreen] Auto-accepting video re-INVITE (already in video mode)');
      event.accept!({});
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}
}
