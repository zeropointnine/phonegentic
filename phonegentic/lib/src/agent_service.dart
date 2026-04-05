import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'agent_config_service.dart';
import 'calendar_sync_service.dart';
import 'call_history_service.dart';
import 'contact_service.dart';
import 'demo_mode_service.dart';
import 'db/call_history_db.dart';
import 'elevenlabs_api_service.dart';
import 'job_function_service.dart';
import 'messaging/messaging_service.dart';
import 'messaging/phone_numbers.dart';
import 'models/agent_context.dart';
import 'models/chat_message.dart';
import 'tear_sheet_service.dart';
import 'elevenlabs_tts_service.dart';
import 'text_agent_service.dart';
import 'whisper_realtime_service.dart';

class AgentService extends ChangeNotifier {
  final WhisperRealtimeService _whisper = WhisperRealtimeService();

  bool _active = false;
  bool _muted = false;
  bool _speaking = false;
  bool _whisperMode = false;
  String _statusText = 'Initializing...';
  AgentMutePolicy _globalMutePolicy = AgentMutePolicy.autoToggle;
  bool _userMuteOverride = false;

  final Queue<double> _levels = Queue<double>();
  static const int waveformBars = 14;

  final List<ChatMessage> _messages = [];
  AgentBootContext _bootContext = AgentBootContext.trivia();

  CallPhase _callPhase = CallPhase.idle;
  DateTime? _connectedAt;
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
  MessagingService? messagingService;
  DemoModeService? demoModeService;
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
      if (!_splitPipeline || selected.whisperByDefault) {
        _setWhisperMode(selected.whisperByDefault);
      }
    }
    _applyInitialMuteState();
    _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);
    _pushInstructionsIfLive();
    notifyListeners();
  }

  /// Enforce stayMuted / stayUnmuted policy on startup or job function switch.
  /// Skipped when a call is active — [_applyMutePolicy] handles call phases.
  void _applyInitialMuteState() {
    if (_callPhase.isActive || _callPhase.isSettling ||
        _callPhase == CallPhase.onHold) {
      return;
    }
    final policy = effectiveMutePolicy;
    if (policy == AgentMutePolicy.stayMuted && !_muted) {
      _muted = true;
      _whisper.muted = true;
      if (!_speaking) {
        _statusText = 'Not Listening...';
      }
    } else if (policy == AgentMutePolicy.stayUnmuted) {
      if (_muted) {
        _muted = false;
        _whisper.muted = false;
        if (!_speaking) {
          _statusText = 'Listening';
        }
      }
      if (_splitPipeline) {
        if (_ttsMuted) {
          _ttsMuted = false;
        }
      } else {
        if (_whisperMode) {
          _whisperMode = false;
          if (_active) {
            _whisper.setModalities(['text', 'audio']);
          }
        }
      }
    }
  }

  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<AudioResponseEvent>? _audioSub;
  StreamSubscription<TranscriptionEvent>? _transcriptSub;
  StreamSubscription<ResponseTextEvent>? _responseTextSub;
  StreamSubscription<FunctionCallEvent>? _functionCallSub;
  StreamSubscription<ResponseTextEvent>? _textAgentSub;
  StreamSubscription<ToolCallRequest>? _textAgentToolSub;

  TextAgentService? _textAgent;
  TextAgentConfig? _textAgentConfig;
  bool get _splitPipeline => _textAgent != null;

  ElevenLabsTtsService? _tts;
  TtsConfig? _ttsConfig;
  bool _ttsMuted = false;
  StreamSubscription<Uint8List>? _ttsAudioSub;
  StreamSubscription<bool>? _ttsSpeakingSub;

  String? _streamingMessageId;
  int _ttsBracketDepth = 0;

  // Agent-initiated voice sampling state
  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');
  bool _agentSampling = false;
  String? _agentSamplePath;

  // Beep tone detection (native Goertzel filter in RenderPreProcessor).
  // Beep only triggers voicemail if an IVR/voicemail transcript was already
  // detected — prevents false positives from hold music, DTMF, etc.
  bool _beepDetected = false;
  bool _voicemailPromptSent = false;
  bool _ivrHeard = false;
  bool _hasConnectedBefore = false;

  // Deduplication: skip identical transcripts arriving within a short window
  String _lastTranscriptText = '';
  DateTime _lastTranscriptTime = DateTime(2000);

  // Cooldown after agent stops speaking to let TTS drain from whisper buffer.
  // 3000 ms accounts for the gap between ElevenLabs declaring generation
  // complete and the WebRTC audio pipeline actually finishing playback.
  DateTime _speakingEndTime = DateTime(2000);
  int _echoGuardMs = 2000;

  // Transcripts that arrive while the agent is speaking or in the echo guard
  // window.  Instead of dropping them (which loses context), we buffer and
  // process after the echo guard clears.
  final List<TranscriptionEvent> _pendingTranscripts = [];
  Timer? _postSpeakFlushTimer;

  // Recent agent response texts for text-based echo suppression.
  // If an incoming transcript fuzzy-matches a recent agent response, it is
  // almost certainly the agent's own TTS being picked up by the mic.
  final List<String> _recentAgentTexts = [];
  static const _maxRecentAgentTexts = 5;

  // Settling: buffer window after SIP CONFIRMED to filter auto-attendant/IVR
  Timer? _settleTimer;
  Timer? _preGreetTimer;
  int _ivrHitsInSettle = 0;
  final List<TranscriptionEvent> _settleTranscripts = [];
  static const _settleWindowMs = 4000;
  static const _settleExtendMs = 8000;
  static const _maxSettleMs = 20000;
  DateTime? _settleStartTime;

  // Deferred greeting: nudge the agent to begin if the line stays quiet
  // after transitioning to connected.
  Timer? _connectedGreetTimer;
  static const _connectedGreetDelayMs = 1500;

  bool get active => _active;
  bool get muted => _muted;
  bool get speaking => _speaking;
  bool get whisperMode => _splitPipeline ? _ttsMuted : _whisperMode;
  bool get canToggleWhisper => true;
  String get statusText => _statusText;
  List<double> get levels => _levels.toList();
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  WhisperRealtimeService get whisper => _whisper;
  AgentBootContext get bootContext => _bootContext;

  AgentMutePolicy get globalMutePolicy => _globalMutePolicy;

  /// Resolve the effective mute policy: job function override wins over global.
  AgentMutePolicy get effectiveMutePolicy {
    final override = _jobFunctionService?.selected?.mutePolicyOverride;
    if (override != null &&
        override >= 0 &&
        override < AgentMutePolicy.values.length) {
      return AgentMutePolicy.values[override];
    }
    return _globalMutePolicy;
  }

  void setGlobalMutePolicy(AgentMutePolicy policy) {
    if (_globalMutePolicy == policy) return;
    _globalMutePolicy = policy;
    AgentConfigService.saveMutePolicy(policy);
    _applyInitialMuteState();
    notifyListeners();
  }

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
      if (!_splitPipeline || whisperByDefault) {
        _setWhisperMode(whisperByDefault);
      }
    }

    _tts?.updateVoiceId(ctx.elevenLabsVoiceId);

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
    _textAgent?.updateInstructions(_buildTextAgentInstructions());
  }

  Speaker get hostSpeaker => _bootContext.speakers.isNotEmpty
      ? _bootContext.speakers.first
      : Speaker(role: 'Host', source: 'mic');
  Speaker get remoteSpeaker => _bootContext.speakers.length > 1
      ? _bootContext.speakers[1]
      : Speaker(role: 'Remote Party 1', source: 'remote');

  /// Update the remote party's display name (e.g. from contacts DB or
  /// voiceprint match) and push refreshed instructions to the live session.
  void setRemotePartyName(String name) {
    if (_bootContext.speakers.length > 1) {
      _bootContext.speakers[1].name = name;
    }
    notifyListeners();
    _pushInstructionsIfLive();
  }

  void _clearRemotePartyName() {
    if (_bootContext.speakers.length > 1) {
      _bootContext.speakers[1].name = '';
    }
  }

  AgentService() {
    _messages.add(ChatMessage.system('Agent starting...'));
    _tapChannel.setMethodCallHandler(_handleNativeTapCall);
    _init();
  }

  Future<void> _init() async {
    try {
      _syncBootContextFromJobFunction();
      _globalMutePolicy = await AgentConfigService.loadMutePolicy();

      final config = await AgentConfigService.loadVoiceConfig();
      _echoGuardMs = config.echoGuardMs;
      _textAgentConfig = await AgentConfigService.loadTextConfig();
      _ttsConfig = await AgentConfigService.loadTtsConfig();
      if (!config.enabled || !config.isConfigured) {
        _statusText = 'Not configured';
        _messages.clear();
        _messages.add(ChatMessage.system(
            'Voice agent not configured. Go to Settings > Agents to set up.'));
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
        _applyInitialMuteState();
        _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);
        _pushInstructionsIfLive();
      }

      _messages.clear();
      if (_active) {
        await _loadPreviousConversation();
        final jfTitle = _jobFunctionService?.selected?.title;
        final label = jfTitle != null ? 'Ready as "$jfTitle".' : 'Ready.';
        _messages.add(ChatMessage.agent(
          '$label I\'m listening to the call and can assist anytime. Type a message or just talk.',
        ));
      } else {
        _messages.add(ChatMessage.system('Failed to connect to AI agent.'));
      }
      notifyListeners();

      if (!_active) return;

      await _whisper.startAudioTap(captureInput: true, captureOutput: true);

      // Initialize the on-device speaker identifier and load known voiceprints
      await _whisper.initSpeakerIdentifier();
      await _loadKnownSpeakerEmbeddings();

      _levelSub = _whisper.audioLevels.listen((level) {
        _levels.addLast(level);
        while (_levels.length > waveformBars) {
          _levels.removeFirst();
        }
        notifyListeners();
      });

      _speakingSub = _whisper.speakingState.listen((isSpeaking) {
        // In split pipeline mode, ignore OpenAI's speaking state — we're
        // throwing away its audio. ElevenLabs controls _speaking instead.
        if (_splitPipeline) return;
        _speaking = isSpeaking;
        _statusText = isSpeaking
            ? 'Speaking'
            : (_muted ? 'Not Listening...' : 'Listening');
        if (!isSpeaking) {
          _speakingEndTime = DateTime.now();
          _schedulePostSpeakFlush();
        }
        notifyListeners();
      });

      int audioChunkCount = 0;
      _audioSub = _whisper.audioResponses.listen((event) {
        if (_whisperMode) return;
        if (!_callPhase.isActive && _callPhase != CallPhase.idle) return;
        if (event.pcm16Data.isNotEmpty) {
          audioChunkCount++;
          if (audioChunkCount <= 3 || audioChunkCount % 50 == 0) {
            debugPrint(
                '[AgentService] TTS chunk #$audioChunkCount: ${event.pcm16Data.length} bytes');
          }
          _whisper.playResponseAudio(event.pcm16Data);
        }
      });

      _transcriptSub = _whisper.transcriptions.listen(_onTranscript);
      _responseTextSub = _whisper.responseTexts.listen(_onResponseText);
      _functionCallSub = _whisper.functionCalls.listen(_onFunctionCall);

      _initTextAgent();

      // Apply the job function's ElevenLabs voice now that TTS is initialised.
      // The earlier updateVoiceId call (before _initTextAgent) was a no-op
      // because _tts hadn't been created yet.
      _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);

      debugPrint(
          '[AgentService] Started: model=${config.model} voice=${config.voice}');
    } catch (e) {
      _statusText = 'Error';
      _active = false;
      _messages.add(ChatMessage.system('Error: $e'));
      debugPrint('[AgentService] Init failed: $e');
      notifyListeners();
    }
  }

  void _initTextAgent() {
    final tc = _textAgentConfig;
    debugPrint('[AgentService] TextAgent config: '
        'enabled=${tc?.enabled} '
        'provider=${tc?.provider.name} '
        'configured=${tc?.isConfigured}');
    if (tc == null || !tc.enabled || !tc.isConfigured) return;
    if (tc.provider == TextAgentProvider.openai) return;

    _textAgent = TextAgentService(
      config: tc,
      systemInstructions: _buildTextAgentInstructions(),
    );
    _textAgentSub = _textAgent!.responses.listen(_appendStreamingResponse);
    _textAgentToolSub = _textAgent!.toolCalls.listen(_onTextAgentToolCall);

    // Set the whisper flag so OpenAI audio responses are suppressed on the
    // Dart side, but do NOT change modalities on the server — text-only
    // modalities disable VAD which kills transcription.
    _whisperMode = true;

    _initTts();

    debugPrint(
        '[AgentService] Split pipeline active: ${tc.provider.name} text agent');
  }

  void _initTts() {
    final tc = _ttsConfig;
    debugPrint('[AgentService] TTS config: '
        'provider=${tc?.provider.name} '
        'configured=${tc?.isConfigured}');

    // Allow TTS init with just an API key — the voice can come from the
    // job function via updateVoiceId() even if no default voice is set.
    final hasApiKey = tc != null &&
        tc.provider == TtsProvider.elevenlabs &&
        tc.elevenLabsApiKey.isNotEmpty;
    if (!hasApiKey) return;

    _tts = ElevenLabsTtsService(config: tc);

    int elChunkCount = 0;
    _ttsAudioSub = _tts!.audioChunks.listen((pcm) {
      if (_ttsMuted) return;
      elChunkCount++;
      if (elChunkCount <= 3 || elChunkCount % 25 == 0) {
        debugPrint('[AgentService] ElevenLabs audio #$elChunkCount: '
            '${pcm.length} bytes → playResponseAudio');
      }
      _whisper.playResponseAudio(pcm);
    });

    _ttsSpeakingSub = _tts!.speakingState.listen((speaking) {
      _speaking = speaking;
      if (!speaking) {
        _speakingEndTime = DateTime.now();
        _schedulePostSpeakFlush();
      }
    });

    debugPrint('[AgentService] ElevenLabs TTS active: '
        'voice=${tc.elevenLabsVoiceId} model=${tc.elevenLabsModelId}');
  }

  CalendarSyncService? _calendarSync;
  set calendarSyncService(CalendarSyncService s) => _calendarSync = s;

  String _buildCalendarContext() {
    final sync = _calendarSync;
    if (sync == null) return '';

    final events = sync.events;
    if (events.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('\n## Calendar Schedule');
    buf.writeln(
        'You have make_call, end_call, and (when configured) SMS tools '
        '(send_sms, reply_sms, search_messages).');
    buf.writeln('When a calendar event starts, follow the job function '
        'instructions. If the event involves a call, use make_call to dial; '
        'if it involves texting, use the SMS tools as appropriate.');
    buf.writeln('');

    final now = DateTime.now();
    for (final e in events.take(5)) {
      final start = e.startTime.toLocal();
      final end = e.endTime.toLocal();
      final isNow = start.isBefore(now) && end.isAfter(now);
      buf.write('- ${isNow ? "[NOW] " : ""}${e.title}: ');
      buf.write('${_fmtTime(start)} – ${_fmtTime(end)}');
      if (e.inviteeName != null) buf.write(' (${e.inviteeName})');
      if (e.location != null) buf.write(' @ ${e.location}');
      buf.writeln();
    }
    return buf.toString();
  }

  static String _fmtTime(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ap = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ap';
  }

  String _buildTextAgentInstructions() {
    final hasTts = _tts != null;
    final ctx = AgentBootContext(
      name: _bootContext.name,
      role: _bootContext.role,
      jobFunction: _bootContext.jobFunction,
      speakers: _bootContext.speakers,
      guardrails: _bootContext.guardrails,
      textOnly: !hasTts,
    );
    final base = ctx.toInstructions();
    final calendar = _buildCalendarContext();
    final prompt = _textAgentConfig?.systemPrompt ?? '';
    final buf = StringBuffer(base);
    buf.write(_buildDateTimeContext());
    if (calendar.isNotEmpty) buf.write(calendar);
    if (prompt.isNotEmpty) {
      buf.write('\n\n## Additional Instructions\n$prompt');
    }
    return buf.toString();
  }

  static String _buildDateTimeContext() {
    final now = DateTime.now();
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final months = ['January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'];
    final day = weekdays[now.weekday - 1];
    final month = months[now.month - 1];
    final h = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
    final m = now.minute.toString().padLeft(2, '0');
    final ap = now.hour >= 12 ? 'PM' : 'AM';
    final tz = now.timeZoneName;
    return '\n## Current Date & Time\n'
        '$day, $month ${now.day}, ${now.year} at $h:$m $ap $tz\n';
  }

  /// Save the remote party's voiceprint embedding to SQLite for future
  /// identification, if we have both a known contact and an embedding.
  Future<void> _saveRemoteVoiceprint() async {
    try {
      final rid = _remoteIdentity;
      if (rid == null || rid.isEmpty) return;

      final contact = contactService?.lookupByPhone(rid);
      final contactId = contact?['id'] as int?;
      if (contactId == null) return;

      final embedding = await _whisper.getRemoteSpeakerEmbedding();
      if (embedding == null || embedding.isEmpty) return;

      await CallHistoryDb.upsertSpeakerEmbedding(
        contactId: contactId,
        embedding: embedding,
      );
      debugPrint('[AgentService] Saved voiceprint for contact #$contactId');
    } catch (e) {
      debugPrint('[AgentService] Failed to save voiceprint: $e');
    }
  }

  /// Load stored speaker voiceprint embeddings from SQLite and push them
  /// to the native speaker identifier so it can match voices on new calls.
  Future<void> _loadKnownSpeakerEmbeddings() async {
    try {
      final rows = await CallHistoryDb.getAllSpeakerEmbeddingsDecoded();
      if (rows.isEmpty) return;

      final speakers = <Map<String, dynamic>>[];
      for (final row in rows) {
        final contactId = row['contact_id'] as int?;
        final name = row['display_name'] as String? ?? '';
        final embedding = row['decoded_embedding'] as List<double>?;
        if (contactId == null || embedding == null) continue;

        speakers.add({
          'id': 'contact_$contactId',
          'name': name,
          'embedding': embedding,
        });
      }

      if (speakers.isNotEmpty) {
        await _whisper.loadKnownSpeakers(speakers);
        debugPrint(
            '[AgentService] Loaded ${speakers.length} known speaker voiceprints');
      }
    } catch (e) {
      debugPrint('[AgentService] Failed to load speaker embeddings: $e');
    }
  }

  /// Load transcripts from the most recent completed call and prepend them
  /// to the message list so the user sees prior context on startup.
  Future<void> _loadPreviousConversation() async {
    try {
      final recentCalls = await CallHistoryDb.getRecentCalls(limit: 1);
      if (recentCalls.isEmpty) return;

      final call = recentCalls.first;
      final callId = call['id'] as int;
      final transcripts = await CallHistoryDb.getTranscripts(callId);
      if (transcripts.isEmpty) return;

      final remoteName = call['remote_display_name'] as String? ??
          call['remote_identity'] as String? ??
          'Unknown';
      final startedAt =
          DateTime.tryParse(call['started_at'] as String? ?? '') ??
              DateTime.now();
      final dateLabel = '${startedAt.month}/${startedAt.day}/${startedAt.year} '
          '${startedAt.hour}:${startedAt.minute.toString().padLeft(2, '0')}';

      _messages.add(ChatMessage.system(
        'Previous call: $remoteName \u2014 $dateLabel',
        metadata: const {'isPreviousCallHeader': true},
      ));

      for (final t in transcripts) {
        final role = t['role'] as String? ?? 'remote';
        final speakerName = t['speaker_name'] as String?;
        final text = t['text'] as String? ?? '';
        if (text.isEmpty) continue;

        ChatRole chatRole;
        switch (role) {
          case 'host':
            chatRole = ChatRole.host;
            break;
          case 'agent':
            chatRole = ChatRole.agent;
            break;
          default:
            chatRole = ChatRole.remoteParty;
        }

        if (chatRole == ChatRole.agent) {
          _messages.add(ChatMessage.agent(text,
              metadata: const {'isPreviousCall': true}));
        } else {
          _messages.add(ChatMessage.transcript(chatRole, text,
              speakerName: speakerName,
              metadata: const {'isPreviousCall': true}));
        }
      }

      _messages.add(ChatMessage.system('— End of previous call —',
          metadata: const {'isPreviousCallFooter': true}));
    } catch (e) {
      debugPrint('[AgentService] Failed to load previous conversation: $e');
    }
  }

  /// Returns true if [text] is a fuzzy substring of any recent agent response,
  /// indicating it is likely the agent's own TTS being transcribed back.
  bool _isEchoOfAgentResponse(String text) {
    if (_recentAgentTexts.isEmpty) return false;
    final lower = text.toLowerCase();
    if (lower.length < 8) return false; // too short to match reliably
    for (final agentText in _recentAgentTexts) {
      final agentLower = agentText.toLowerCase();
      // Check if the transcript is contained within a recent agent response
      if (agentLower.contains(lower)) return true;
      // Check if a significant portion of the transcript words overlap
      final tWords =
          lower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      final aWords =
          agentLower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      if (tWords.isNotEmpty && aWords.isNotEmpty) {
        final overlap = tWords.intersection(aWords).length;
        if (overlap / tWords.length >= 0.4) return true;
      }
    }
    return false;
  }

  /// Schedule a flush of buffered transcripts after the echo guard window.
  void _schedulePostSpeakFlush() {
    _postSpeakFlushTimer?.cancel();
    _postSpeakFlushTimer = Timer(
      Duration(milliseconds: _echoGuardMs),
      _flushPendingTranscripts,
    );
  }

  /// Process transcripts that were buffered while the agent was speaking.
  /// Echo-like entries are filtered; genuine remote speech is forwarded.
  void _flushPendingTranscripts() {
    if (_pendingTranscripts.isEmpty) return;
    if (_speaking) return; // still speaking, wait
    final msSince =
        DateTime.now().difference(_speakingEndTime).inMilliseconds;
    if (msSince < _echoGuardMs) {
      _schedulePostSpeakFlush();
      return;
    }

    final batch = List<TranscriptionEvent>.from(_pendingTranscripts);
    _pendingTranscripts.clear();

    for (final event in batch) {
      final text = event.text.trim();
      if (text.isEmpty) continue;
      if (_isEchoOfAgentResponse(text)) {
        debugPrint('[AgentService] Buffered echo discarded: "$text"');
        continue;
      }
      _processTranscript(event);
    }
  }

  void _onTranscript(TranscriptionEvent event) async {
    if (!event.isFinal || event.text.trim().isEmpty) return;

    // Suppress transcripts while call is still setting up — but in split
    // pipeline mode, allow transcripts when idle so the user can talk to the
    // agent without an active call.
    if (_callPhase.isPreConnect) {
      if (!(_splitPipeline && _callPhase == CallPhase.idle)) return;
    }

    // During settling, check for IVR patterns. If detected, extend the
    // settle window. If clean human speech arrives instead, promote to
    // connected — but DON'T forward the transcript to the LLM yet.
    // Buffer it so the VAD-aware connected greeting can forward it once
    // the remote party stops speaking, preventing the agent from talking
    // over them.
    if (_callPhase.isSettling) {
      final text = event.text.trim();
      if (IvrDetector.isIvr(text)) {
        _ivrHitsInSettle++;
        _ivrHeard = true;
        _extendSettleTimer();
        debugPrint(
            '[AgentService] IVR detected during settle: "$text" (hits=$_ivrHitsInSettle)');
        return;
      }
      _settleTranscripts.add(event);
      if (text.length >= 3 && _ivrHitsInSettle == 0) {
        debugPrint(
            '[AgentService] Human speech during settle: "$text" — promoting (transcript buffered)');
        _promoteToConnected();
      }
      return;
    }

    // While the agent is speaking (or within the echo guard cooldown after
    // it stops), buffer transcripts instead of dropping them.  They will be
    // processed once the echo guard clears via _flushPendingTranscripts().
    // We intentionally do NOT interrupt TTS here — echo detection is not
    // reliable enough mid-speech to distinguish the agent's own audio being
    // transcribed back from genuine remote party speech.
    if (_speaking) {
      _pendingTranscripts.add(event);
      return;
    }
    final msSinceSpoke =
        DateTime.now().difference(_speakingEndTime).inMilliseconds;
    if (msSinceSpoke < _echoGuardMs) {
      _pendingTranscripts.add(event);
      return;
    }

    _processTranscript(event);
  }

  /// Core transcript processing shared by the live path and the post-speak
  /// buffer flush.
  void _processTranscript(TranscriptionEvent event) async {
    final text = event.text.trim();
    if (text.isEmpty) return;

    // Filter stray IVR/auto-attendant fragments that arrive after settling.
    if (IvrDetector.isIvr(text)) {
      _ivrHeard = true;
      debugPrint('[AgentService] IVR filtered post-settle: "$text"');
      return;
    }

    // Real human speech — cancel any pending connected greeting so the
    // agent doesn't talk over whoever is already speaking.
    _cancelConnectedGreeting();

    // If there are buffered settle-phase transcripts, forward them first
    // so the LLM has the full context of what was said before connected.
    _drainSettleTranscripts();

    // Text-based echo suppression: if the transcript is a substantial
    // substring of a recent agent response, it's the agent hearing itself.
    if (_isEchoOfAgentResponse(text)) {
      debugPrint('[AgentService] Echo suppressed (text match): "$text"');
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

    final info = await _whisper.getSpeakerInfo();
    final source = info['source'] as String? ?? 'unknown';
    final voiceprintName = info['identity'] as String? ?? '';
    final confidence = (info['confidence'] as num?)?.toDouble() ?? 0.0;
    final isRemote = source == 'remote';
    final role = isRemote ? ChatRole.remoteParty : ChatRole.host;
    final speaker = isRemote ? remoteSpeaker : hostSpeaker;

    // When idle (no active call), filter likely background/ambient audio.
    // Low-confidence transcripts from the mic are probably TV, TikTok, etc.
    if (_callPhase == CallPhase.idle) {
      if (confidence > 0.0 && confidence < 0.25) {
        debugPrint('[AgentService] Ambient audio dropped (confidence=$confidence): "$text"');
        return;
      }
    }

    final lowConfidence = confidence > 0.0 && confidence < 0.5;

    // If voiceprint identified a name with reasonable confidence and the
    // speaker doesn't have one yet, update the label.  A threshold of 0.65
    // avoids false positives from ambient audio or dissimilar voices.
    if (voiceprintName.isNotEmpty && speaker.name.isEmpty) {
      if (confidence >= 0.65) {
        speaker.name = voiceprintName;
        _pushInstructionsIfLive();
        debugPrint('[AgentService] Voiceprint accepted: "$voiceprintName" (confidence=$confidence)');
      } else {
        debugPrint('[AgentService] Voiceprint rejected: "$voiceprintName" (confidence=$confidence < 0.65)');
      }
    }

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

    // Tag low-confidence transcripts so the agent can judge whether to respond
    final label = lowConfidence
        ? '${speaker.label} (low confidence)'
        : speaker.label;
    _textAgent?.addTranscript(label, text);
  }

  void _onResponseText(ResponseTextEvent event) {
    if (_splitPipeline) return;
    _appendStreamingResponse(event);
  }

  /// Shared handler for streaming agent responses from either OpenAI
  /// Realtime or the external text agent (Claude, etc.).
  void _appendStreamingResponse(ResponseTextEvent event) {
    if (_callPhase == CallPhase.ended || _callPhase == CallPhase.failed) return;
    if (event.isFinal) {
      debugPrint('[AgentService] Claude response final: '
          '${event.text.length > 80 ? event.text.substring(0, 80) : event.text}...');
    }

    if (event.isFinal) {
      _tts?.endGeneration();

      if (_streamingMessageId != null) {
        final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
        if (idx >= 0) {
          _messages[idx].isStreaming = false;
          if (event.text.isNotEmpty) {
            _messages[idx].text = event.text;
          }
          final finalText = _messages[idx].text;
          _recentAgentTexts.add(finalText);
          while (_recentAgentTexts.length > _maxRecentAgentTexts) {
            _recentAgentTexts.removeAt(0);
          }
          callHistory?.addTranscript(
            role: 'agent',
            text: finalText,
          );
        }
        _streamingMessageId = null;
      }
      notifyListeners();
      return;
    }

    // Suppress TTS during pre-connect and settling phases so the agent
    // doesn't talk over auto-attendants / IVR greetings.
    final suppressTts = (_callPhase.isPreConnect ||
            _callPhase == CallPhase.answered ||
            _callPhase == CallPhase.settling) &&
        _callPhase != CallPhase.idle;

    // Pipe text delta to ElevenLabs TTS, stripping bracketed stage directions
    if (_tts != null && event.text.isNotEmpty && !suppressTts) {
      if (_streamingMessageId == null) {
        _ttsBracketDepth = 0;
        _tts!.startGeneration();
      }
      final ttsText = _stripBracketsForTts(event.text);
      if (ttsText.isNotEmpty) {
        _tts!.sendText(ttsText);
      }
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

  /// Strip bracketed text from a streaming delta before sending to TTS.
  /// Tracks `_ttsBracketDepth` across deltas so nested/split brackets work.
  String _stripBracketsForTts(String text) {
    final buf = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '[') {
        _ttsBracketDepth++;
      } else if (ch == ']') {
        if (_ttsBracketDepth > 0) _ttsBracketDepth--;
      } else if (_ttsBracketDepth == 0) {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Function call handling (agent tools)
  // ---------------------------------------------------------------------------

  Future<void> _onFunctionCall(FunctionCallEvent event) async {
    if (_splitPipeline) return;
    debugPrint(
        '[AgentService] Function call: ${event.name} args=${event.arguments}');

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
          result = await _handleEndCall();
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
        case 'send_sms':
          result = await _handleSendSms(args);
          break;
        case 'reply_sms':
          result = await _handleReplySms(args);
          break;
        case 'search_messages':
          result = await _handleSearchMessages(args);
          break;
        case 'start_voice_sample':
          result = await _handleStartVoiceSample(args);
          break;
        case 'stop_and_clone_voice':
          result = await _handleStopAndCloneVoice(args);
          break;
        case 'set_agent_voice':
          result = await _handleSetAgentVoice(args);
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

  /// Handle tool calls from the Claude text agent (split pipeline).
  Future<void> _onTextAgentToolCall(ToolCallRequest req) async {
    debugPrint(
        '[AgentService] Text-agent tool: ${req.name} args=${req.arguments}');

    String result;
    try {
      switch (req.name) {
        case 'make_call':
          result = await _handleMakeCall(req.arguments);
          break;
        case 'end_call':
          result = await _handleEndCall();
          break;
        case 'search_contacts':
          result = await _handleSearchContacts(req.arguments);
          break;
        case 'create_tear_sheet':
          result = await _handleCreateTearSheet(req.arguments);
          break;
        case 'send_sms':
          result = await _handleSendSms(req.arguments);
          break;
        case 'reply_sms':
          result = await _handleReplySms(req.arguments);
          break;
        case 'search_messages':
          result = await _handleSearchMessages(req.arguments);
          break;
        case 'start_voice_sample':
          result = await _handleStartVoiceSample(req.arguments);
          break;
        case 'stop_and_clone_voice':
          result = await _handleStopAndCloneVoice(req.arguments);
          break;
        case 'set_agent_voice':
          result = await _handleSetAgentVoice(req.arguments);
          break;
        default:
          result = 'Unknown tool: ${req.name}';
      }
    } catch (e) {
      result = 'Error: $e';
      debugPrint('[AgentService] Text-agent tool error: $e');
    }

    debugPrint('[AgentService] Text-agent tool result: $result');
    _textAgent?.addToolResult(req.id, result);
  }

  // ---------------------------------------------------------------------------
  // SMS / Messaging tool handlers
  // ---------------------------------------------------------------------------

  Future<String> _handleSendSms(Map<String, dynamic> args) async {
    if (messagingService == null || !messagingService!.isConfigured) {
      return 'Messaging is not configured. Set up SMS (Telnyx or Twilio) in Settings.';
    }
    final to = args['to'] as String?;
    final text = args['text'] as String?;
    if (to == null || to.isEmpty || text == null || text.isEmpty) {
      return 'Both "to" and "text" are required.';
    }
    final mediaUrl = args['media_url'] as String?;
    final mediaUrls =
        mediaUrl != null && mediaUrl.isNotEmpty ? [mediaUrl] : null;
    final msg = await messagingService!
        .sendMessage(to: to, text: text, mediaUrls: mediaUrls);
    if (msg != null) {
      final displayTo = (demoModeService?.enabled ?? false)
          ? demoModeService!.maskPhone(to)
          : to;
      _messages.add(ChatMessage.system(
        'SMS sent to $displayTo: "$text"',
        metadata: {'type': 'sms_sent', 'to': to},
      ));
      notifyListeners();
      return 'Message sent successfully to $displayTo.';
    }
    return 'Failed to send message.';
  }

  Future<String> _handleReplySms(Map<String, dynamic> args) async {
    if (messagingService == null || !messagingService!.isConfigured) {
      return 'Messaging is not configured.';
    }
    final text = args['text'] as String?;
    if (text == null || text.isEmpty) return '"text" is required.';

    final selected = messagingService!.selectedRemotePhone;
    if (selected == null) {
      return 'No conversation selected. Use send_sms with a phone number instead.';
    }
    final msg = await messagingService!.reply(text);
    if (msg != null) {
      final displayTo = (demoModeService?.enabled ?? false)
          ? demoModeService!.maskPhone(selected)
          : selected;
      _messages.add(ChatMessage.system(
        'SMS reply to $displayTo: "$text"',
        metadata: {'type': 'sms_reply', 'to': selected},
      ));
      notifyListeners();
      return 'Reply sent to $displayTo.';
    }
    return 'Failed to send reply.';
  }

  Future<String> _handleSearchMessages(Map<String, dynamic> args) async {
    if (messagingService == null) return 'Messaging is not configured.';
    final query = args['query'] as String? ?? '';
    final contactName = args['contact_name'] as String? ?? '';

    final searchTerm = query.isNotEmpty ? query : contactName;
    if (searchTerm.isEmpty) return 'Provide a query or contact_name to search.';

    final results = await messagingService!.searchMessages(searchTerm);
    if (results.isEmpty) return 'No messages found matching "$searchTerm".';

    final buf = StringBuffer('Found ${results.length} message(s):\n');
    for (final m in results.take(10)) {
      final dir = m.direction.name;
      final phone = m.remotePhone;
      final preview =
          m.text.length > 80 ? '${m.text.substring(0, 80)}...' : m.text;
      buf.writeln('- [$dir] $phone: "$preview"');
    }
    return buf.toString();
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
    final normalized =
        number.toLowerCase().replaceAll(RegExp(r'[<>_]'), '').trim();
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

    number = ensureE164(number);

    try {
      final mediaConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };
      final stream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      final success =
          await sipHelper!.call(number, voiceOnly: true, mediaStream: stream);
      if (!success) {
        return 'Failed to make call: SIP not connected. User needs to register first.';
      }
      final displayNum = (demoModeService?.enabled ?? false)
          ? demoModeService!.maskPhone(number)
          : number;
      return 'Call initiated to $displayNum';
    } catch (e) {
      return 'Failed to make call: $e';
    }
  }

  Future<String> _handleEndCall() async {
    if (sipHelper == null) return 'SIP helper not available.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call to end.';

    if (_connectedAt != null) {
      final elapsed = DateTime.now().difference(_connectedAt!).inSeconds;
      if (elapsed < 20) {
        return 'Call just connected ${elapsed}s ago. '
            'Do NOT hang up autonomously — only the host can decide when to end the call.';
      }
    }

    // Wait for TTS to finish so the agent's message is fully delivered
    // before the line drops (e.g. voicemail, goodbyes).
    if (_speaking) {
      debugPrint('[AgentService] end_call deferred — waiting for TTS to finish');
      final completer = Completer<void>();
      late StreamSubscription<bool> sub;
      sub = _tts!.speakingState.listen((speaking) {
        if (!speaking && !completer.isCompleted) {
          completer.complete();
          sub.cancel();
        }
      });
      // Safety timeout so we don't wait forever
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          sub.cancel();
          debugPrint('[AgentService] end_call TTS wait timed out');
        },
      );
    }

    sipHelper!.activeCall?.hangup();
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
    if (filtered.length > 50)
      buf.writeln('... and ${filtered.length - 50} more.');
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
      if (entry is Map) {
        final m = Map<String, dynamic>.from(entry);
        final raw = m['phone_number'] as String? ??
            m['phone'] as String? ??
            m['number'] as String? ??
            '';
        final phone = raw.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
        if (phone.isNotEmpty) {
          numbers.add(phone);
          names.add(m['name'] as String? ?? m['display_name'] as String?);
        }
      } else if (entry is String && entry.isNotEmpty) {
        numbers.add(entry.replaceAll(RegExp(r'[\s\-\(\)\.]'), ''));
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
        'The host should see a tear sheet bar (full width at the top of the window, '
        'and under the agent header on the right) with a Play button. '
        'There is also a receipt icon in the agent header to pause/play or open a new sheet. '
        'Press Play to begin calling, or ask the host to say "start the tear sheet."';
  }

  // ---------------------------------------------------------------------------
  // Voice sampling / cloning / swap tools (alter ego flow)
  // ---------------------------------------------------------------------------

  Future<String> _handleStartVoiceSample(Map<String, dynamic> args) async {
    if (_agentSampling) return 'Already sampling. Stop the current sample first.';
    if (!_callPhase.isActive && _callPhase != CallPhase.settling) {
      return 'No active call to sample from.';
    }

    final party = (args['party'] as String?)?.toLowerCase() ?? 'remote';
    if (party != 'remote' && party != 'host') {
      return 'Invalid party "$party". Use "remote" or "host".';
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final recDir =
          Directory(p.join(dir.path, 'phonegentic', 'voice_samples'));
      await recDir.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _agentSamplePath =
          p.join(recDir.path, 'agent_sample_${party}_$timestamp.wav');

      await _tapChannel.invokeMethod(
          'startVoiceSample', {'path': _agentSamplePath, 'party': party});

      _agentSampling = true;
      _messages.add(ChatMessage.system('Voice sampling started ($party)'));
      notifyListeners();
      debugPrint('[AgentService] Agent-initiated voice sample → $_agentSamplePath ($party)');
      return 'Voice sampling started for $party party. '
          'Let them speak for at least 10-15 seconds, then call stop_and_clone_voice.';
    } catch (e) {
      debugPrint('[AgentService] startVoiceSample failed: $e');
      _agentSamplePath = null;
      return 'Failed to start voice sample: $e';
    }
  }

  Future<String> _handleStopAndCloneVoice(Map<String, dynamic> args) async {
    if (!_agentSampling || _agentSamplePath == null) {
      return 'No voice sample in progress. Call start_voice_sample first.';
    }

    final apiKey = _ttsConfig?.elevenLabsApiKey ?? '';
    if (apiKey.isEmpty) {
      return 'ElevenLabs API key is not configured. Cannot clone voice.';
    }

    try {
      await _tapChannel.invokeMethod('stopVoiceSample');
      _agentSampling = false;
      debugPrint('[AgentService] Voice sample stopped → $_agentSamplePath');
    } catch (e) {
      _agentSampling = false;
      debugPrint('[AgentService] stopVoiceSample failed: $e');
      return 'Failed to stop voice sample: $e';
    }

    final name = (args['voice_name'] as String?)?.trim().isNotEmpty == true
        ? args['voice_name'] as String
        : 'Alter Ego ${DateTime.now().millisecondsSinceEpoch}';

    try {
      _messages.add(ChatMessage.system('Cloning voice...'));
      notifyListeners();

      final voiceId = await ElevenLabsApiService.addVoice(
        apiKey,
        name: name,
        filePaths: [_agentSamplePath!],
      );

      _agentSamplePath = null;
      _messages.add(ChatMessage.system('Voice "$name" cloned successfully'));
      notifyListeners();
      debugPrint('[AgentService] Voice cloned: $voiceId ($name)');
      return 'Voice cloned successfully. voice_id=$voiceId name="$name". '
          'Call set_agent_voice with this voice_id to start speaking in their voice.';
    } catch (e) {
      _agentSamplePath = null;
      debugPrint('[AgentService] Voice clone failed: $e');
      return 'Voice cloning failed: $e';
    }
  }

  Future<String> _handleSetAgentVoice(Map<String, dynamic> args) async {
    final voiceId = args['voice_id'] as String?;
    if (voiceId == null || voiceId.isEmpty) {
      return 'No voice_id provided.';
    }

    if (_tts == null) {
      return 'ElevenLabs TTS is not active. Cannot change voice.';
    }

    _tts!.updateVoiceId(voiceId);
    _messages.add(ChatMessage.system('Agent voice changed to $voiceId'));
    notifyListeners();
    debugPrint('[AgentService] Agent voice swapped to: $voiceId');
    return 'Voice updated. You are now speaking with voice_id=$voiceId. '
        'All subsequent speech will use this voice.';
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
      if (_splitPipeline) {
        debugPrint('[AgentService] User message → Claude: "$trimmed"');
        _textAgent!.sendUserMessage(trimmed);
      } else {
        _whisper.sendTextMessage(trimmed);
      }
    } else {
      _messages.add(ChatMessage.system('Agent is not connected.'));
      notifyListeners();
    }
  }

  void toggleWhisperMode() {
    _userMuteOverride = true;
    if (_splitPipeline) {
      _ttsMuted = !_ttsMuted;
      notifyListeners();
      return;
    }
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

  /// Apply the mute policy on call phase transitions.
  ///
  /// A new call starting (initiating / ringing) resets the user override so
  /// the configured policy takes effect fresh. Once the user manually toggles
  /// mute during a call, the policy stops interfering until the next call.
  void _applyMutePolicy(CallPhase phase) {
    // New call → reset override so the policy applies from scratch.
    if (phase == CallPhase.initiating || phase == CallPhase.ringing) {
      _userMuteOverride = false;
    }

    // User manually toggled — their choice wins for this call.
    if (_userMuteOverride) return;

    final policy = effectiveMutePolicy;

    if (policy == AgentMutePolicy.stayUnmuted) {
      bool changed = false;
      if (_muted) {
        _muted = false;
        _whisper.muted = false;
        if (!_speaking) _statusText = 'Listening';
        changed = true;
      }
      if (_splitPipeline) {
        if (_ttsMuted) {
          _ttsMuted = false;
          changed = true;
        }
      } else {
        if (_whisperMode) {
          _whisperMode = false;
          if (_active) {
            _whisper.setModalities(['text', 'audio']);
          }
          changed = true;
        }
      }
      if (changed) notifyListeners();
      return;
    }

    if (policy != AgentMutePolicy.autoToggle) return;

    if (phase == CallPhase.settling || phase == CallPhase.connected) {
      bool changed = false;
      if (_muted) {
        _muted = false;
        _whisper.muted = false;
        if (!_speaking) _statusText = 'Listening';
        changed = true;
      }
      if (_splitPipeline) {
        if (_ttsMuted) {
          _ttsMuted = false;
          changed = true;
        }
      } else {
        if (_whisperMode) {
          _whisperMode = false;
          if (_active) {
            _whisper.setModalities(['text', 'audio']);
          }
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } else if (phase == CallPhase.ended || phase == CallPhase.failed) {
      bool changed = false;
      if (!_muted) {
        _muted = true;
        _whisper.muted = true;
        if (!_speaking) _statusText = 'Not Listening...';
        changed = true;
      }
      if (_splitPipeline) {
        if (!_ttsMuted) {
          _ttsMuted = true;
          changed = true;
        }
      } else {
        if (!_whisperMode) {
          _whisperMode = true;
          if (_active) {
            _whisper.stopResponseAudio();
            _whisper.setModalities(['text']);
          }
          changed = true;
        }
      }
      if (changed) notifyListeners();
    }
  }

  void addSystemMessage(String text) {
    _messages.add(ChatMessage.system(text));
    notifyListeners();
  }

  /// Send a system-level context update that the model can see and act on.
  /// Also adds it to the local chat as a system message.
  void sendSystemEvent(String text, {bool requireResponse = false}) {
    _messages.add(ChatMessage.system(text));
    notifyListeners();

    if (_active) {
      if (requireResponse) {
        _whisper.sendSystemDirective(text);
      } else {
        _whisper.sendSystemContext(text);
      }
    }
    if (_splitPipeline && _textAgent != null) {
      if (requireResponse) {
        _textAgent!.sendUserMessage('[SYSTEM EVENT]: $text');
      } else {
        _textAgent!.addSystemContext('[SYSTEM EVENT]: $text');
      }
    }
  }

  void sendWhisperMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _messages.add(ChatMessage.whisper(trimmed));
    notifyListeners();

    if (_active) {
      if (_splitPipeline) {
        _textAgent!.sendUserMessage('[WHISPER from Host]: $trimmed');
      } else {
        _whisper.sendSystemContext('[WHISPER] $trimmed');
      }
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

    // Auto-mute/unmute based on policy
    _applyMutePolicy(phase);

    // Start/end call history records
    if (phase == CallPhase.initiating || phase == CallPhase.ringing) {
      callHistory?.startCallRecord(
        direction: (outbound ?? _isOutbound) ? 'outbound' : 'inbound',
        remoteIdentity: remoteIdentity ?? _remoteIdentity,
        remoteDisplayName: remoteDisplayName ?? _remoteDisplayName,
        localIdentity: localIdentity ?? _localIdentity,
      );

      // Auto-resolve remote party name from the contacts database so
      // transcript bubbles and agent instructions use the real name.
      final rid = remoteIdentity ?? _remoteIdentity;
      if (rid != null && remoteSpeaker.name.isEmpty) {
        final contact = contactService?.lookupByPhone(rid);
        final name = contact?['display_name'] as String?;
        if (name != null && name.isNotEmpty) {
          setRemotePartyName(name);
        }
      }
    }

    if (phase == CallPhase.ended || phase == CallPhase.failed) {
      final status = phase == CallPhase.failed ? 'failed' : 'completed';
      callHistory?.endCallRecord(status: status);

      // Store the remote party's voiceprint if we know who they are
      _saveRemoteVoiceprint();

      if (_remoteIdentity != null) _lastDialedNumber = _remoteIdentity;
      _remoteIdentity = null;
      _remoteDisplayName = null;
      _localIdentity = null;
      _connectedAt = null;
      _beepDetected = false;
      _voicemailPromptSent = false;
      _ivrHeard = false;
      _hasConnectedBefore = false;
      _clearRemotePartyName();
      _cancelSettleTimer();
      _cancelConnectedGreeting();
      _recentAgentTexts.clear();
      _pendingTranscripts.clear();
      _settleTranscripts.clear();
      _postSpeakFlushTimer?.cancel();
      _whisper.resetSpeakerIdentifier();
      _whisper.stopResponseAudio();
      _tts?.endGeneration();
      _textAgent?.reset();

      // Clean up any agent-initiated voice sampling still in progress
      if (_agentSampling) {
        try {
          _tapChannel.invokeMethod('stopVoiceSample');
        } catch (_) {}
        _agentSampling = false;
        _agentSamplePath = null;
      }

      // Return to idle after a brief delay so the agent can listen again
      // between calls. Without this, _callPhase stays at ended forever,
      // which blocks agent responses and keeps TTS muted.
      Future.delayed(const Duration(seconds: 2), () {
        if (_callPhase == CallPhase.ended || _callPhase == CallPhase.failed) {
          _callPhase = CallPhase.idle;
          _partyCount = 1;
          _userMuteOverride = false;
          // Restore listening state for split pipeline
          if (_splitPipeline && _ttsMuted) {
            _ttsMuted = false;
          }
          notifyListeners();
          debugPrint('[AgentService] Returned to idle after call ended');
        }
      });
    }

    if (phase == CallPhase.settling) {
      _startSettleTimer();
      _tts?.warmUp();
    } else if (_callPhase != CallPhase.settling) {
      _cancelSettleTimer();
    }

    if (!phaseChanged) {
      notifyListeners();
      return;
    }

    final demo = demoModeService;
    final maskedRemoteId = (demo != null && demo.enabled && _remoteIdentity != null)
        ? demo.maskPhone(_remoteIdentity!)
        : _remoteIdentity;
    final maskedRemoteName = (demo != null && demo.enabled && _remoteDisplayName != null)
        ? demo.maskDisplayName(_remoteDisplayName!)
        : _remoteDisplayName;
    final maskedLocalId = (demo != null && demo.enabled && _localIdentity != null)
        ? demo.maskPhone(_localIdentity!)
        : _localIdentity;

    final contextText = phase.contextMessage(
      partyCount: partyCount,
      remoteIdentity: maskedRemoteId,
      remoteDisplayName: maskedRemoteName,
      localIdentity: maskedLocalId,
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
    // Skip text agent context when promoting to connected after the
    // pre-greeting already fired — that context would flush into a
    // duplicate greeting response.
    if (!(phase == CallPhase.connected && _hasConnectedBefore)) {
      _textAgent?.addSystemContext(contextText);
    }

    if (phase == CallPhase.connected) {
      if (!_hasConnectedBefore) {
        _scheduleConnectedGreeting();
        _hasConnectedBefore = true;
      }
    } else {
      _cancelConnectedGreeting();
    }

    debugPrint(
        '[AgentService] Call phase: ${phase.name} parties=$partyCount remote=$_remoteIdentity');
  }

  /// Start the settling timer. When it fires without being extended by
  /// IVR detections, auto-promote to connected.
  void _startSettleTimer() {
    _settleTimer?.cancel();
    _preGreetTimer?.cancel();
    _ivrHitsInSettle = 0;
    _settleStartTime = DateTime.now();
    _settleTimer = Timer(const Duration(milliseconds: _settleWindowMs), () {
      _tryPromoteFromSettle();
    });
  }

  /// Extend settling when IVR audio keeps arriving, up to the hard ceiling.
  void _extendSettleTimer() {
    _settleTimer?.cancel();
    _preGreetTimer?.cancel();
    final elapsed = _settleStartTime != null
        ? DateTime.now().difference(_settleStartTime!).inMilliseconds
        : 0;
    if (elapsed >= _maxSettleMs) {
      debugPrint('[AgentService] Settle ceiling reached — force-promoting');
      _promoteToConnected();
      return;
    }
    _settleTimer = Timer(const Duration(milliseconds: _settleExtendMs), () {
      _tryPromoteFromSettle();
    });
  }

  /// Only promote to connected if no one is currently speaking (VAD inactive).
  /// If speech is ongoing (e.g. voicemail greeting still playing), reschedule
  /// — but honour the hard ceiling so we never stay in settling forever.
  void _tryPromoteFromSettle() {
    if (_callPhase != CallPhase.settling) return;
    final elapsed = _settleStartTime != null
        ? DateTime.now().difference(_settleStartTime!).inMilliseconds
        : 0;
    if (_whisper.vadActive && elapsed < _maxSettleMs) {
      debugPrint('[AgentService] Settle timer fired but VAD active — deferring');
      _settleTimer = Timer(const Duration(milliseconds: 1000), () {
        _tryPromoteFromSettle();
      });
      return;
    }
    if (elapsed >= _maxSettleMs) {
      debugPrint('[AgentService] Settle ceiling reached in VAD loop — force-promoting');
    }
    _promoteToConnected();
  }

  void _cancelSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _preGreetTimer?.cancel();
    _preGreetTimer = null;
    _ivrHitsInSettle = 0;
  }

  void _promoteToConnected() {
    _cancelSettleTimer();
    if (_callPhase != CallPhase.settling) return;

    _connectedAt = DateTime.now();
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

  /// Schedule a deferred nudge so the agent begins the conversation if the
  /// line stays quiet after connected. Cancelled when a transcript arrives
  /// first (the transcript flow will prompt the agent naturally).
  ///
  /// The greeting is VAD-aware: if the remote party is still speaking when
  /// the timer fires, it re-defers in 800 ms increments (up to 8 s) so the
  /// agent waits for a natural pause before talking.
  static const _maxGreetDeferMs = 8000;
  DateTime? _greetDeferStart;

  void _scheduleConnectedGreeting() {
    _connectedGreetTimer?.cancel();
    _greetDeferStart = null;
    _connectedGreetTimer = Timer(
      const Duration(milliseconds: _connectedGreetDelayMs),
      () => _tryFireConnectedGreeting(),
    );
  }

  void _tryFireConnectedGreeting() {
    if (_callPhase != CallPhase.connected) return;

    _greetDeferStart ??= DateTime.now();
    final elapsed =
        DateTime.now().difference(_greetDeferStart!).inMilliseconds;

    if (_whisper.vadActive && elapsed < _maxGreetDeferMs) {
      debugPrint('[AgentService] Greeting deferred — VAD still active');
      _connectedGreetTimer = Timer(const Duration(milliseconds: 800), () {
        _tryFireConnectedGreeting();
      });
      return;
    }

    _greetDeferStart = null;

    // If we captured transcripts during the settling phase, forward them
    // now so the LLM can respond to what the remote party actually said
    // instead of getting a generic "begin conversation" nudge.
    if (_settleTranscripts.isNotEmpty) {
      debugPrint('[AgentService] Connected greeting — forwarding ${_settleTranscripts.length} settle transcript(s)');
      _drainSettleTranscripts();
      return;
    }

    const prompt =
        '[SYSTEM] The call is connected and the line is quiet. '
        'If you heard a voicemail greeting followed by a beep, leave a brief voicemail now. '
        'Otherwise, begin the conversation per your job function instructions.';
    if (_splitPipeline && _textAgent != null) {
      _textAgent!.sendUserMessage(prompt);
    } else if (_active) {
      _whisper.sendSystemDirective(prompt);
    }
    debugPrint('[AgentService] Connected greeting triggered (line quiet)');
  }

  void _cancelConnectedGreeting() {
    _connectedGreetTimer?.cancel();
    _connectedGreetTimer = null;
  }

  /// Forward any transcripts captured during the settling phase to the LLM
  /// via the normal transcript processing path, then clear the buffer.
  void _drainSettleTranscripts() {
    if (_settleTranscripts.isEmpty) return;
    final batch = List<TranscriptionEvent>.from(_settleTranscripts);
    _settleTranscripts.clear();
    for (final event in batch) {
      _processTranscript(event);
    }
    debugPrint('[AgentService] Drained ${batch.length} settle transcript(s)');
  }

  /// Immediately prompt the agent to leave a voicemail — no timer delay.
  /// Called when a voicemail/IVR transcript is detected post-settle, or when
  /// the native Goertzel filter detects a beep tone ending.
  /// One-shot per call to prevent false positives from triggering loops.
  void _triggerVoicemailPrompt() {
    if (_callPhase != CallPhase.connected) return;
    if (_voicemailPromptSent) {
      debugPrint('[AgentService] Voicemail prompt already sent — skipping');
      return;
    }
    _voicemailPromptSent = true;
    const prompt =
        '[SYSTEM] You have reached voicemail and the beep has sounded. '
        'Leave your voicemail message NOW — recording is in progress.';
    if (_splitPipeline && _textAgent != null) {
      _textAgent!.sendUserMessage(prompt);
    } else if (_active) {
      _whisper.sendSystemDirective(prompt);
    }
    debugPrint('[AgentService] Voicemail prompt triggered immediately');
  }

  // MARK: - Native beep tone detection (Goertzel)

  /// Whether the beep arrived in a plausible voicemail window: during
  /// settling, or within 30s of connected promotion (voicemail greetings
  /// can recite the full phone number and run 15-20s).
  bool get _inBeepWindow {
    if (_callPhase == CallPhase.settling) return true;
    if (_callPhase == CallPhase.connected && _connectedAt != null) {
      final elapsed = DateTime.now().difference(_connectedAt!).inSeconds;
      return elapsed <= 30;
    }
    return false;
  }

  /// Handle method calls from native AudioTapChannel (beep detection events).
  /// Beep detection only acts if an IVR/voicemail transcript was already heard
  /// — prevents false triggers from hold music, DTMF, conference tones, etc.
  Future<dynamic> _handleNativeTapCall(MethodCall call) async {
    switch (call.method) {
      case 'onBeepDetected':
        if (!_ivrHeard || !_inBeepWindow || _voicemailPromptSent) {
          debugPrint(
              '[AgentService] Native beep IGNORED (ivr=$_ivrHeard window=${_inBeepWindow} sent=$_voicemailPromptSent)');
          break;
        }
        _beepDetected = true;
        debugPrint('[AgentService] Native beep tone DETECTED (IVR confirmed)');
        if (_callPhase == CallPhase.settling) {
          _promoteToConnected();
        }
        break;
      case 'onBeepEnded':
        if (!_beepDetected) break;
        debugPrint('[AgentService] Native beep tone ENDED');
        if (_callPhase == CallPhase.connected) {
          _cancelConnectedGreeting();
          _triggerVoicemailPrompt();
        }
        _beepDetected = false;
        break;
    }
  }

  /// Host manually confirms a real person is on the line, skipping the
  /// settle window immediately.
  void confirmPartyConnected() {
    if (_callPhase == CallPhase.settling || _callPhase == CallPhase.answered) {
      _promoteToConnected();
    }
  }

  void toggleMute() {
    _userMuteOverride = true;
    _muted = !_muted;
    _whisper.muted = _muted;
    if (!_speaking) {
      _statusText = _muted ? 'Not Listening...' : 'Listening';
    }
    notifyListeners();
  }

  Future<void> reconnect() async {
    _textAgentToolSub?.cancel();
    _textAgentSub?.cancel();
    _textAgent?.dispose();
    _textAgent = null;
    _textAgentConfig = null;
    _ttsAudioSub?.cancel();
    _ttsSpeakingSub?.cancel();
    _tts?.dispose();
    _tts = null;
    _ttsConfig = null;
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
    _ttsMuted = false;
    _userMuteOverride = false;
    _callPhase = CallPhase.idle;
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
    _cancelConnectedGreeting();
    _postSpeakFlushTimer?.cancel();
    _tapChannel.setMethodCallHandler(null);
    _textAgentToolSub?.cancel();
    _textAgentSub?.cancel();
    _textAgent?.dispose();
    _ttsAudioSub?.cancel();
    _ttsSpeakingSub?.cancel();
    _tts?.dispose();
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
