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
import 'call_history_service.dart';
import 'contact_service.dart';
import 'db/call_history_db.dart';
import 'tear_sheet_service.dart';
import 'models/agent_context.dart';
import 'theme_provider.dart';
import 'widgets/action_button.dart';
import 'widgets/audio_device_sheet.dart';

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
  CallStateEnum _state = CallStateEnum.NONE;

  String? _recordingPath;
  bool _isRecording = false;
  Timer? _recTimer;
  int _recSeconds = 0;
  String _recLabel = '0:00';
  int? _endingCallRecordId;

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
        ? _bootContext.speakers.length + 1 // +1 for the agent
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
  }

  @override
  void deactivate() {
    super.deactivate();
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
    _recTimer?.cancel();
    _recTimer = null;
    _exitCallMode();
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
      if (_localRenderer != null) {
        _localRenderer!.srcObject =
            (stream != null && stream.getVideoTracks().isNotEmpty)
                ? stream
                : null;
      }
      if (!kIsWeb &&
          !WebRTC.platformIsDesktop &&
          event.stream?.getAudioTracks().isNotEmpty == true) {
        event.stream?.getAudioTracks().first.enableSpeakerphone(false);
      }
      _localStream = stream;
    }
    if (event.originator == Originator.remote) {
      if (_remoteRenderer != null) {
        _remoteRenderer!.srcObject =
            (stream != null && stream.getVideoTracks().isNotEmpty)
                ? stream
                : null;
      }
      _remoteStream = stream;
    }
    setState(() => _resizeLocalVideo());
  }

  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');

  Future<void> _enterCallMode() async {
    try {
      await _tapChannel.invokeMethod('enterCallMode');
      debugPrint('[CallScreen] enterCallMode — AI audio routed through WebRTC pipeline');
    } catch (e) {
      debugPrint('[CallScreen] enterCallMode failed: $e');
    }
  }

  Future<void> _exitCallMode() async {
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
      setState(() => _recLabel = '$m:${s.toString().padLeft(2, '0')}');
    });
    setState(() {});

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
    setState(() {});

    try {
      await _tapChannel.invokeMethod('stopCallRecording');
      debugPrint('[CallScreen] Recording stopped → $_recordingPath');
    } catch (e) {
      debugPrint('[CallScreen] Recording stop failed: $e');
    }

    if (_recordingPath != null) {
      final history =
          Provider.of<CallHistoryService>(context, listen: false);
      final recordId = history.activeCallRecordId ?? _endingCallRecordId;
      if (recordId != null) {
        try {
          await CallHistoryDb.updateRecordingPath(recordId, _recordingPath!);
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

  Future<void> _maybeAutoRecord() async {
    final config = await AgentConfigService.loadCallRecordingConfig();
    if (config.autoRecord) {
      await _startRecording();
      _agent.announceRecording();
      setState(() {});
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
    return SafeArea(
      child: Column(
        children: [
          _buildCallTopBar(),
          Expanded(child: _buildContent()),
          _buildActionButtons(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildCallTopBar() {
    final agent = context.watch<AgentService>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (agent.whisperMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: AppColors.burntAmber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
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
          const Spacer(),
          GestureDetector(
            onTap: () =>
                context.read<CallHistoryService>().toggleHistory(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Icon(Icons.history_rounded,
                  size: 18, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _showAudioDevices,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.border.withOpacity(0.5), width: 0.5),
              ),
              child: Icon(Icons.headphones_rounded,
                  size: 18, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
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
      final matchedContact = remoteIdentity != null
          ? contactService.lookupByPhone(remoteIdentity!)
          : null;
      final contactName =
          matchedContact?['display_name'] as String?;
      final displayInitial = (contactName ?? remoteIdentity ?? '?')
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      final initial = displayInitial.isEmpty
          ? '?'
          : displayInitial.substring(0, 1).toUpperCase();

      stackWidgets.add(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar
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
                  remoteIdentity ?? '',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
              ] else
                Text(
                  remoteIdentity ?? 'Unknown',
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
        bottomRow.addAll([
          ActionButton(
            title: _hold ? 'Resume' : 'Hold',
            icon: _hold ? Icons.play_arrow : Icons.pause,
            checked: _hold,
            onPressed: _handleHold,
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
        bottomRow.add(_circleBtn(Icons.call_end, Colors.grey, '', () {}));
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
            child: Icon(icon, size: 28, color: Colors.white),
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
    if (voiceOnly && (event.hasVideo ?? false)) {
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
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}
}
