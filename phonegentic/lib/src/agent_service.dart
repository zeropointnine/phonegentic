import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sip_ua/sip_ua.dart';

import 'agent_config_service.dart';
import 'call_history_service.dart';
import 'contact_service.dart';
import 'db/call_history_db.dart';
import 'job_function_service.dart';
import 'models/agent_context.dart';
import 'models/chat_message.dart';
import 'tear_sheet_service.dart';
import 'whisper_realtime_service.dart';

class AgentService extends ChangeNotifier {
  final WhisperRealtimeService _whisper = WhisperRealtimeService();

  bool _active = false;
  bool _muted = false;
  bool _speaking = false;
  bool _whisperMode = false;
  String _statusText = 'Initializing...';

  final Queue<double> _levels = Queue<double>();
  static const int waveformBars = 14;

  final List<ChatMessage> _messages = [];
  AgentBootContext _bootContext = AgentBootContext.trivia();

  CallPhase _callPhase = CallPhase.idle;
  int _partyCount = 1;
  String? _remoteIdentity;
  String? _remoteDisplayName;
  String? _localIdentity;
  bool _isOutbound = true;
  String? _lastDialedNumber;

  CallPhase get callPhase => _callPhase;
  int get partyCount => _partyCount;
  String? get remoteIdentity => _remoteIdentity;
  String? get remoteDisplayName => _remoteDisplayName;
  String? get localIdentity => _localIdentity;
  bool get isOutbound => _isOutbound;
  bool get hasActiveCall => _callPhase != CallPhase.idle;

  CallHistoryService? callHistory;
  ContactService? contactService;
  TearSheetService? tearSheetService;
  JobFunctionService? _jobFunctionService;
  SIPUAHelper? sipHelper;

  set jobFunctionService(JobFunctionService? svc) {
    _jobFunctionService = svc;
    _syncFromJobFunctionIfNeeded();
  }

  int? _lastSyncedJobFunctionId;

  void _syncFromJobFunctionIfNeeded() {
    final selected = _jobFunctionService?.selected;
    if (selected == null || selected.id == _lastSyncedJobFunctionId) return;
    _lastSyncedJobFunctionId = selected.id;
    _bootContext = _jobFunctionService!.buildBootContext();
    if (selected.whisperByDefault != _whisperMode) {
      _setWhisperMode(selected.whisperByDefault);
    }
    _pushInstructionsIfLive();
    notifyListeners();
  }

  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<AudioResponseEvent>? _audioSub;
  StreamSubscription<TranscriptionEvent>? _transcriptSub;
  StreamSubscription<ResponseTextEvent>? _responseTextSub;
  StreamSubscription<FunctionCallEvent>? _functionCallSub;

  String? _streamingMessageId;

  // Deduplication: skip identical transcripts arriving within a short window
  String _lastTranscriptText = '';
  DateTime _lastTranscriptTime = DateTime(2000);

  // Cooldown after agent stops speaking to let TTS drain from whisper buffer
  DateTime _speakingEndTime = DateTime(2000);
  static const _echoGuardMs = 1500;

  // Settling: buffer window after SIP CONFIRMED to filter auto-attendant/IVR
  Timer? _settleTimer;
  int _ivrHitsInSettle = 0;
  static const _settleWindowMs = 8000;
  static const _settleExtendMs = 5000;

  bool get active => _active;
  bool get muted => _muted;
  bool get speaking => _speaking;
  bool get whisperMode => _whisperMode;
  String get statusText => _statusText;
  List<double> get levels => _levels.toList();
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  WhisperRealtimeService get whisper => _whisper;
  AgentBootContext get bootContext => _bootContext;

  void _syncBootContextFromJobFunction() {
    final selected = _jobFunctionService?.selected;
    if (selected == null) return;
    _bootContext = _jobFunctionService!.buildBootContext();
    _lastSyncedJobFunctionId = selected.id;
  }

  void updateBootContext(
    AgentBootContext ctx, {
    String? jobFunctionName,
    bool? whisperByDefault,
  }) {
    _bootContext = ctx;
    if (jobFunctionName != null) {
      final mode = whisperByDefault == true ? ' (text-only)' : '';
      _messages.add(ChatMessage.system(
        'Switched to "$jobFunctionName"$mode',
      ));
    }

    if (whisperByDefault != null && whisperByDefault != _whisperMode) {
      _setWhisperMode(whisperByDefault);
    }

    notifyListeners();
    _pushInstructionsIfLive();
  }

  void _setWhisperMode(bool enabled) {
    _whisperMode = enabled;
    if (_active) {
      if (enabled) _whisper.stopResponseAudio();
      _whisper.setModalities(enabled ? ['text'] : ['text', 'audio']);
    }
  }

  Future<void> _pushInstructionsIfLive() async {
    if (!_active) return;
    _whisper.updateSessionInstructions(_bootContext.toInstructions());
  }

  Speaker get hostSpeaker =>
      _bootContext.speakers.isNotEmpty
          ? _bootContext.speakers.first
          : Speaker(role: 'Host', source: 'mic');
  Speaker get remoteSpeaker =>
      _bootContext.speakers.length > 1
          ? _bootContext.speakers[1]
          : Speaker(role: 'Remote Party 1', source: 'remote');

  AgentService() {
    _messages.add(ChatMessage.system('Agent starting...'));
    _init();
  }

  Future<void> _init() async {
    try {
      _syncBootContextFromJobFunction();

      final config = await AgentConfigService.loadVoiceConfig();
      if (!config.enabled || !config.isConfigured) {
        _statusText = 'Not configured';
        _messages.clear();
        _messages.add(ChatMessage.system('Voice agent not configured. Go to Settings > Agents to set up.'));
        notifyListeners();
        return;
      }

      _statusText = 'Connecting...';
      _messages.clear();
      _messages.add(ChatMessage.system('Connecting to AI...'));
      notifyListeners();

      final hasJobFunction = _jobFunctionService?.selected != null;
      final instructions = hasJobFunction
          ? _bootContext.toInstructions()
          : (config.instructions.isNotEmpty
              ? config.instructions
              : _bootContext.toInstructions());

      await _whisper.connect(
        apiKey: config.apiKey,
        model: config.model,
        voice: config.voice,
        instructions: instructions,
      );

      _active = _whisper.isConnected;
      _statusText = _active ? 'Connected' : 'Failed';

      if (_active) {
        // The job function may have loaded while we were connecting.
        // Re-sync and push the correct instructions now that the session is live.
        _syncBootContextFromJobFunction();
        _pushInstructionsIfLive();
      }

      _messages.clear();
      if (_active) {
        final jfName = _jobFunctionService?.selected?.name;
        final label = jfName != null ? 'Ready as "$jfName".' : 'Ready.';
        _messages.add(ChatMessage.agent(
          '$label I\'m listening to the call and can assist anytime. Type a message or just talk.',
        ));
      } else {
        _messages.add(ChatMessage.system('Failed to connect to AI agent.'));
      }
      notifyListeners();

      if (!_active) return;

      await _whisper.startAudioTap(captureInput: true, captureOutput: true);

      _levelSub = _whisper.audioLevels.listen((level) {
        _levels.addLast(level);
        while (_levels.length > waveformBars) {
          _levels.removeFirst();
        }
        notifyListeners();
      });

      _speakingSub = _whisper.speakingState.listen((isSpeaking) {
        _speaking = isSpeaking;
        _statusText = isSpeaking ? 'Speaking' : (_muted ? 'Not Listening...' : 'Listening');
        if (!isSpeaking) _speakingEndTime = DateTime.now();
        notifyListeners();
      });

      int audioChunkCount = 0;
      _audioSub = _whisper.audioResponses.listen((event) {
        if (_whisperMode) return;
        if (event.pcm16Data.isNotEmpty) {
          audioChunkCount++;
          if (audioChunkCount <= 3 || audioChunkCount % 50 == 0) {
            debugPrint('[AgentService] TTS chunk #$audioChunkCount: ${event.pcm16Data.length} bytes');
          }
          _whisper.playResponseAudio(event.pcm16Data);
        }
      });

      _transcriptSub = _whisper.transcriptions.listen(_onTranscript);
      _responseTextSub = _whisper.responseTexts.listen(_onResponseText);
      _functionCallSub = _whisper.functionCalls.listen(_onFunctionCall);

      debugPrint('[AgentService] Started: model=${config.model} voice=${config.voice}');
    } catch (e) {
      _statusText = 'Error';
      _active = false;
      _messages.add(ChatMessage.system('Error: $e'));
      debugPrint('[AgentService] Init failed: $e');
      notifyListeners();
    }
  }

  void _onTranscript(TranscriptionEvent event) async {
    if (!event.isFinal || event.text.trim().isEmpty) return;

    // Suppress transcripts while call is still setting up.
    if (_callPhase.isPreConnect) return;

    // During settling, check for IVR patterns. If detected, extend the
    // settle window. If clean speech arrives, that helps the timer expire
    // and promote to connected. Either way, don't forward to the agent.
    if (_callPhase.isSettling) {
      final text = event.text.trim();
      if (IvrDetector.isIvr(text)) {
        _ivrHitsInSettle++;
        _extendSettleTimer();
        debugPrint('[AgentService] IVR detected during settle: "$text" (hits=$_ivrHitsInSettle)');
      }
      return;
    }

    // Suppress agent echo: when the agent is speaking (or just finished),
    // its TTS audio loops back through the whisper buffer and gets
    // transcribed as input. Wait for the echo to drain.
    if (_speaking) return;
    final msSinceSpoke = DateTime.now().difference(_speakingEndTime).inMilliseconds;
    if (msSinceSpoke < _echoGuardMs) return;

    final text = event.text.trim();

    // Even after settling, filter any stray IVR fragments (e.g. the tail
    // end of "your call may be recorded for quality purposes").
    if (IvrDetector.isIvr(text)) {
      debugPrint('[AgentService] IVR filtered post-settle: "$text"');
      return;
    }

    // Deduplicate: OpenAI VAD can split the same utterance into multiple
    // items that produce near-identical completed transcriptions.
    final now = DateTime.now();
    if (text == _lastTranscriptText &&
        now.difference(_lastTranscriptTime).inMilliseconds < 3000) {
      return;
    }
    _lastTranscriptText = text;
    _lastTranscriptTime = now;

    final dominant = await _whisper.getDominantSpeaker();
    final isRemote = dominant == 'remote';
    final role = isRemote ? ChatRole.remoteParty : ChatRole.host;
    final speaker = isRemote ? remoteSpeaker : hostSpeaker;

    _messages.add(ChatMessage.transcript(
      role,
      text,
      speakerName: speaker.label,
    ));
    notifyListeners();

    callHistory?.addTranscript(
      role: isRemote ? 'remote' : 'host',
      speakerName: speaker.label,
      text: text,
    );
  }

  void _onResponseText(ResponseTextEvent event) {
    if (event.isFinal) {
    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        _messages[idx].isStreaming = false;
        if (event.text.isNotEmpty) {
          _messages[idx].text = event.text;
        }
        callHistory?.addTranscript(
          role: 'agent',
          text: _messages[idx].text,
        );
      }
      _streamingMessageId = null;
    }
    notifyListeners();
    return;
    }

    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        _messages[idx].text += event.text;
        notifyListeners();
        return;
      }
    }

    final msg = ChatMessage.agent(event.text, isStreaming: true);
    _streamingMessageId = msg.id;
    _messages.add(msg);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Function call handling (agent tools)
  // ---------------------------------------------------------------------------

  Future<void> _onFunctionCall(FunctionCallEvent event) async {
    debugPrint('[AgentService] Function call: ${event.name} args=${event.arguments}');

    String result;
    try {
      final args = jsonDecode(event.arguments) as Map<String, dynamic>;
      switch (event.name) {
        case 'search_calls':
          result = await _handleSearchCalls(args);
          break;
        case 'open_call_history':
          callHistory?.openHistory(
            query: args['search_query'] as String?,
          );
          result = 'Call history panel opened.';
          break;
        case 'make_call':
          result = await _handleMakeCall(args);
          break;
        case 'end_call':
          result = _handleEndCall();
          break;
        case 'send_dtmf':
          result = _handleSendDtmf(args);
          break;
        case 'search_contacts':
          result = await _handleSearchContacts(args);
          break;
        case 'create_tear_sheet':
          result = await _handleCreateTearSheet(args);
          break;
        default:
          result = 'Unknown function: ${event.name}';
      }
    } catch (e) {
      result = 'Error executing ${event.name}: $e';
      debugPrint('[AgentService] Function call error: $e');
    }

    if (_active) {
      _whisper.sendFunctionCallOutput(
        callId: event.callId,
        output: result,
      );
    }
  }

  Future<String> _handleSearchCalls(Map<String, dynamic> args) async {
    if (callHistory == null) return 'Call history not available.';

    DateTime? since;
    final sinceMinutes = args['since_minutes_ago'] as int?;
    if (sinceMinutes != null) {
      since = DateTime.now().subtract(Duration(minutes: sinceMinutes));
    }

    final params = CallSearchParams(
      contactName: args['contact_name'] as String?,
      minDurationSeconds: args['min_duration_seconds'] as int?,
      maxDurationSeconds: args['max_duration_seconds'] as int?,
      since: since,
      direction: args['direction'] as String?,
      status: args['status'] as String?,
    );

    final result = await callHistory!.searchAndFormat(params);

    callHistory!.openHistory();

    return result;
  }

  Future<String> _handleMakeCall(Map<String, dynamic> args) async {
    if (sipHelper == null) return 'SIP helper not available.';
    var number = args['number'] as String?;
    if (number == null || number.isEmpty) return 'No number provided.';

    // Resolve "last" / "redial" / placeholder to the actual last dialed number
    final normalized = number.toLowerCase().replaceAll(RegExp(r'[<>_]'), '').trim();
    if (normalized == 'last' ||
        normalized == 'redial' ||
        normalized == 'lastdialed' ||
        normalized == 'lastdialednumber' ||
        normalized == 'last dialed number') {
      if (_lastDialedNumber != null) {
        number = _lastDialedNumber!;
      } else {
        return 'No previous number to redial.';
      }
    }

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };
      final stream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      sipHelper!.call(number, voiceOnly: true, mediaStream: stream);
      return 'Call initiated to $number';
    } catch (e) {
      return 'Failed to make call: $e';
    }
  }

  String _handleEndCall() {
    if (sipHelper == null) return 'SIP helper not available.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call to end.';
    active.hangup();
    return 'Call ended.';
  }

  String _handleSendDtmf(Map<String, dynamic> args) {
    if (sipHelper == null) return 'SIP helper not available.';
    final tones = args['tones'] as String?;
    if (tones == null || tones.isEmpty) return 'No tones provided.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call for DTMF.';
    active.sendDTMF(tones);
    return 'Sent DTMF: $tones';
  }

  Future<String> _handleSearchContacts(Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';

    // Search contacts
    final contacts = query.isEmpty
        ? await CallHistoryDb.getAllContacts()
        : await CallHistoryDb.searchContacts(query);

    if (contacts.isEmpty) return 'No contacts found.';

    // For "not called since" filter
    final notCalledSinceDays = args['not_called_since_days'] as int?;

    List<Map<String, dynamic>> filtered = contacts;
    if (notCalledSinceDays != null) {
      final cutoff =
          DateTime.now().subtract(Duration(days: notCalledSinceDays));
      final result = <Map<String, dynamic>>[];
      for (final c in contacts) {
        final phone = c['phone_number'] as String? ?? '';
        if (phone.isEmpty) continue;
        final calls = await CallHistoryDb.searchCalls(
          contactName: phone,
          since: cutoff,
          limit: 1,
        );
        if (calls.isEmpty) result.add(c);
      }
      filtered = result;
    }

    if (filtered.isEmpty) return 'No contacts match the criteria.';

    final buf = StringBuffer('Found ${filtered.length} contacts:\n');
    for (int i = 0; i < filtered.length && i < 50; i++) {
      final c = filtered[i];
      final name = c['display_name'] as String? ?? 'Unknown';
      final phone = c['phone_number'] as String? ?? '';
      buf.writeln('- $name${phone.isNotEmpty ? " ($phone)" : ""}');
    }
    if (filtered.length > 50) buf.writeln('... and ${filtered.length - 50} more.');
    return buf.toString();
  }

  Future<String> _handleCreateTearSheet(Map<String, dynamic> args) async {
    if (tearSheetService == null) return 'Tear sheet service not available.';

    final name = args['name'] as String? ?? 'Tear Sheet';
    final entries = args['entries'] as List<dynamic>?;

    if (entries == null || entries.isEmpty) {
      return 'No entries provided. Search contacts first, then call create_tear_sheet with the results.';
    }

    final numbers = <String>[];
    final names = <String?>[];
    for (final entry in entries) {
      if (entry is Map<String, dynamic>) {
        final phone = entry['phone_number'] as String? ?? '';
        if (phone.isNotEmpty) {
          numbers.add(phone);
          names.add(entry['name'] as String?);
        }
      } else if (entry is String && entry.isNotEmpty) {
        numbers.add(entry);
        names.add(null);
      }
    }

    if (numbers.isEmpty) return 'No valid phone numbers in entries.';

    final sheetId = await CallHistoryDb.insertTearSheet(name: name);
    for (int i = 0; i < numbers.length; i++) {
      await CallHistoryDb.insertTearSheetItem(
        tearSheetId: sheetId,
        position: i,
        phoneNumber: numbers[i],
        contactName: names[i],
      );
    }

    // Load the sheet into the service
    final sheet = tearSheetService!;
    // Use the internal load path via createFromNumbers won't work since we
    // already inserted — reload manually.
    await sheet.loadSheetById(sheetId);

    return 'Tear sheet "$name" created with ${numbers.length} entries. '
        'The host can see it docked at the top of the screen. '
        'Press Play to begin calling, or say "start the tear sheet."';
  }

  void announceRecording() {
    if (!_active) return;
    _whisper.sendSystemDirective(
      'SYSTEM ACTION: Call recording has started. You MUST immediately say '
      'aloud to the other party: "By the way, this call is now being recorded." '
      'Say only this announcement, nothing else.',
    );
  }

  void sendUserMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _messages.add(ChatMessage.user(trimmed));
    notifyListeners();

    if (_active) {
      _whisper.sendTextMessage(trimmed);
    } else {
      _messages.add(ChatMessage.system('Agent is not connected.'));
      notifyListeners();
    }
  }

  void toggleWhisperMode() {
    _whisperMode = !_whisperMode;
    if (_active) {
      if (_whisperMode) {
        _whisper.stopResponseAudio();
      }
      _whisper.setModalities(
        _whisperMode ? ['text'] : ['text', 'audio'],
      );
    }
    notifyListeners();
  }

  void sendWhisperMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _messages.add(ChatMessage.whisper(trimmed));
    notifyListeners();

    if (_active) {
      _whisper.sendSystemContext('[WHISPER] $trimmed');
    }

    callHistory?.addTranscript(
      role: 'whisper',
      speakerName: 'Host',
      text: trimmed,
    );
  }

  void updateSpeakerName(String speakerRole, String name) {
    final idx = _bootContext.speakers.indexWhere((s) => s.role == speakerRole);
    if (idx >= 0) {
      _bootContext.speakers[idx].name = name;
      notifyListeners();
    }
  }

  /// Push a call state change into the agent's context without triggering
  /// a verbal response. The agent sees the phase transition as a system
  /// message and adjusts behaviour (e.g. stays silent while ringing).
  void notifyCallPhase(
    CallPhase phase, {
    int partyCount = 2,
    String? remoteIdentity,
    String? remoteDisplayName,
    String? localIdentity,
    bool? outbound,
  }) {
    final phaseChanged = phase != _callPhase || partyCount != _partyCount;

    _callPhase = phase;
    _partyCount = partyCount;
    if (remoteIdentity != null) _remoteIdentity = remoteIdentity;
    if (remoteDisplayName != null) _remoteDisplayName = remoteDisplayName;
    if (localIdentity != null) _localIdentity = localIdentity;
    if (outbound != null) _isOutbound = outbound;

    // Start/end call history records
    if (phase == CallPhase.initiating || phase == CallPhase.ringing) {
      callHistory?.startCallRecord(
        direction: (outbound ?? _isOutbound) ? 'outbound' : 'inbound',
        remoteIdentity: remoteIdentity ?? _remoteIdentity,
        remoteDisplayName: remoteDisplayName ?? _remoteDisplayName,
        localIdentity: localIdentity ?? _localIdentity,
      );
    }

    if (phase == CallPhase.ended || phase == CallPhase.failed) {
      final status = phase == CallPhase.failed ? 'failed' : 'completed';
      callHistory?.endCallRecord(status: status);
      if (_remoteIdentity != null) _lastDialedNumber = _remoteIdentity;
      _remoteIdentity = null;
      _remoteDisplayName = null;
      _localIdentity = null;
      _cancelSettleTimer();
    }

    if (phase == CallPhase.settling) {
      _startSettleTimer();
    } else if (_callPhase != CallPhase.settling) {
      _cancelSettleTimer();
    }

    if (!phaseChanged) {
      notifyListeners();
      return;
    }

    final contextText = phase.contextMessage(
      partyCount: partyCount,
      remoteIdentity: _remoteIdentity,
      remoteDisplayName: _remoteDisplayName,
      localIdentity: _localIdentity,
      outbound: _isOutbound,
    );

    _messages.add(ChatMessage.callState(
      phase.displayLabel,
      metadata: {'phase': phase.name, 'partyCount': partyCount},
    ));
    notifyListeners();

    if (_active) {
      _whisper.sendSystemContext(contextText);
    }

    debugPrint('[AgentService] Call phase: ${phase.name} parties=$partyCount remote=$_remoteIdentity');
  }

  /// Start the settling timer. When it fires without being extended by
  /// IVR detections, auto-promote to connected.
  void _startSettleTimer() {
    _settleTimer?.cancel();
    _ivrHitsInSettle = 0;
    _settleTimer = Timer(const Duration(milliseconds: _settleWindowMs), () {
      if (_callPhase == CallPhase.settling) {
        _promoteToConnected();
      }
    });
  }

  /// Extend settling when IVR audio keeps arriving.
  void _extendSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: _settleExtendMs), () {
      if (_callPhase == CallPhase.settling) {
        _promoteToConnected();
      }
    });
  }

  void _cancelSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _ivrHitsInSettle = 0;
  }

  void _promoteToConnected() {
    _cancelSettleTimer();
    if (_callPhase != CallPhase.settling) return;

    debugPrint('[AgentService] Settle complete — promoting to connected');
    notifyCallPhase(
      CallPhase.connected,
      partyCount: _partyCount,
      remoteIdentity: _remoteIdentity,
      remoteDisplayName: _remoteDisplayName,
      localIdentity: _localIdentity,
      outbound: _isOutbound,
    );
  }

  /// Host manually confirms a real person is on the line, skipping the
  /// settle window immediately.
  void confirmPartyConnected() {
    if (_callPhase == CallPhase.settling ||
        _callPhase == CallPhase.answered) {
      _promoteToConnected();
    }
  }

  void toggleMute() {
    _muted = !_muted;
    _whisper.muted = _muted;
    if (!_speaking) {
      _statusText = _muted ? 'Not Listening...' : 'Listening';
    }
    notifyListeners();
  }

  Future<void> reconnect() async {
    _levelSub?.cancel();
    _speakingSub?.cancel();
    _audioSub?.cancel();
    _transcriptSub?.cancel();
    _responseTextSub?.cancel();
    _functionCallSub?.cancel();
    await _whisper.disconnect();
    _active = false;
    _speaking = false;
    _muted = false;
    _levels.clear();
    _messages.clear();
    _streamingMessageId = null;
    _statusText = 'Reconnecting...';
    notifyListeners();
    await _init();
  }

  @override
  void dispose() {
    _cancelSettleTimer();
    _levelSub?.cancel();
    _speakingSub?.cancel();
    _audioSub?.cancel();
    _transcriptSub?.cancel();
    _responseTextSub?.cancel();
    _functionCallSub?.cancel();
    _whisper.dispose();
    super.dispose();
  }
}
