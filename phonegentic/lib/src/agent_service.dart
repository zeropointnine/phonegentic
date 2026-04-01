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
      if (!_splitPipeline || selected.whisperByDefault) {
        _setWhisperMode(selected.whisperByDefault);
      }
    }
    _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);
    _pushInstructionsIfLive();
    notifyListeners();
  }

  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<AudioResponseEvent>? _audioSub;
  StreamSubscription<TranscriptionEvent>? _transcriptSub;
  StreamSubscription<ResponseTextEvent>? _responseTextSub;
  StreamSubscription<FunctionCallEvent>? _functionCallSub;
  StreamSubscription<ResponseTextEvent>? _textAgentSub;

  TextAgentService? _textAgent;
  TextAgentConfig? _textAgentConfig;
  bool get _splitPipeline => _textAgent != null;

  ElevenLabsTtsService? _tts;
  TtsConfig? _ttsConfig;
  StreamSubscription<Uint8List>? _ttsAudioSub;
  StreamSubscription<bool>? _ttsSpeakingSub;

  String? _streamingMessageId;

  // Deduplication: skip identical transcripts arriving within a short window
  String _lastTranscriptText = '';
  DateTime _lastTranscriptTime = DateTime(2000);

  // Cooldown after agent stops speaking to let TTS drain from whisper buffer
  DateTime _speakingEndTime = DateTime(2000);
  int _echoGuardMs = 2500;

  // Recent agent response texts for text-based echo suppression.
  // If an incoming transcript fuzzy-matches a recent agent response, it is
  // almost certainly the agent's own TTS being picked up by the mic.
  final List<String> _recentAgentTexts = [];
  static const _maxRecentAgentTexts = 5;

  // Settling: buffer window after SIP CONFIRMED to filter auto-attendant/IVR
  Timer? _settleTimer;
  int _ivrHitsInSettle = 0;
  static const _settleWindowMs = 8000;
  static const _settleExtendMs = 5000;

  bool get active => _active;
  bool get muted => _muted;
  bool get speaking => _speaking;
  bool get whisperMode => _whisperMode;
  bool get canToggleWhisper => !_splitPipeline;
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

  Speaker get hostSpeaker =>
      _bootContext.speakers.isNotEmpty
          ? _bootContext.speakers.first
          : Speaker(role: 'Host', source: 'mic');
  Speaker get remoteSpeaker =>
      _bootContext.speakers.length > 1
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
    _init();
  }

  Future<void> _init() async {
    try {
      _syncBootContextFromJobFunction();

      final config = await AgentConfigService.loadVoiceConfig();
      _echoGuardMs = config.echoGuardMs;
      _textAgentConfig = await AgentConfigService.loadTextConfig();
      _ttsConfig = await AgentConfigService.loadTtsConfig();
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
        _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);
        _pushInstructionsIfLive();
      }

      _messages.clear();
      if (_active) {
        await _loadPreviousConversation();
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
        _statusText = isSpeaking ? 'Speaking' : (_muted ? 'Not Listening...' : 'Listening');
        if (!isSpeaking) _speakingEndTime = DateTime.now();
        notifyListeners();
      });

      int audioChunkCount = 0;
      _audioSub = _whisper.audioResponses.listen((event) {
        if (_whisperMode) return;
        if (!_callPhase.isActive && _callPhase != CallPhase.idle) return;
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

      _initTextAgent();

      debugPrint('[AgentService] Started: model=${config.model} voice=${config.voice}');
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

    // Set the whisper flag so OpenAI audio responses are suppressed on the
    // Dart side, but do NOT change modalities on the server — text-only
    // modalities disable VAD which kills transcription.
    _whisperMode = true;

    _initTts();

    debugPrint('[AgentService] Split pipeline active: ${tc.provider.name} text agent');
  }

  void _initTts() {
    final tc = _ttsConfig;
    debugPrint('[AgentService] TTS config: '
        'provider=${tc?.provider.name} '
        'configured=${tc?.isConfigured}');
    if (tc == null || !tc.isConfigured) return;

    _tts = ElevenLabsTtsService(config: tc);

    int elChunkCount = 0;
    _ttsAudioSub = _tts!.audioChunks.listen((pcm) {
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
      }
    });

    debugPrint('[AgentService] ElevenLabs TTS active: '
        'voice=${tc.elevenLabsVoiceId} model=${tc.elevenLabsModelId}');
  }

  String _buildTextAgentInstructions() {
    final hasTts = _tts != null;
    final ctx = AgentBootContext(
      role: _bootContext.role,
      jobFunction: _bootContext.jobFunction,
      speakers: _bootContext.speakers,
      guardrails: _bootContext.guardrails,
      textOnly: !hasTts,
    );
    final base = ctx.toInstructions();
    final prompt = _textAgentConfig?.systemPrompt ?? '';
    if (prompt.isNotEmpty) {
      return '$base\n\n## Additional Instructions\n$prompt';
    }
    return base;
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
        debugPrint('[AgentService] Loaded ${speakers.length} known speaker voiceprints');
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
      final startedAt = DateTime.tryParse(
              call['started_at'] as String? ?? '') ??
          DateTime.now();
      final dateLabel =
          '${startedAt.month}/${startedAt.day}/${startedAt.year} '
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
      final tWords = lower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      final aWords = agentLower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      if (tWords.isNotEmpty && aWords.isNotEmpty) {
        final overlap = tWords.intersection(aWords).length;
        if (overlap / tWords.length >= 0.6) return true;
      }
    }
    return false;
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
    final isRemote = source == 'remote';
    final role = isRemote ? ChatRole.remoteParty : ChatRole.host;
    final speaker = isRemote ? remoteSpeaker : hostSpeaker;

    // If voiceprint identified a name and the speaker doesn't have one yet,
    // update the speaker label and push refreshed instructions.
    if (voiceprintName.isNotEmpty && speaker.name.isEmpty) {
      speaker.name = voiceprintName;
      _pushInstructionsIfLive();
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

    _textAgent?.addTranscript(speaker.label, text);
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

    // Pipe text delta to ElevenLabs TTS for voice output
    if (_tts != null && event.text.isNotEmpty) {
      if (_streamingMessageId == null) {
        _tts!.startGeneration();
      }
      _tts!.sendText(event.text);
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
    if (_splitPipeline) return;
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
    if (_splitPipeline) return;
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
      _clearRemotePartyName();
      _cancelSettleTimer();
      _recentAgentTexts.clear();
      _whisper.resetSpeakerIdentifier();
      _textAgent?.reset();
      _tts?.endGeneration();
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
    _textAgent?.addSystemContext(contextText);

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
