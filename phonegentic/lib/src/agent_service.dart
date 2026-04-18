import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sip_ua/sip_ua.dart';

import 'agent_config_service.dart';
import 'calendar_sync_service.dart';
import 'call_history_service.dart';
import 'chrome/flight_aware_service.dart';
import 'chrome/gmail_config.dart';
import 'chrome/gmail_service.dart';
import 'chrome/google_calendar_config.dart';
import 'chrome/google_calendar_service.dart';
import 'chrome/google_search_service.dart';
import 'conference/conference_service.dart';
import 'contact_service.dart';
import 'demo_mode_service.dart';
import 'db/call_history_db.dart';
import 'manager_presence_service.dart';
import 'user_config_service.dart';
import 'elevenlabs_api_service.dart';
import 'ivr_detector.dart';
import 'job_function_service.dart';
import 'messaging/messaging_service.dart';
import 'messaging/models/sms_message.dart';
import 'messaging/phone_numbers.dart';
import 'models/agent_context.dart';
import 'models/chat_message.dart';
import 'models/transfer_rule.dart';
import 'transfer_rule_service.dart';
import 'tear_sheet_service.dart';
import 'elevenlabs_tts_service.dart';
import 'kokoro_tts_service.dart';
import 'on_device_config.dart';
import 'llm/llm_interfaces.dart';
import 'text_agent_service.dart';
import 'vocal_expressions.dart';
import 'whisper_realtime_service.dart';
import 'whisperkit_stt_service.dart';

class AgentService extends ChangeNotifier {
  final WhisperRealtimeService _whisper = WhisperRealtimeService();

  bool _active = false;
  bool _muted = false;
  bool _speaking = false;
  bool _whisperMode = false;
  bool _isLocalSttMode = false;
  String _statusText = 'Initializing...';
  AgentMutePolicy _globalMutePolicy = AgentMutePolicy.autoToggle;
  bool _userMuteOverride = false;

  final Queue<double> _levels = Queue<double>();
  static const int waveformBars = 14;

  // TTS waveform: audio chunks arrive in a burst but play over seconds.
  // Slice each chunk into 100ms segments, queue the per-segment RMS,
  // and drain at playback rate so the waveform tracks actual audio.
  final Queue<double> _ttsLevelQueue = Queue<double>();
  Timer? _ttsLevelTimer;
  static const int _ttsLevelIntervalMs = 100;
  static const int _samplesPerSegment = 2400; // 100ms at 24kHz

  void _pushTtsAudioLevel(Uint8List pcm16) {
    if (pcm16.length < 4) return;
    final bd = ByteData.sublistView(pcm16);
    final totalSamples = pcm16.length ~/ 2;

    for (int offset = 0; offset < totalSamples; offset += _samplesPerSegment) {
      final end = min(offset + _samplesPerSegment, totalSamples);
      final segLen = end - offset;
      double sum = 0;
      for (int i = offset; i < end; i++) {
        final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
        sum += s * s;
      }
      _ttsLevelQueue.addLast((sqrt(sum / segLen) * 4.0).clamp(0.0, 1.0));
    }

    _ttsLevelTimer ??= Timer.periodic(
      const Duration(milliseconds: _ttsLevelIntervalMs),
      (_) => _drainTtsLevel(),
    );
  }

  void _drainTtsLevel() {
    if (_ttsLevelQueue.isEmpty) {
      _ttsLevelTimer?.cancel();
      _ttsLevelTimer = null;
      notifyListeners();
      return;
    }
    final level = _ttsLevelQueue.removeFirst();
    _levels.addLast(level);
    while (_levels.length > waveformBars) {
      _levels.removeFirst();
    }
    notifyListeners();
  }

  void _stopTtsLevelDrain() {
    _ttsLevelTimer?.cancel();
    _ttsLevelTimer = null;
    _ttsLevelQueue.clear();
  }

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
  String? _priorCallTranscript;

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
  MessagingService? _messagingService;
  DemoModeService? demoModeService;
  ManagerPresenceService? managerPresenceService;

  MessagingService? get messagingService => _messagingService;
  set messagingService(MessagingService? svc) {
    if (svc == _messagingService) return;
    _inboundSmsSub?.cancel();
    _messagingService = svc;
    if (svc != null) {
      _inboundSmsSub = svc.inboundMessages.listen(_onInboundSms);
    }
  }

  FlightAwareService? flightAwareService;
  GmailService? gmailService;
  GoogleCalendarService? googleCalendarService;
  GoogleSearchService? googleSearchService;
  JobFunctionService? _jobFunctionService;
  ConferenceService? conferenceService;
  TransferRuleService? _transferRuleService;
  SIPUAHelper? sipHelper;

  TransferRuleService? get transferRuleService => _transferRuleService;
  set transferRuleService(TransferRuleService? svc) {
    _transferRuleService = svc;
    svc?.loadAll();
  }

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
    if (_bootContext.kokoroVoiceStyle != null && _kokoroTts != null) {
      _kokoroTts!.setVoice(_bootContext.kokoroVoiceStyle!);
    }
    _pushInstructionsIfLive();
    notifyListeners();
  }

  /// Enforce stayMuted / stayUnmuted policy on startup or job function switch.
  /// Skipped when a call is active — [_applyMutePolicy] handles call phases.
  void _applyInitialMuteState() {
    if (_callPhase.isActive ||
        _callPhase.isSettling ||
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
  StreamSubscription<bool>? _vadSub;
  StreamSubscription<AudioResponseEvent>? _audioSub;
  StreamSubscription<TranscriptionEvent>? _transcriptSub;
  StreamSubscription<ResponseTextEvent>? _responseTextSub;
  StreamSubscription<FunctionCallEvent>? _functionCallSub;

  // Local STT (WhisperKit / whisper.cpp) — active when SttProvider.whisperKit.
  SttConfig? _sttConfig;
  WhisperKitSttService? _whisperKitStt;
  StreamSubscription<Uint8List>? _localAudioSub;
  StreamSubscription<ResponseTextEvent>? _textAgentSub;
  StreamSubscription<ToolCallRequest>? _textAgentToolSub;
  StreamSubscription<SmsMessage>? _inboundSmsSub;

  TextAgentService? _textAgent;
  TextAgentConfig? _textAgentConfig;
  AgentManagerConfig _agentManagerConfig = const AgentManagerConfig();
  bool get _splitPipeline => _textAgent != null;

  ElevenLabsTtsService? _tts;
  KokoroTtsService? _kokoroTts;
  TtsConfig? _ttsConfig;
  bool _ttsMuted = false;
  bool _ttsInterrupted = false;
  StreamSubscription<Uint8List>? _ttsAudioSub;
  StreamSubscription<bool>? _ttsSpeakingSub;

  String? _streamingMessageId;
  int _ttsBracketDepth = 0;
  StreamingExpressionState _vocalExprState = StreamingExpressionState();

  /// When TTS is active, hold agent bubble text until the first PCM plays so
  /// the UI does not run ahead of speech. Raw model deltas accumulate here.
  bool _voiceHoldUntilFirstPcm = false;
  StringBuffer? _voiceUiBuffer;

  /// Set when Claude's isFinal arrives while the voice hold is still active.
  /// The PCM listener uses this to finalize the message on release.
  bool _voiceFinalPending = false;
  Timer? _voiceFinalTimer;

  void _resetVoiceUiSyncState() {
    _voiceHoldUntilFirstPcm = false;
    _voiceUiBuffer = null;
    _voiceFinalPending = false;
    _voiceFinalTimer?.cancel();
    _voiceFinalTimer = null;
  }

  /// Call before routing TTS PCM to the speaker. Flushes `_voiceUiBuffer`
  /// into the streaming agent message on the first chunk of each generation.
  void _releaseVoiceUiIfWaitingForTts(Uint8List pcm) {
    if (pcm.isEmpty) return;
    if (!_voiceHoldUntilFirstPcm) return;
    if (_streamingMessageId == null) {
      _resetVoiceUiSyncState();
      return;
    }
    final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
    if (idx < 0) {
      _resetVoiceUiSyncState();
      return;
    }
    if (_voiceUiBuffer != null && _voiceUiBuffer!.isNotEmpty) {
      _messages[idx].text = _voiceUiBuffer.toString();
      _voiceUiBuffer = null;
    }
    _voiceHoldUntilFirstPcm = false;

    if (_voiceFinalPending) {
      _messages[idx].isStreaming = false;
      _voiceFinalPending = false;
      _voiceFinalTimer?.cancel();
      _voiceFinalTimer = null;
      _streamingMessageId = null;
    }
    notifyListeners();
  }

  /// Safety fallback: release voice hold if TTS never produced audio.
  void _forceReleaseVoiceHold() {
    if (!_voiceHoldUntilFirstPcm) return;
    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        if (_voiceUiBuffer != null && _voiceUiBuffer!.isNotEmpty) {
          _messages[idx].text = _voiceUiBuffer.toString();
        }
        _messages[idx].isStreaming = false;
      }
    }
    _resetVoiceUiSyncState();
    _streamingMessageId = null;
    notifyListeners();
  }

  // Agent-initiated voice sampling state
  static const _tapChannel = MethodChannel('com.agentic_ai/audio_tap_control');
  bool _agentSampling = false;
  String? _agentSamplePath;
  DateTime? _agentSamplingStartTime;
  String? _samplingMessageId;

  bool get agentSampling => _agentSampling;
  DateTime? get agentSamplingStartTime => _agentSamplingStartTime;

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

  // ---------------------------------------------------------------------------
  // Echo suppression & turn-taking — READ THIS BEFORE CHANGING TIMING VALUES
  // ---------------------------------------------------------------------------
  //
  // The agent plays TTS audio into the call.  The mic picks up that audio and
  // sends it to OpenAI Whisper, which transcribes it as if someone spoke.
  // Without suppression the agent would "hear itself" and respond in a loop.
  //
  // We use a THREE-LAYER defence, each tuned through painful iteration:
  //
  //  Layer 1 — Time-based buffering (_echoGuardMs)
  //    While _speaking is true (ElevenLabs reports generation active) and
  //    for _echoGuardMs milliseconds AFTER it stops, all incoming transcripts
  //    go into _pendingTranscripts instead of the LLM.  This catches the
  //    vast majority of echo because the mic-to-Whisper-to-transcript
  //    pipeline has ~1-2s latency after TTS finishes.
  //
  //    Tradeoff: too short → echoes leak through and the agent answers
  //    itself.  Too long → the agent is deaf to the human for too long
  //    after speaking, making the conversation feel sluggish.  2000ms is
  //    the current sweet spot.
  //
  //  Layer 2 — Text-based echo detection (_isEchoOfAgentResponse)
  //    Buffered transcripts (from layer 1) are checked against
  //    _recentAgentTexts before being forwarded to the LLM.  Two checks:
  //      a) Exact substring: "call lee" in "would you like me to call lee"
  //      b) Word overlap ≥40% (only for transcripts with 3+ words to avoid
  //         false positives on short commands like "Call Lee")
  //
  //    This also runs on LIVE transcripts, but only within _echoGuardMs*2
  //    of the last speech.  Beyond that window it's disabled so legitimate
  //    user commands sharing common words aren't suppressed.
  //
  //    Tradeoff: too aggressive → real speech blocked (the "Call Lee" bug).
  //    Too lax → echoes sneak through.  The 3-word minimum and time gate
  //    are the current balance.
  //
  //  Layer 3 — Native audio processing (outside this file)
  //    The AudioTap native layer does basic AEC (acoustic echo cancellation)
  //    via the WebRTC audio processing module, and mutes mic injection into
  //    the capture path while TTS audio is playing.  This reduces echo at
  //    the audio level before Whisper ever sees it.
  //
  // ## Transcript flow through the pipeline
  //
  //   Whisper transcription
  //     → _onTranscript()
  //       ├─ settling?  → buffer in _settleTranscripts, detect IVR
  //       ├─ speaking?  → buffer in _pendingTranscripts
  //       ├─ echo guard window?  → buffer in _pendingTranscripts
  //       └─ otherwise  → _processTranscript()
  //                         ├─ IVR filter
  //                         ├─ time-gated text echo check
  //                         ├─ deduplication
  //                         ├─ speaker identification
  //                         └─ → TextAgentService (Claude)
  //
  //   When speaking stops → _schedulePostSpeakFlush()
  //     → waits _echoGuardMs
  //     → _flushPendingTranscripts()
  //       ├─ text echo check each buffered transcript
  //       └─ survivors → _processTranscript()
  //
  // ## TTS text flow (Claude → ElevenLabs)
  //
  //   Claude streams text deltas via ResponseTextEvent
  //     → _appendStreamingResponse()
  //       ├─ isFinal? → endGeneration(), store in _recentAgentTexts
  //       ├─ suppress during settling/pre-connect
  //       ├─ first delta → startGeneration() on ElevenLabsTtsService
  //       ├─ _stripBracketsForTts() removes [stage directions]
  //       └─ sendText() → ElevenLabs text buffer → audio chunks
  //
  // ## VAD (Voice Activity Detection)
  //
  //   OpenAI Realtime provides server-side VAD via the 'server_vad' turn
  //   detection mode.  The _whisper.vadActive flag reflects whether OpenAI
  //   currently detects speech in the audio stream.  We use this to:
  //     - Defer the connected greeting while the remote party is speaking
  //       (_tryFireConnectedGreeting checks vadActive)
  //     - Defer the settle-to-connected promotion timer when VAD is active
  //
  //   VAD parameters (set in WhisperRealtimeService session config):
  //     threshold: 0.8       — sensitivity (0-1, higher = less sensitive)
  //     prefix_padding_ms: 300  — audio kept before speech onset
  //     silence_duration_ms: 1800 — silence before speech is considered ended
  //
  //   Tradeoff: lower silence_duration_ms makes the agent respond faster
  //   but risks cutting off mid-sentence pauses.  1800ms is a compromise.
  //
  // ---------------------------------------------------------------------------

  DateTime _speakingEndTime = DateTime(2000);
  int _echoGuardMs = 2000;

  final List<TranscriptionEvent> _pendingTranscripts = [];
  Timer? _postSpeakFlushTimer;
  Timer? _playbackEndDebounce;
  Timer? _ttsGenEndTimer;
  Timer? _playbackSafetyTimer;
  Timer? _vadInterruptDebounce;
  bool _ttsGenerationComplete = false;

  final List<String> _recentAgentTexts = [];
  static const _maxRecentAgentTexts = 5;

  // Settling: buffer window after SIP CONFIRMED to filter auto-attendant/IVR
  Timer? _settleTimer;
  Timer? _preGreetTimer;
  int _ivrHitsInSettle = 0;
  final List<TranscriptionEvent> _settleTranscripts = [];
  final List<String> _settleAccumulatedTexts = [];
  static const _settleWindowInboundMs = 1000;
  static const _settleWindowOutboundMs = 2000;
  static const _settleExtendMs = 8000;
  static const _maxSettleMs = 20000;
  DateTime? _settleStartTime;

  // Pre-greeting: on outbound calls, fire the greeting prompt during
  // settling so LLM + TTS latency is absorbed by the settle window.
  bool _preGreetInFlight = false;
  StringBuffer? _preGreetTextBuffer;
  String? _preGreetFinalText;
  bool _preGreetReady = false;

  /// Grace window after flushing the pre-greeting. Transcripts that arrive
  /// within this window are added as system context (not addTranscript) so
  /// the LLM doesn't generate a duplicate greeting in response to the
  /// remote party's initial "Hello?".
  DateTime? _preGreetGraceUntil;

  /// Grace period after a connected greeting fires. Short remote-party
  /// acknowledgments (< 4 words) during this window are added as context
  /// only so the LLM doesn't re-greet in response to "Hello?" / "Hi".
  DateTime? _postGreetGraceUntil;

  // Beep-watch: after IVR detected and speech stops, wait for a beep.
  Timer? _beepWatchTimer;
  static const _beepWatchTimeoutMs = 3000;
  static const _beepWatchSilenceMs = 1500;
  Timer? _beepWatchSilenceTimer;
  bool _inBeepWatchMode = false;

  // Cadence tracking: monitor speech patterns during settling to detect
  // automated greetings vs. human responses.
  Timer? _cadenceTimer;
  DateTime? _vadSpeechStartTime;
  int _cumulativeSpeechMs = 0;
  int _settleWordCount = 0;
  static const _cadenceCheckIntervalMs = 500;

  // Deferred greeting: nudge the agent to begin if the line stays quiet
  // after transitioning to connected.
  Timer? _connectedGreetTimer;
  static const _connectedGreetDelayMs = 500;

  bool get active => _active;
  bool get muted => _muted;
  bool get speaking => _speaking || _ttsLevelTimer != null;
  bool get whisperMode => _splitPipeline ? _ttsMuted : _whisperMode;
  bool get canToggleWhisper => true;

  /// True when TTS is actively playing — used by the UI to slow the typewriter
  /// reveal so text matches speech pace. Goes false on interrupt so the widget
  /// can snap any unrevealed text immediately.
  bool get ttsActiveForUi =>
      _splitPipeline &&
      _hasTts &&
      !_ttsMuted &&
      !_muted &&
      (_speaking || _whisper.isTtsPlaying);
  String get statusText => _statusText;
  List<double> get levels => _levels.toList();

  /// Last pipeline error (Claude / TTS / Whisper). Null when healthy.
  String? _pipelineError;
  String? get pipelineError => _pipelineError;
  void clearPipelineError() {
    _pipelineError = null;
    notifyListeners();
  }

  /// Extract a human-readable summary from a raw error string.
  static String _formatPipelineError(String raw) {
    // Claude credit / billing errors
    if (raw.contains('credit balance is too low')) {
      return 'LLM API: credit balance too low';
    }
    // Claude auth
    if (raw.contains('401') || raw.contains('authentication_error')) {
      return 'LLM API: invalid API key';
    }
    // Claude model not found
    if (raw.contains('not_found_error') || raw.contains('model_not_found')) {
      return 'LLM API: model not found';
    }
    // Claude rate limit
    if (raw.contains('rate_limit') || raw.contains('429')) {
      return 'LLM API: rate limited';
    }
    // Generic – trim to something readable
    final match = RegExp(r'"message"\s*:\s*"([^"]+)"').firstMatch(raw);
    if (match != null) return match.group(1)!;
    if (raw.length > 120) return '${raw.substring(0, 117)}...';
    return raw;
  }
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
    if (_splitPipeline) {
      _ttsMuted = enabled;
    }
    if (_active) {
      if (enabled) _whisper.stopResponseAudio();
      _whisper.setModalities(enabled ? ['text'] : ['text', 'audio']);
    }
  }

  Future<void> _pushInstructionsIfLive() async {
    if (!_active) return;
    final base = _bootContext.toInstructions();
    final flight = _buildFlightAwareContext();
    final gmail = _buildGmailContext();
    final gcal = _buildGoogleCalendarContext();
    final gsearch = _buildGoogleSearchContext();
    final awareness = _buildReminderAndAwarenessContext();
    _whisper.updateSessionInstructions('$base$flight$gmail$gcal$gsearch$awareness');
    _textAgent?.updateInstructions(_buildTextAgentInstructions());
    _applyIntegrationTools();
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

      _sttConfig = await AgentConfigService.loadSttConfig();
      final config = await AgentConfigService.loadVoiceConfig();
      _echoGuardMs = config.echoGuardMs;
      _textAgentConfig = await AgentConfigService.loadTextConfig();
      _ttsConfig = await AgentConfigService.loadTtsConfig();
      _agentManagerConfig = await UserConfigService.loadAgentManagerConfig();

      // ── Kokoro TTS diagnostic ──
      debugPrint('[KokoroTTS-DIAG] OnDeviceConfig.enabled=${OnDeviceConfig.enabled}');
      debugPrint('[KokoroTTS-DIAG] OnDeviceConfig.isSupported=${OnDeviceConfig.isSupported}');
      debugPrint('[KokoroTTS-DIAG] TTS config loaded: provider=${_ttsConfig?.provider.name} '
          'configured=${_ttsConfig?.isConfigured} '
          'kokoroVoice=${_ttsConfig?.kokoroVoiceStyle}');
      debugPrint('[KokoroTTS-DIAG] TextAgent config: '
          'enabled=${_textAgentConfig?.enabled} '
          'provider=${_textAgentConfig?.provider.name} '
          'configured=${_textAgentConfig?.isConfigured}');
      debugPrint('[KokoroTTS-DIAG] VoiceAgent config: '
          'enabled=${config.enabled} configured=${config.isConfigured}');

      // ── Local STT branch (whisper.cpp / WhisperKit) ──────────────────────
      if (_sttConfig?.provider == SttProvider.whisperKit &&
          OnDeviceConfig.isSupported) {
        await _initLocalSttPath();
        return;
      }
      // ─────────────────────────────────────────────────────────────────────

      if (!config.enabled || !config.isConfigured) {
        _statusText = 'Not configured';
        _messages.clear();
        _resetVoiceUiSyncState();
        _streamingMessageId = null;
        _messages.add(ChatMessage.system(
            'Voice agent not configured. Go to Settings > Agents to set up.'));
        notifyListeners();
        return;
      }

      _statusText = 'Connecting...';
      _messages.clear();
      _smsHistoryLoadedPhones.clear();
      _resetVoiceUiSyncState();
      _streamingMessageId = null;
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
      _resetVoiceUiSyncState();
      _streamingMessageId = null;
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
        if (isSpeaking) {
          _ttsGenEndTimer?.cancel();
        }
        _speaking = isSpeaking;
        _statusText = isSpeaking
            ? 'Speaking'
            : (_muted ? 'Not Listening...' : 'Listening');
        if (!isSpeaking) {
          _speakingEndTime = DateTime.now();
          _schedulePostSpeakFlush();
          _onTtsGenerationDone();
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
      _vadSub = _whisper.vadEvents.listen(_onVadEvent);

      _initTextAgent();
      _applyIntegrationTools();

      // Apply the job function's ElevenLabs voice now that TTS is initialised.
      // The earlier updateVoiceId call (before _initTextAgent) was a no-op
      // because _tts hadn't been created yet.
      _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);

      debugPrint(
          '[AgentService] Started: model=${config.model} voice=${config.voice}');
    } catch (e) {
      _statusText = 'Error';
      _active = false;
      _pipelineError = _formatPipelineError('$e');
      _messages.add(ChatMessage.system('Error: $e'));
      debugPrint('[AgentService] Init failed: $e');
      notifyListeners();
    }
  }

  void _initTextAgent() {
    final tc = _textAgentConfig;
    debugPrint('[KokoroTTS-DIAG] _initTextAgent: '
        'enabled=${tc?.enabled} '
        'provider=${tc?.provider.name} '
        'configured=${tc?.isConfigured}');
    if (tc == null || !tc.enabled || !tc.isConfigured) {
      debugPrint('[KokoroTTS-DIAG] _initTextAgent BAILING: '
          'text agent not configured — Kokoro TTS requires a Claude text agent');
      return;
    }
    if (tc.provider == TextAgentProvider.openai) {
      debugPrint('[KokoroTTS-DIAG] _initTextAgent BAILING: '
          'provider is OpenAI (not Claude) — split pipeline not active');
      return;
    }

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
    debugPrint('[KokoroTTS-DIAG] _initTts: '
        'provider=${tc?.provider.name} '
        'configured=${tc?.isConfigured}');
    if (tc == null || !tc.isConfigured) {
      debugPrint('[KokoroTTS-DIAG] _initTts BAILING: TTS not configured');
      return;
    }

    switch (tc.provider) {
      case TtsProvider.elevenlabs:
        debugPrint('[KokoroTTS-DIAG] _initTts: using ElevenLabs (not Kokoro)');
        _initElevenLabsTts(tc);
        return;
      case TtsProvider.kokoro:
        debugPrint('[KokoroTTS-DIAG] _initTts: → _initKokoroTts()');
        _initKokoroTts(tc);
        return;
      case TtsProvider.none:
        debugPrint('[KokoroTTS-DIAG] _initTts: provider is none, skipping');
        return;
    }
  }

  // ── Local STT initialisation ──────────────────────────────────────────────
  //
  // Called when SttProvider.whisperKit is selected and the platform is
  // supported. Does NOT open an OpenAI WebSocket. Audio flows:
  //
  //   PulseAudio mic → _whisper.rawAudio → WhisperKitSttService.feedAudio()
  //   → whisper.cpp inference → _onTranscript() → text LLM → TTS
  //
  Future<void> _initLocalSttPath() async {
    _isLocalSttMode = true;
    _statusText = 'Initializing...';
    _messages.clear();
    _smsHistoryLoadedPhones.clear();
    _resetVoiceUiSyncState();
    _streamingMessageId = null;
    _messages.add(ChatMessage.system('Loading STT model...'));
    notifyListeners();

    try {
      _whisperKitStt = WhisperKitSttService(config: _sttConfig!);
      await _whisperKitStt!.initialize();

      if (!_whisperKitStt!.isInitialized) {
        _statusText = 'STT model not found';
        _messages.clear();
        _messages.add(ChatMessage.system(
            'Whisper model not found. Run scripts/download_models.sh whisper '
            'to download it, then restart the app.'));
        notifyListeners();
        return;
      }

      _active = true;
      _statusText = 'Listening';
      _messages.clear();
      await _loadPreviousConversation();
      final jfTitle = _jobFunctionService?.selected?.title;
      final label = jfTitle != null ? 'Ready as "$jfTitle".' : 'Ready.';
      _messages.add(ChatMessage.agent(
          '$label On-device STT active. Speak and I\'ll assist via text.'));
      notifyListeners();

      // Capture mic only — speaker output must NOT be captured here because
      // the rawAudio stream feeds directly into whisper.cpp.  Capturing output
      // would cause TTS playback to be transcribed as user speech and looped
      // back to the LLM.  (The OpenAI Realtime path captures output because
      // the server does echo cancellation; whisper.cpp does not.)
      await _whisper.startAudioTap(captureInput: true, captureOutput: false);

      // Wire raw mic audio → whisper.cpp.
      await _whisperKitStt!.startTranscription();
      _localAudioSub = _whisper.rawAudio.listen((chunk) {
        // Gate audio during TTS playback — whisper.cpp has no AEC, so any
        // speaker bleed would be transcribed as user speech.  Dropping mic
        // input while TTS is active prevents acoustic echo from reaching
        // inference.  The VAD timer sees silence and drains without running
        // whisper_full().
        if (!_muted && !_speaking && !_whisper.isTtsPlaying) {
          _whisperKitStt?.feedAudio(chunk);
        }
      });

      // Audio level waveform — works via sendAudio() even without OpenAI conn.
      _levelSub = _whisper.audioLevels.listen((level) {
        _levels.addLast(level);
        while (_levels.length > waveformBars) {
          _levels.removeFirst();
        }
        notifyListeners();
      });

      // Convert WhisperKitTranscription → TranscriptionEvent for existing handler.
      _transcriptSub = _whisperKitStt!.transcriptions
          .map((t) => TranscriptionEvent(
                text: t.text,
                isFinal: t.isFinal,
                itemId: '',
              ))
          .listen(_onTranscript);

      // Text LLM + TTS pipeline.
      // _initTextAgent() skips OpenAI text providers (designed for the split-
      // pipeline where OpenAI Realtime handles everything). In local STT mode
      // we need a text agent regardless of provider, so we fall back to direct
      // init when _initTextAgent() leaves _textAgent null.
      _syncBootContextFromJobFunction();
      _initTextAgent();
      if (_textAgent == null) {
        final tc = _textAgentConfig;
        if (tc != null && tc.enabled && tc.isConfigured) {
          _textAgent = TextAgentService(
            config: tc,
            systemInstructions: _buildTextAgentInstructions(),
          );
          _textAgentSub = _textAgent!.responses.listen(_appendStreamingResponse);
          _textAgentToolSub = _textAgent!.toolCalls.listen(_onTextAgentToolCall);
          // _initTextAgent normally calls _initTts; mirror that here.
          _initTts();
        } else {
          // No text agent configured — TTS alone (responses appear in chat only).
          _initTts();
        }
      }
      // _initTextAgent already called _initTts when it set _textAgent, so
      // only call updateVoiceId here (not _initTts again).
      _applyIntegrationTools();
      _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);

      debugPrint('[AgentService] Local STT active: '
          'model=${_sttConfig!.whisperKitModelSize} '
          'gpu=${_sttConfig!.whisperKitUseGpu}');
    } catch (e) {
      _statusText = 'Error';
      _active = false;
      _messages.add(ChatMessage.system('Local STT error: $e'));
      debugPrint('[AgentService] Local STT init failed: $e');
      notifyListeners();
    }
  }
  // ─────────────────────────────────────────────────────────────────────────

  void _initElevenLabsTts(TtsConfig tc) {
    _tts = ElevenLabsTtsService(config: tc);

    int elChunkCount = 0;
    _ttsAudioSub = _tts!.audioChunks.listen((pcm) {
      if (_ttsMuted || _ttsInterrupted) return;
      _releaseVoiceUiIfWaitingForTts(pcm);
      _pushTtsAudioLevel(pcm);
      elChunkCount++;
      if (elChunkCount <= 3 || elChunkCount % 25 == 0) {
        debugPrint('[AgentService] ElevenLabs audio #$elChunkCount: '
            '${pcm.length} bytes → playResponseAudio');
      }
      _whisper.playResponseAudio(pcm);
    });

    _ttsSpeakingSub = _tts!.speakingState.listen((speaking) {
      if (speaking) {
        _ttsGenEndTimer?.cancel();
        _speaking = true;
        if (!_muted) {
          _statusText = 'Speaking';
          notifyListeners();
        }
      } else {
        _onTtsGenerationDone();
      }
    });

    debugPrint('[AgentService] ElevenLabs TTS active: '
        'voice=${tc.elevenLabsVoiceId} model=${tc.elevenLabsModelId}');
  }

  void _initKokoroTts(TtsConfig tc) {
    final kokoro = KokoroTtsService(config: tc);
    _kokoroTts = kokoro;

    kokoro.initialize().then((_) async {
      try {
        if (!kokoro.isInitialized) {
          debugPrint('[AgentService] Kokoro TTS failed to initialize');
          _kokoroTts = null;
          return;
        }
        await kokoro.setVoice(tc.kokoroVoiceStyle);
        await kokoro.warmUpSynthesis();
      } catch (e, st) {
        debugPrint('[AgentService] Kokoro post-init: $e\n$st');
      }
    });

    int chunkCount = 0;
    _ttsAudioSub = kokoro.audioChunks.listen((pcm) {
      if (_ttsMuted || _ttsInterrupted) return;
      _releaseVoiceUiIfWaitingForTts(pcm);
      _pushTtsAudioLevel(pcm);
      chunkCount++;
      if (chunkCount <= 3 || chunkCount % 25 == 0) {
        debugPrint('[AgentService] Kokoro audio #$chunkCount: '
            '${pcm.length} bytes → playResponseAudio');
      }
      _whisper.playResponseAudio(pcm);
    });

    _ttsSpeakingSub = kokoro.speakingState.listen((speaking) {
      if (speaking) {
        _ttsGenerationComplete = false;
        _speaking = true;
        if (!_muted) {
          _statusText = 'Speaking';
          notifyListeners();
        }
      } else {
        // All chunks have been queued to the playback pipeline, but PulseAudio
        // may still be draining the last buffer. Just set the flag — the next
        // onPlaybackComplete (final underflow) will fire with this flag true and
        // use the short 300ms debounce. Do NOT start a timer here: audio is
        // still playing and a premature timer would lift suppression too early.
        _ttsGenerationComplete = true;
      }
    });

    debugPrint(
        '[AgentService] Kokoro TTS active: voice=${tc.kokoroVoiceStyle}');
  }

  // -- Active TTS abstraction (ElevenLabs or Kokoro) --------------------------

  bool get _hasTts => _tts != null || _kokoroTts != null;

  void _activeTtsStartGeneration() {
    _ttsInterrupted = false;
    _tts?.startGeneration();
    _kokoroTts?.startGeneration();
  }

  static final _phonegenticRe = RegExp(r'Phonegentic', caseSensitive: false);

  void _activeTtsSendText(String text) {
    final fixed = text.replaceAll(_phonegenticRe, 'Phone-Jentic');
    _tts?.sendText(fixed);
    _kokoroTts?.sendText(fixed);
  }

  void _activeTtsEndGeneration() {
    _tts?.endGeneration();
    _kokoroTts?.endGeneration();
  }

  void _activeTtsWarmUp() {
    _tts?.warmUp();
    // Kokoro: discarded `warmup` synthesis runs once after init (see _initKokoroTts).
  }

  void _activeTtsDispose() {
    _tts?.dispose();
    _tts = null;
    _kokoroTts?.dispose();
    _kokoroTts = null;
  }

  CalendarSyncService? _calendarSync;
  set calendarSyncService(CalendarSyncService s) => _calendarSync = s;

  String _buildCalendarContext() {
    final sync = _calendarSync;
    if (sync == null) return '';

    final events = sync.events;
    if (events.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('\n## Local Calendar (Calendly-synced events stored in the app)');
    buf.writeln('These events are from the local database. When the manager asks '
        'about "my calendar", "my schedule", or "local calendar", refer to '
        'these events — do NOT open Google Calendar for this.');
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
    final hasTts =
        (_tts != null || _kokoroTts != null) && !_ttsMuted && !_muted;
    final ctx = AgentBootContext(
      name: _bootContext.name,
      role: _bootContext.role,
      jobFunction: _bootContext.jobFunction,
      speakers: _bootContext.speakers,
      guardrails: _bootContext.guardrails,
      textOnly: !hasTts,
      defaultCountryCode: _bootContext.defaultCountryCode,
    );
    final base = ctx.toInstructions();
    final calendar = _buildCalendarContext();
    final flight = _buildFlightAwareContext();
    final gmail = _buildGmailContext();
    final gcal = _buildGoogleCalendarContext();
    final gsearch = _buildGoogleSearchContext();
    final prompt = _textAgentConfig?.systemPrompt ?? '';
    final buf = StringBuffer(base);
    buf.write(_buildDateTimeContext());
    if (calendar.isNotEmpty) buf.write(calendar);
    if (flight.isNotEmpty) buf.write(flight);
    if (gmail.isNotEmpty) buf.write(gmail);
    if (gcal.isNotEmpty) buf.write(gcal);
    if (gsearch.isNotEmpty) buf.write(gsearch);
    if (_isCallerAgentManager) {
      final managerPhone = _agentManagerConfig.phoneNumber;
      buf.write('\n\n## Agent Manager'
          '\nThe current inbound caller is the designated **Agent Manager** '
          '(phone: $managerPhone) — '
          'they have the same authority as the host. Treat their requests '
          'exactly as you would the host\'s.'
          '\n\nThe manager has UNRESTRICTED access to every tool and action '
          'you can perform — no exceptions. This includes but is not limited '
          'to: sending texts, making calls, reading emails, searching '
          'contacts, listing and changing voices, cloning voices, creating '
          'transfer rules, managing reminders, looking up flights, managing '
          'calendars, running Google searches, and any other tool available '
          'to you. If the manager asks you to do something and you have a '
          'tool for it, execute it immediately. NEVER refuse a manager '
          'request or say you cannot do something — if the tool exists, use it.'
          '\n\nDo NOT apply inbound-caller restrictions to this person.'
          '\n\nWhen the agent manager says "me", "I", or "my" in requests '
          'like "send me a text", "text me", or "call me", they are '
          'referring to THEMSELVES at $managerPhone. Use that number as the '
          'recipient — do NOT ask who "me" is.');
    }
    buf.write(_buildReminderAndAwarenessContext());
    if (prompt.isNotEmpty) {
      buf.write('\n\n## Additional Instructions\n$prompt');
    }
    return buf.toString();
  }

  String _buildReminderAndAwarenessContext() {
    final buf = StringBuffer('\n\n## Reminders and Activity Awareness\n');
    buf.write(
        'You can create timed reminders for the manager using `create_reminder`. '
        'When someone asks to be reminded about something at a specific time, '
        'use this tool. Always offer to also add important reminders to Google Calendar.\n\n');
    buf.write(
        'Use `list_reminders` when the manager asks about scheduled reminders, '
        'upcoming events they set through you, or "do I have any reminders?". '
        'This returns all agent-created reminders from the local database.\n\n');
    buf.write(
        'When the manager returns after being away, or asks about recent activity, '
        'use `get_call_summary` to catch them up on what happened. Offer to play '
        'back recordings of specific calls if they exist.\n\n');
    buf.write(
        'You can play call recordings inline using `play_call_recording` when '
        'the manager wants to hear a specific call. Include the call_record_id '
        'from the call summary results.\n');

    if (managerPresenceService != null) {
      if (managerPresenceService!.isAway) {
        buf.write('\nNote: The manager appears to be away from the app.\n');
      }

      final pending = managerPresenceService!.pendingReminders;
      if (pending.isNotEmpty) {
        buf.write('\n### Current Pending Reminders\n');
        for (final r in pending.take(10)) {
          final title = r['title'] as String? ?? 'Untitled';
          final remindAt =
              DateTime.parse(r['remind_at'] as String).toLocal();
          final mins = remindAt.difference(DateTime.now()).inMinutes;
          final timeLabel = mins > 0 ? 'in $mins min' : 'overdue';
          buf.writeln('- "$title" $timeLabel (${_fmtTime(remindAt)})');
        }
      } else {
        buf.write('\nNo pending reminders at this time.\n');
      }
    }

    return buf.toString();
  }

  static String _buildDateTimeContext() {
    final now = DateTime.now();
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    final months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    final day = weekdays[now.weekday - 1];
    final month = months[now.month - 1];
    final h = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
    final m = now.minute.toString().padLeft(2, '0');
    final ap = now.hour >= 12 ? 'PM' : 'AM';
    final tz = now.timeZoneName;
    return '\n## Current Date & Time\n'
        '$day, $month ${now.day}, ${now.year} at $h:$m $ap $tz\n';
  }

  // ---------------------------------------------------------------------------
  // Dynamic integration tools
  // ---------------------------------------------------------------------------

  bool get _flightAwareEnabled =>
      flightAwareService != null && flightAwareService!.config.enabled;

  bool get _gmailEnabled =>
      gmailService != null && gmailService!.config.enabled;

  bool get _googleCalendarEnabled =>
      googleCalendarService != null && googleCalendarService!.config.enabled;

  bool get _googleSearchEnabled =>
      googleSearchService != null && googleSearchService!.config.enabled;

  String _buildFlightAwareContext() {
    if (!_flightAwareEnabled) return '';
    return '\n\n## Flight Lookup (FlightAware)\n'
        'You can look up real-time flight information using these tools:\n'
        '- **lookup_flight**: Look up a specific flight by number (e.g. UAL278, AA100, DAL405). '
        'Returns airline, origin/destination, departure/arrival times, status, and gate info.\n'
        '- **search_flights_by_route**: Search all flights between two airports using '
        'ICAO codes (e.g. KSFO→KJFK, KLAX→KORD). Returns a table of upcoming and recent flights.\n'
        'Use these when the caller or host asks about flight status, arrival times, '
        'which flights serve a route, or anything aviation-related.\n';
  }

  String _buildGmailContext() {
    if (!_gmailEnabled) return '';
    final access = gmailService!.config.readAccessMode;
    final accessNote = access == GmailReadAccess.hostOnly
        ? ' Note: email reading is restricted to the host only.'
        : access == GmailReadAccess.allowList
            ? ' Note: email reading is restricted to approved callers only.'
            : '';
    return '\n\n## Gmail Integration\n'
        'You can interact with the user\'s Gmail using these tools:\n'
        '- **send_gmail**: Send an email. Parameters: to (email address), subject, body.\n'
        '- **search_gmail**: Search the inbox. Parameter: query (Gmail search string).\n'
        '- **read_gmail**: Read a specific email. Parameters: query (search to find it), '
        'index (0-based, which result to open, default 0).\n'
        'Use these when asked to send, find, or read emails.$accessNote\n';
  }

  String _buildGoogleCalendarContext() {
    if (!_googleCalendarEnabled) return '';
    final access = googleCalendarService!.config.readAccessMode;
    final accessNote = access == CalendarReadAccess.hostOnly
        ? ' Note: calendar reading is restricted to the host only.'
        : access == CalendarReadAccess.allowList
            ? ' Note: calendar reading is restricted to approved callers only.'
            : '';
    return '\n\n## Google Calendar Integration\n'
        'You can interact with the user\'s Google Calendar using these tools:\n'
        '- **list_google_calendars**: List all available calendars (name + ID). '
        'Call this before creating events.\n'
        '- **create_google_calendar_event**: Create an event. Parameters: title, date (YYYY-MM-DD), '
        'start_time (HH:MM), end_time (HH:MM), description (optional), location (optional), '
        'calendar_id (optional — from list_google_calendars).\n'
        '- **create_new_google_calendar**: Create a brand-new calendar (not an event). '
        'Parameter: name (the calendar name, e.g. "Work", "Gym").\n'
        '- **read_google_calendar**: Read events for a date. Parameter: date (YYYY-MM-DD).\n'
        '- **sync_google_calendar**: Sync local calendar with Google Calendar (bidirectional).\n'
        '\n'
        '**Important**: When a user asks to create a calendar event, first call list_google_calendars. '
        'If multiple calendars are available, ask the user which calendar they want the event on '
        'before creating it. Pass the chosen calendar_id to create_google_calendar_event.$accessNote\n';
  }

  static const _flightToolsOpenAi = [
    {
      'type': 'function',
      'name': 'lookup_flight',
      'description': 'Look up real-time flight information by flight number. '
          'Returns airline, origin, destination, departure/arrival times, '
          'status, gate info.',
      'parameters': {
        'type': 'object',
        'properties': {
          'flight_number': {
            'type': 'string',
            'description':
                'Flight number (e.g. UAL278, AA100, DAL405). ICAO or IATA format.',
          },
        },
        'required': ['flight_number'],
      },
    },
    {
      'type': 'function',
      'name': 'search_flights_by_route',
      'description':
          'Search for all flights between two airports. Returns a list of '
              'upcoming and recent flights with airline, ident, aircraft, '
              'status, and times.',
      'parameters': {
        'type': 'object',
        'properties': {
          'origin': {
            'type': 'string',
            'description': 'Origin airport ICAO code (e.g. KSFO, KLAX, KJFK)',
          },
          'destination': {
            'type': 'string',
            'description':
                'Destination airport ICAO code (e.g. KJFK, KORD, KATL)',
          },
        },
        'required': ['origin', 'destination'],
      },
    },
  ];

  static final _flightToolsLlm = <LlmTool>[
    LlmTool(
      name: 'lookup_flight',
      description: 'Look up real-time flight information by flight number. '
          'Returns airline, origin, destination, departure/arrival times, '
          'status, gate info.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'flight_number': {
            'type': 'string',
            'description':
                'Flight number (e.g. UAL278, AA100, DAL405). ICAO or IATA format.',
          },
        },
        'required': ['flight_number'],
      },
    ),
    LlmTool(
      name: 'search_flights_by_route',
      description: 'Search all flights between two airports. Returns upcoming and '
          'recent flights with airline, ident, aircraft, status, and times.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'origin': {
            'type': 'string',
            'description': 'Origin airport ICAO code (e.g. KSFO, KLAX, KJFK)',
          },
          'destination': {
            'type': 'string',
            'description':
                'Destination airport ICAO code (e.g. KJFK, KORD, KATL)',
          },
        },
        'required': ['origin', 'destination'],
      },
    ),
  ];

  // ── Gmail tools ─────────────────────────────────────────────────────

  static const _gmailToolsOpenAi = [
    {
      'type': 'function',
      'name': 'send_gmail',
      'description': 'Send an email via Gmail. Composes and sends immediately.',
      'parameters': {
        'type': 'object',
        'properties': {
          'to': {
            'type': 'string',
            'description': 'Recipient email address.',
          },
          'subject': {
            'type': 'string',
            'description': 'Email subject line.',
          },
          'body': {
            'type': 'string',
            'description': 'Email body text.',
          },
        },
        'required': ['to', 'subject', 'body'],
      },
    },
    {
      'type': 'function',
      'name': 'search_gmail',
      'description':
          'Search the user\'s Gmail inbox. Returns a list of matching emails '
              'with sender, subject, snippet, and date.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Gmail search query (e.g. "from:alice subject:meeting", '
                    '"is:unread", "after:2026/01/01").',
          },
        },
        'required': ['query'],
      },
    },
    {
      'type': 'function',
      'name': 'read_gmail',
      'description':
          'Read the full content of a specific email found by searching Gmail.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Gmail search query to locate the email.',
          },
          'index': {
            'type': 'integer',
            'description':
                'Zero-based index of the search result to open (default 0 = first/newest).',
          },
        },
        'required': ['query'],
      },
    },
  ];

  static final _gmailToolsLlm = <LlmTool>[
    LlmTool(
      name: 'send_gmail',
      description: 'Send an email via Gmail. Composes and sends immediately.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'to': {
            'type': 'string',
            'description': 'Recipient email address.',
          },
          'subject': {
            'type': 'string',
            'description': 'Email subject line.',
          },
          'body': {
            'type': 'string',
            'description': 'Email body text.',
          },
        },
        'required': ['to', 'subject', 'body'],
      },
    ),
    LlmTool(
      name: 'search_gmail',
      description: 'Search the user\'s Gmail inbox. Returns matching emails with '
          'sender, subject, snippet, and date.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Gmail search query (e.g. "from:alice subject:meeting").',
          },
        },
        'required': ['query'],
      },
    ),
    LlmTool(
      name: 'read_gmail',
      description: 'Read the full content of a specific email found by searching Gmail.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Gmail search query to locate the email.',
          },
          'index': {
            'type': 'integer',
            'description':
                'Zero-based index of the search result to open (default 0).',
          },
        },
        'required': ['query'],
      },
    ),
  ];

  // ── Google Calendar tools ──────────────────────────────────────────

  static const _googleCalendarToolsOpenAi = [
    {
      'type': 'function',
      'name': 'list_google_calendars',
      'description':
          'List all available Google Calendars for the connected account. '
              'Returns calendar names and IDs. Call this before creating events '
              'so you can ask the user which calendar to use.',
      'parameters': {
        'type': 'object',
        'properties': {},
      },
    },
    {
      'type': 'function',
      'name': 'create_google_calendar_event',
      'description': 'Create an event on Google Calendar.',
      'parameters': {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Event title.',
          },
          'date': {
            'type': 'string',
            'description': 'Event date in YYYY-MM-DD format.',
          },
          'start_time': {
            'type': 'string',
            'description': 'Start time in HH:MM format (24-hour).',
          },
          'end_time': {
            'type': 'string',
            'description': 'End time in HH:MM format (24-hour).',
          },
          'description': {
            'type': 'string',
            'description': 'Optional event description.',
          },
          'location': {
            'type': 'string',
            'description': 'Optional event location.',
          },
          'calendar_id': {
            'type': 'string',
            'description':
                'Optional calendar ID to create the event on. Use list_google_calendars to get available IDs. '
                    'If omitted, uses the default calendar.',
          },
        },
        'required': ['title', 'date', 'start_time', 'end_time'],
      },
    },
    {
      'type': 'function',
      'name': 'read_google_calendar',
      'description':
          'Read all events from Google Calendar for a specific date.',
      'parameters': {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': 'Date to read events for in YYYY-MM-DD format.',
          },
        },
        'required': ['date'],
      },
    },
    {
      'type': 'function',
      'name': 'create_new_google_calendar',
      'description':
          'Create a brand-new Google Calendar (not an event — a whole new calendar). '
              'Use when the user wants to add a new calendar like "Work", "Gym", etc.',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Name for the new calendar.',
          },
        },
        'required': ['name'],
      },
    },
    {
      'type': 'function',
      'name': 'sync_google_calendar',
      'description':
          'Synchronize the local calendar with Google Calendar (bidirectional). '
              'Pulls events from Google and pushes local events to Google.',
      'parameters': {
        'type': 'object',
        'properties': {},
      },
    },
  ];

  static final _googleCalendarToolsLlm = <LlmTool>[
    LlmTool(
      name: 'list_google_calendars',
      description:
          'List all available Google Calendars for the connected account. '
          'Returns calendar names and IDs. Call this before creating events '
          'so you can ask the user which calendar to use.',
      inputSchema: {
        'type': 'object',
        'properties': {},
      },
    ),
    LlmTool(
      name: 'create_google_calendar_event',
      description: 'Create an event on Google Calendar.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Event title.',
          },
          'date': {
            'type': 'string',
            'description': 'Event date in YYYY-MM-DD format.',
          },
          'start_time': {
            'type': 'string',
            'description': 'Start time in HH:MM format (24-hour).',
          },
          'end_time': {
            'type': 'string',
            'description': 'End time in HH:MM format (24-hour).',
          },
          'description': {
            'type': 'string',
            'description': 'Optional event description.',
          },
          'location': {
            'type': 'string',
            'description': 'Optional event location.',
          },
          'calendar_id': {
            'type': 'string',
            'description':
                'Optional calendar ID to create the event on. Use list_google_calendars to get available IDs. '
                'If omitted, uses the default calendar.',
          },
        },
        'required': ['title', 'date', 'start_time', 'end_time'],
      },
    ),
    LlmTool(
      name: 'read_google_calendar',
      description: 'Read all events from Google Calendar for a specific date.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'date': {
            'type': 'string',
            'description': 'Date to read events for in YYYY-MM-DD format.',
          },
        },
        'required': ['date'],
      },
    ),
    LlmTool(
      name: 'create_new_google_calendar',
      description:
          'Create a brand-new Google Calendar (not an event — a whole new calendar). '
          'Use when the user wants to add a new calendar like "Work", "Gym", etc.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Name for the new calendar.',
          },
        },
        'required': ['name'],
      },
    ),
    LlmTool(
      name: 'sync_google_calendar',
      description: 'Synchronize local calendar with Google Calendar (bidirectional).',
      inputSchema: {
        'type': 'object',
        'properties': {},
      },
    ),
  ];

  // ── Google Search tools ─────────────────────────────────────────────

  String _buildGoogleSearchContext() {
    if (!_googleSearchEnabled) return '';
    return '\n\n## Google Search Integration\n'
        'You can search the web using Google:\n'
        '- **google_search**: Search Google for any query. Returns top results '
        'with title, URL, and snippet.\n'
        'Use this when the caller or host asks you to look something up, '
        'find information online, or answer factual questions you are '
        'unsure about.\n';
  }

  static const _googleSearchToolsOpenAi = [
    {
      'type': 'function',
      'name': 'google_search',
      'description':
          'Search Google and return top results with title, URL, and snippet.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query to send to Google.',
          },
        },
        'required': ['query'],
      },
    },
  ];

  static final _googleSearchToolsLlm = <LlmTool>[
    LlmTool(
      name: 'google_search',
      description: 'Search Google and return top results with title, URL, and snippet.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query to send to Google.',
          },
        },
        'required': ['query'],
      },
    ),
  ];

  static final _reminderToolsLlm = <LlmTool>[
    LlmTool(
      name: 'create_reminder',
      description:
          'Create a timed reminder for the manager. The reminder fires at '
          'the specified time. Offer to also add it to Google Calendar.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Short title for the reminder.',
          },
          'remind_at': {
            'type': 'string',
            'description':
                'ISO 8601 datetime when the reminder should fire '
                '(e.g. "2026-04-17T15:00:00").',
          },
          'description': {
            'type': 'string',
            'description': 'Optional longer description.',
          },
          'add_to_google_calendar': {
            'type': 'boolean',
            'description':
                'If true, also create a Google Calendar event for this reminder.',
          },
        },
        'required': ['title', 'remind_at'],
      },
    ),
    LlmTool(
      name: 'get_call_summary',
      description:
          'Get a summary of recent call activity. Use when the manager '
          'asks about calls since they were away or wants a status update.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'since_minutes_ago': {
            'type': 'integer',
            'description':
                'Only include calls from the last N minutes. '
                'Omit to use time since last briefing.',
          },
        },
      },
    ),
    LlmTool(
      name: 'play_call_recording',
      description:
          'Play back a call recording inline in the chat for the manager.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'call_record_id': {
            'type': 'integer',
            'description':
                'The ID of the call record whose recording to play.',
          },
        },
        'required': ['call_record_id'],
      },
    ),
    LlmTool(
      name: 'list_reminders',
      description:
          'List all scheduled reminders. Use when the manager asks about '
          'upcoming reminders, what is scheduled, or "do I have any reminders?".',
      inputSchema: {
        'type': 'object',
        'properties': {
          'include_fired': {
            'type': 'boolean',
            'description':
                'If true, include already-fired and dismissed reminders. '
                'Defaults to false (only pending).',
          },
        },
      },
    ),
  ];

  /// Push integration-specific tools and instructions to both pipelines.
  void _applyIntegrationTools() {
    final oaiExtra = <Map<String, dynamic>>[];
    final llmExtra = <LlmTool>[..._reminderToolsLlm];

    if (_flightAwareEnabled) {
      oaiExtra.addAll(_flightToolsOpenAi);
      llmExtra.addAll(_flightToolsLlm);
    }
    if (_gmailEnabled) {
      oaiExtra.addAll(_gmailToolsOpenAi);
      llmExtra.addAll(_gmailToolsLlm);
    }
    if (_googleCalendarEnabled) {
      oaiExtra.addAll(_googleCalendarToolsOpenAi);
      llmExtra.addAll(_googleCalendarToolsLlm);
    }
    if (_googleSearchEnabled) {
      oaiExtra.addAll(_googleSearchToolsOpenAi);
      llmExtra.addAll(_googleSearchToolsLlm);
    }

    _whisper.setExtraTools(oaiExtra);
    _textAgent?.setExtraTools(llmExtra);
    debugPrint('[AgentService] Integration tools applied: '
        '${oaiExtra.length} OAI extra, ${llmExtra.length} LLM extra '
        '(names: ${llmExtra.map((t) => t.name).join(', ')})');
  }

  // ---------------------------------------------------------------------------

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

  /// Common Whisper hallucination patterns on noise/silence — these are
  /// not real speech and must never trigger barge-in or be processed.
  static final RegExp _whisperHallucinationRe = RegExp(
    r'^(vous dites\s?\??|ja,?\s*ja\.?|hallo\??|so\.|'
    r'ok[,.]?\s*ok\.?|'
    r'sous-titrage\b|sous-titres?\b|'
    r'merci\.?|untertitelung\b|'
    r'amara\.org|'
    r'ご視聴ありがとうございました|'
    r'\.\.\.$|'
    r'[\.\,\!\?]+$)$',
    caseSensitive: false,
  );

  /// CJK / non-Latin script detection — Whisper hallucinates in random
  /// languages when it hears noise on an English-language call.
  static final RegExp _nonLatinRe = RegExp(
    r'[\u3000-\u9FFF\uAC00-\uD7AF\u0400-\u04FF\u0600-\u06FF\u0E00-\u0E7F]',
  );

  /// Bracketed Whisper tags for non-speech segments (but not ♪ lyrics ♪).
  static final RegExp _whisperBracketedTagRe = RegExp(
    r'^\[(BLANK_AUDIO|BLANK audio|blank_audio|Music|Silence|Applause|Laughter|'
    r'NOISE|noise|CLICK|click|clicking|typing|COUGH|cough|Sighs?|sighs?|'
    r'breathing|BREATHING|sneezing|clearing throat)\]$',
    caseSensitive: false,
  );

  /// Returns true if the transcript looks like a Whisper hallucination
  /// rather than genuine speech — common with ambient noise or silence.
  static bool _isWhisperHallucination(String text) {
    if (text.length <= 2) return true;
    if (_whisperBracketedTagRe.hasMatch(text)) return true;
    if (_whisperHallucinationRe.hasMatch(text)) return true;
    if (_nonLatinRe.hasMatch(text)) return true;
    return false;
  }

  /// Returns true if [text] is a fuzzy substring of any recent agent response,
  /// indicating it is likely the agent's own TTS being transcribed back.
  bool _isEchoOfAgentResponse(String text) {
    if (_recentAgentTexts.isEmpty) return false;
    final lower = text.toLowerCase().trim();
    if (lower.length < 4) return false;
    for (final agentText in _recentAgentTexts) {
      final agentLower = agentText.toLowerCase();
      if (agentLower.contains(lower)) return true;
      // Word-overlap check — only for transcripts with 3+ significant words
      // so short commands like "Call Lee" aren't blocked by common words.
      final tWords =
          lower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      if (tWords.length < 3) continue;
      final aWords =
          agentLower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      if (aWords.isNotEmpty) {
        final overlap = tWords.intersection(aWords).length;
        if (overlap / tWords.length >= 0.4) return true;
      }
    }
    return false;
  }

  /// Returns true if [text] is a near-duplicate of a recent agent message
  /// in the UI, preventing the same greeting from appearing twice.
  bool _isDuplicateAgentMessage(String text) {
    final lower = text.toLowerCase();
    final words = lower.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
    if (words.length < 4) return false;
    final now = DateTime.now();
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.role != ChatRole.agent) continue;
      if (now.difference(m.timestamp).inSeconds > 15) break;
      if (m.isStreaming) continue;
      final mWords =
          m.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
      if (mWords.isEmpty) continue;
      final overlap = words.intersection(mWords).length;
      final ratio = overlap / words.length;
      if (ratio >= 0.5) return true;
    }
    return false;
  }

  /// TTS generation finished — all audio chunks have been emitted to native.
  /// Transition UI to "Listening" quickly, but keep isTtsPlaying gated until
  /// native confirms playback is done (onPlaybackComplete).  This gives a
  /// responsive UI without letting Whisper hear the still-playing TTS audio.
  void _onTtsGenerationDone() {
    _ttsGenEndTimer?.cancel();
    _ttsGenEndTimer = Timer(const Duration(milliseconds: 200), () {
      if (_speaking) {
        _speaking = false;
        _speakingEndTime = DateTime.now();
        _statusText = _muted ? 'Not Listening...' : 'Listening';
        notifyListeners();
        _schedulePostSpeakFlush();
      }
      debugPrint('[AgentService] Gen-done UI transition (isTtsPlaying still gated)');

      // Safety: if native never sends onPlaybackComplete (e.g. no audio was
      // queued, or direct-mode with no tap channel), force-clear after a
      // generous timeout. The native ring-buffer-aware polling timer should
      // fire first for normal operation — this is a last resort. Ring buffers
      // hold up to 30s of audio, so 45s covers worst case.
      _playbackSafetyTimer?.cancel();
      _playbackSafetyTimer = Timer(const Duration(seconds: 45), () {
        if (_whisper.isTtsPlaying) {
          _whisper.isTtsPlaying = false;
          debugPrint('[AgentService] Safety timeout: forced isTtsPlaying=false');
        }
      });
    });
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
    final msSince = DateTime.now().difference(_speakingEndTime).inMilliseconds;
    if (msSince < _echoGuardMs) {
      _schedulePostSpeakFlush();
      return;
    }

    final batch = List<TranscriptionEvent>.from(_pendingTranscripts);
    _pendingTranscripts.clear();

    for (final event in batch) {
      final text = event.text.trim();
      if (text.isEmpty) continue;
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      if (words.length < 2) {
        debugPrint('[AgentService] Buffered single-word dropped: "$text"');
        continue;
      }
      if (_isEchoOfAgentResponse(text)) {
        debugPrint('[AgentService] Buffered echo discarded: "$text"');
        continue;
      }
      _processTranscript(event);
    }
  }

  /// Handle VAD speech-start/stop events for fast barge-in detection.
  /// When the remote party starts speaking while the agent is playing audio,
  /// we immediately stop the agent without waiting for a full transcript.
  /// A 900ms debounce avoids false triggers from echo/noise picked up by the
  /// server VAD, and the VAD must still be active when the timer fires
  /// (speech_stopped cancels it).
  void _onVadEvent(bool speechStarted) {
    if (!speechStarted) {
      _vadInterruptDebounce?.cancel();
      _vadInterruptDebounce = null;
      return;
    }

    // Only trigger during active agent audio playback.
    if (!_speaking && !_whisper.isTtsPlaying) return;

    // Don't re-trigger if we already interrupted.
    if (_ttsInterrupted) return;

    // Skip during settling — VAD activity is normal there.
    if (_callPhase == CallPhase.settling) return;

    _vadInterruptDebounce?.cancel();
    _vadInterruptDebounce = Timer(const Duration(milliseconds: 900), () {
      // Re-check conditions after debounce.
      if (!_speaking && !_whisper.isTtsPlaying) return;
      if (_ttsInterrupted) return;
      _vadInterruptStop();
    });
  }

  /// Fast barge-in: stop the agent immediately without a transcript.
  /// The transcript will arrive later and be processed normally.
  void _vadInterruptStop() {
    debugPrint('[AgentService] VAD barge-in: stopping agent audio');

    _ttsInterrupted = true;
    _textAgent?.cancelCurrentResponse();
    _activeTtsEndGeneration();

    _whisper.stopResponseAudio();
    _whisper.clearTTSQueue();
    _whisper.isTtsPlaying = false;

    _ttsGenEndTimer?.cancel();
    _playbackEndDebounce?.cancel();
    _playbackSafetyTimer?.cancel();
    _postSpeakFlushTimer?.cancel();
    _vadInterruptDebounce?.cancel();

    _speaking = false;
    _speakingEndTime = DateTime.now();
    _statusText = _muted ? 'Not Listening...' : 'Listening';

    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        if (_voiceHoldUntilFirstPcm && _voiceUiBuffer != null) {
          _messages[idx].text = _voiceUiBuffer.toString();
        }
        _messages[idx].isStreaming = false;
      }
      _resetVoiceUiSyncState();
      _streamingMessageId = null;
    }

    // The transcript for the interrupting speech hasn't arrived yet — it will
    // come through _onTranscript after Whisper finishes processing. Schedule
    // a post-speak flush so any transcript buffered during the echo guard
    // gets processed.
    _schedulePostSpeakFlush();
    notifyListeners();
  }

  /// Barge-in: stop the agent mid-speech and respond to the interrupting
  /// transcript. Cancels the in-flight LLM response, ends TTS generation,
  /// clears queued audio, finalizes the interrupted UI message, flushes any
  /// buffered transcripts, and processes the interrupting event.
  void _interruptAgent(TranscriptionEvent event) {
    debugPrint('[AgentService] Barge-in interrupt: "${event.text.trim()}"');

    // 0. Gate the audio listener so in-flight TTS chunks are dropped.
    _ttsInterrupted = true;

    // 1. Cancel in-flight LLM response (emits partial final event).
    _textAgent?.cancelCurrentResponse();

    // 2. Stop TTS generation — no more text→audio conversion.
    _activeTtsEndGeneration();

    // 3. Stop native audio playback and clear call-mode TTS ring buffers.
    _whisper.stopResponseAudio();
    _whisper.clearTTSQueue();
    _whisper.isTtsPlaying = false;

    // 4. Cancel all post-speak / playback timers.
    _ttsGenEndTimer?.cancel();
    _playbackEndDebounce?.cancel();
    _playbackSafetyTimer?.cancel();
    _postSpeakFlushTimer?.cancel();
    _vadInterruptDebounce?.cancel();

    // 5. Transition from speaking → listening immediately.
    _speaking = false;
    _speakingEndTime = DateTime.now();
    _statusText = _muted ? 'Not Listening...' : 'Listening';

    // 6. Finalize the interrupted UI message.
    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        if (_voiceHoldUntilFirstPcm && _voiceUiBuffer != null) {
          _messages[idx].text = _voiceUiBuffer.toString();
        }
        _messages[idx].isStreaming = false;
      }
      _resetVoiceUiSyncState();
      _streamingMessageId = null;
    }

    // 7. Flush any previously buffered transcripts (skip echo guard).
    if (_pendingTranscripts.isNotEmpty) {
      final batch = List<TranscriptionEvent>.from(_pendingTranscripts);
      _pendingTranscripts.clear();
      for (final buffered in batch) {
        final text = buffered.text.trim();
        if (text.isEmpty) continue;
        if (_isEchoOfAgentResponse(text)) continue;
        _processTranscript(buffered);
      }
    }

    // 8. Process the interrupting transcript.
    _processTranscript(event);
    notifyListeners();
  }

  void _onTranscript(TranscriptionEvent event) async {
    if (!event.isFinal || event.text.trim().isEmpty) return;
    if (_muted) return;

    // Drop common Whisper hallucination artifacts before any further processing.
    if (_isWhisperHallucination(event.text.trim())) {
      debugPrint(
          '[AgentService] Whisper hallucination dropped: "${event.text.trim()}"');
      return;
    }

    // Suppress transcripts while call is still setting up — but in split
    // pipeline mode or local STT mode, allow transcripts when idle so the
    // user can talk to the agent without an active call.
    if (_callPhase.isPreConnect) {
      if (!((_splitPipeline || _isLocalSttMode) && _callPhase == CallPhase.idle)) return;
    }

    // During settling, classify each transcript to decide whether this is a
    // human answering or an automated IVR/voicemail greeting. Buffer all
    // transcripts — they are forwarded after promotion to connected.
    if (_callPhase.isSettling) {
      final String text = event.text.trim();
      _settleTranscripts.add(event);
      _settleAccumulatedTexts.add(text);
      _settleWordCount += text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).length;

      final IvrConfidence c = IvrDetector.confidence(text);
      debugPrint(
          '[AgentService] Settle transcript: "$text" → $c');

      // IVR / voicemail detection only applies to outbound calls.
      // Inbound callers are real humans — skip the classification entirely.
      if (_isOutbound) {
        if (c.mailboxFull) {
          debugPrint(
              '[AgentService] Mailbox full detected — notifying host');
          _ivrHeard = true;
          _ivrHitsInSettle++;
          _handleMailboxFull(text);
          return;
        }

        if (c.type == CallPartyType.ivr) {
          _ivrHitsInSettle++;
          _ivrHeard = true;
          _extendSettleTimer();
          if (c.ivrEnding) {
            debugPrint(
                '[AgentService] IVR ending phrase detected — entering beep watch');
            _enterBeepWatchMode();
          }
          return;
        }
      }

      if (c.type == CallPartyType.human && c.score >= 0.7) {
        if (_ivrHitsInSettle == 0) {
          debugPrint(
              '[AgentService] Human speech during settle: "$text" — promoting');
          _promoteToConnected();
          return;
        }
        // IVR was heard before but now human-sounding text — could be the
        // tail of a voicemail greeting. Check accumulated context.
        final IvrConfidence acc =
            IvrDetector.accumulatedConfidence(_settleAccumulatedTexts);
        if (acc.type == CallPartyType.human) {
          debugPrint(
              '[AgentService] Accumulated context is human — promoting');
          _promoteToConnected();
          return;
        }
      }

      // Ambiguous — let more text arrive. If the initial settle timer hasn't
      // been extended by IVR, it will fire naturally and promote.
      return;
    }

    // While the agent is speaking OR TTS audio is still draining through
    // native ring buffers, check whether this transcript is TTS echo or
    // genuine remote speech. The _speaking flag clears on gen-done (~200ms
    // after TTS generation ends), but ring buffers may still have seconds of
    // queued audio playing through the speakers.
    if (_speaking || _whisper.isTtsPlaying) {
      final text = event.text.trim();
      if (_isEchoOfAgentResponse(text)) {
        debugPrint('[AgentService] Echo during speak: "$text"');
        return;
      }
      // During the pre-greeting grace window, add as context only.
      if (_preGreetGraceUntil != null &&
          DateTime.now().isBefore(_preGreetGraceUntil!)) {
        _preGreetGraceUntil = null;
        _textAgent?.addSystemContext('[Remote]: $text');
        debugPrint(
            '[AgentService] Pre-greet grace (during speak): "$text" as context');
        return;
      }
      // Require a minimum word count to trigger barge-in — very short
      // fragments are almost always echo residue or noise artifacts that
      // slip past _isEchoOfAgentResponse (which skips texts <8 chars).
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      if (words.length < 3) {
        debugPrint(
            '[AgentService] Short fragment during speak ignored: "$text"');
        _pendingTranscripts.add(event);
        return;
      }
      _interruptAgent(event);
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

    // Real human speech — cancel any pending connected greeting so the
    // agent doesn't talk over whoever is already speaking.
    _cancelConnectedGreeting();

    // If there are buffered settle-phase transcripts, forward them first
    // so the LLM has the full context of what was said before connected.
    _drainSettleTranscripts();

    // Text-based echo suppression — only within a short window after the
    // agent finishes speaking.  Outside this window the check is skipped so
    // legitimate user commands that share common words with prior agent
    // responses (e.g. "Call Lee" vs "would you like me to call Kali") are
    // not incorrectly suppressed.
    final msSinceSpoke =
        DateTime.now().difference(_speakingEndTime).inMilliseconds;
    if (msSinceSpoke < _echoGuardMs * 2 && _isEchoOfAgentResponse(text)) {
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
        debugPrint(
            '[AgentService] Ambient audio dropped (confidence=$confidence): "$text"');
        return;
      }
    }

    final lowConfidence = confidence > 0.0 && confidence < 0.5;

    // If voiceprint identified a name with reasonable confidence and the
    // speaker doesn't have one yet, update the label.  A threshold of 0.65
    // avoids false positives from ambient audio or dissimilar voices.
    //
    // For the remote speaker on outbound calls, only apply voiceprint naming
    // when the dialed number already resolved to a contact (i.e. the contact
    // lookup set the name first).  Otherwise a false-positive voice match
    // labels a stranger (e.g. a call-center agent) with a known contact's
    // name — exactly the "Stan Cell ≠ Delta Airlines" bug.
    final skipVoiceprint = isRemote &&
        _isOutbound &&
        speaker.name.isEmpty &&
        _remoteIdentity != null &&
        contactService?.lookupByPhone(_remoteIdentity!) == null;

    if (voiceprintName.isNotEmpty && speaker.name.isEmpty && !skipVoiceprint) {
      if (confidence >= 0.65) {
        speaker.name = voiceprintName;
        _pushInstructionsIfLive();
        debugPrint(
            '[AgentService] Voiceprint accepted: "$voiceprintName" (confidence=$confidence)');
      } else {
        debugPrint(
            '[AgentService] Voiceprint rejected: "$voiceprintName" (confidence=$confidence < 0.65)');
      }
    } else if (skipVoiceprint && voiceprintName.isNotEmpty) {
      debugPrint(
          '[AgentService] Voiceprint skipped for remote on outbound call to unrecognized number: '
          '"$voiceprintName" (confidence=$confidence)');
    }

    _addOrMergeTranscript(role, text, speakerName: speaker.label);

    callHistory?.addTranscript(
      role: isRemote ? 'remote' : 'host',
      speakerName: speaker.label,
      text: text,
    );

    // Tag low-confidence transcripts so the agent can judge whether to respond
    final label =
        lowConfidence ? '${speaker.label} (low confidence)' : speaker.label;

    // Post-pre-greeting grace: the first transcript(s) after the pre-greeting
    // flush (typically the remote party's "Hello?") are added as context only
    // so the LLM doesn't generate a duplicate greeting.
    if (_preGreetGraceUntil != null &&
        DateTime.now().isBefore(_preGreetGraceUntil!)) {
      _preGreetGraceUntil = null;
      _textAgent?.addSystemContext('[$label]: $text');
      debugPrint(
          '[AgentService] Post-pre-greet grace: added "$text" as context only');
      return;
    }

    // Post-connected-greeting grace: short acknowledgments from the remote
    // party (e.g. "Hello?", "Hi", "Hey there") right after the agent's
    // greeting are added as context so the LLM doesn't re-greet.
    if (_postGreetGraceUntil != null &&
        DateTime.now().isBefore(_postGreetGraceUntil!)) {
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      if (isRemote && words.length < 4) {
        _textAgent?.addSystemContext('[$label]: $text');
        debugPrint(
            '[AgentService] Post-greet grace: added "$text" as context only');
        return;
      }
      // Substantial speech clears the grace window.
      _postGreetGraceUntil = null;
    }

    _textAgent?.addTranscript(label, text);
  }

  void _onResponseText(ResponseTextEvent event) {
    if (_splitPipeline) return;
    _appendStreamingResponse(event);
  }

  static final _hallucinatedCallStateRe =
      RegExp(r'\[CALL_STATE:\s*[^\]]*\]', caseSensitive: false);

  /// Shared handler for streaming agent responses from either OpenAI
  /// Realtime or the external text agent (Claude, etc.).
  void _appendStreamingResponse(ResponseTextEvent event) {
    if (_callPhase == CallPhase.ended || _callPhase == CallPhase.failed) return;

    // The LLM must never generate [CALL_STATE: ...] tags — those are
    // system-only. Strip them to prevent hallucinated state changes from
    // poisoning the conversation history.
    if (event.isFinal && _hallucinatedCallStateRe.hasMatch(event.text)) {
      final cleaned = event.text.replaceAll(_hallucinatedCallStateRe, '').trim();
      debugPrint('[AgentService] Stripped hallucinated CALL_STATE from LLM output');
      if (cleaned.isEmpty) {
        debugPrint('[AgentService] Entire response was hallucinated CALL_STATE — discarding');
        return;
      }
      _appendStreamingResponse(ResponseTextEvent(text: cleaned, isFinal: true));
      return;
    }

    // Pre-greeting: buffer the response during settling instead of the
    // normal display/TTS path. Flushed on promotion to connected.
    if (_preGreetInFlight) {
      if (event.isFinal) {
        _preGreetFinalText = event.text.isNotEmpty
            ? event.text
            : _preGreetTextBuffer?.toString();

        // LLM error — discard and fall back to the normal greeting path.
        if (_preGreetFinalText != null &&
            _preGreetFinalText!.startsWith('Error:')) {
          _pipelineError = _formatPipelineError(_preGreetFinalText!);
          debugPrint('[AgentService] Pre-greeting error — discarding');
          _discardPreGreeting();
          if (_callPhase == CallPhase.connected) {
            _connectedGreetTimer?.cancel();
            _connectedGreetTimer = Timer(
              const Duration(milliseconds: _connectedGreetDelayMs),
              () => _tryFireConnectedGreeting(),
            );
          }
          return;
        }

        _preGreetReady = true;
        _preGreetInFlight = false;
        final preview = _preGreetFinalText ?? '';
        debugPrint('[AgentService] Pre-greeting ready: '
            '${preview.length > 60 ? preview.substring(0, 60) : preview}...');
        if (_callPhase == CallPhase.connected) {
          _flushPreGreeting();
        }
      } else {
        _preGreetTextBuffer ??= StringBuffer();
        _preGreetTextBuffer!.write(event.text);
      }
      return;
    }

    if (event.isFinal) {
      debugPrint('[AgentService] Response final: '
          '${event.text.length > 80 ? event.text.substring(0, 80) : event.text}...');

      if (event.text.startsWith('Error:')) {
        _pipelineError = _formatPipelineError(event.text);
      } else if (_pipelineError != null) {
        _pipelineError = null;
      }
    }

    if (event.isFinal) {
      if (!_ttsMuted && !_muted) _activeTtsEndGeneration();
      _vocalExprState = StreamingExpressionState();

      if (_streamingMessageId != null) {
        final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
        if (idx >= 0) {
          // Determine the canonical final text (expression tags stripped).
          final rawFinal = event.text.isNotEmpty
              ? event.text
              : (_voiceUiBuffer != null && _voiceUiBuffer!.isNotEmpty
                  ? _voiceUiBuffer.toString()
                  : _messages[idx].text);
          final finalText = event.text.isNotEmpty
              ? VocalExpressionRegistry.stripForDisplay(rawFinal)
              : rawFinal;

          if (_isDuplicateAgentMessage(finalText)) {
            debugPrint('[AgentService] Streaming duplicate suppressed');
            _ttsInterrupted = true;
            _whisper.stopResponseAudio();
            _whisper.clearTTSQueue();
            _messages.removeAt(idx);
            _streamingMessageId = null;
            _resetVoiceUiSyncState();
            notifyListeners();
            return;
          }

          _recentAgentTexts.add(finalText);
          while (_recentAgentTexts.length > _maxRecentAgentTexts) {
            _recentAgentTexts.removeAt(0);
          }
          callHistory?.addTranscript(role: 'agent', text: finalText);

          if (_voiceHoldUntilFirstPcm) {
            // PCM hasn't arrived yet — keep the hold so text stays hidden
            // until audio actually starts. Store full text for release.
            _voiceUiBuffer = StringBuffer(finalText);
            _voiceFinalPending = true;
            // Safety: force-release after 8s in case TTS never produces audio.
            _voiceFinalTimer?.cancel();
            _voiceFinalTimer = Timer(const Duration(seconds: 8), () {
              if (!_voiceHoldUntilFirstPcm) return;
              debugPrint('[AgentService] Voice-hold safety timeout — '
                  'releasing text without PCM');
              _forceReleaseVoiceHold();
            });
          } else {
            // PCM already arrived — finalize immediately.
            _messages[idx].text = finalText;
            _voiceUiBuffer = null;
            _messages[idx].isStreaming = false;
            _streamingMessageId = null;
          }
        } else {
          _streamingMessageId = null;
        }
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

    /// Only defer when this pipeline drives speech via Kokoro/ElevenLabs
    /// (`_ttsAudioSub`). Unified OpenAI audio does not use that stream.
    /// In local STT mode the hold-until-PCM mechanism is wrong: it's a chat
    /// assistant, not a phone call, so text must appear immediately regardless
    /// of whether TTS audio has started playing.
    final ttsActive = !_ttsMuted && !_muted;
    final deferAgentTextForTts =
        _splitPipeline && !_isLocalSttMode && _hasTts && ttsActive && !suppressTts;

    // Process vocal expressions and pipe text to TTS (ElevenLabs or Kokoro),
    // stripping bracketed stage directions. Skip when muted to avoid burning
    // TTS credits/compute.
    if (_streamingMessageId == null) {
      _vocalExprState = StreamingExpressionState();
    }
    final exprResult = VocalExpressionRegistry.processDelta(
      event.text, _vocalExprState);
    _vocalExprState = exprResult.state;

    if (_hasTts && ttsActive && event.text.isNotEmpty && !suppressTts) {
      if (_streamingMessageId == null) {
        _ttsBracketDepth = 0;
        _activeTtsStartGeneration();
      }
      final ttsText = _flattenMarkdownForTtsDelta(
        _stripBracketsForTts(exprResult.ttsText),
      );
      if (ttsText.trim().isNotEmpty) {
        _activeTtsSendText(ttsText);
      }
    }

    // Use display text (expression tags stripped) for the chat UI.
    final displayDelta = exprResult.displayText;

    if (_streamingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _streamingMessageId);
      if (idx >= 0) {
        if (deferAgentTextForTts && _voiceHoldUntilFirstPcm) {
          _voiceUiBuffer ??= StringBuffer();
          _voiceUiBuffer!.write(displayDelta);
        } else {
          _messages[idx].text += displayDelta;
        }
        notifyListeners();
        return;
      }
    }

    final initialText = deferAgentTextForTts ? '' : displayDelta;
    final msg = ChatMessage.agent(initialText, isStreaming: true);
    _streamingMessageId = msg.id;
    if (deferAgentTextForTts) {
      _voiceHoldUntilFirstPcm = true;
      _voiceUiBuffer = StringBuffer(displayDelta);
    } else {
      _resetVoiceUiSyncState();
    }
    _messages.add(msg);
    notifyListeners();
  }

  /// Per-delta cleanup so markdown does not get spoken (e.g. `**`, headings).
  /// Paragraph breaks become `. ` so the segmenter treats them as sentence
  /// boundaries, keeping first-segment size small for faster time-to-audio.
  static String _flattenMarkdownForTtsDelta(String s) {
    if (s.isEmpty) return s;
    var t = s.replaceAll('**', ' ');
    t = t.replaceAll('__', ' ');
    t = t.replaceAll('`', '');
    t = t.replaceAllMapped(RegExp(r'^#{1,6}\s+', multiLine: true), (_) => '');
    // Paragraph breaks → sentence boundary so TTS flushes sooner.
    t = t.replaceAllMapped(RegExp(r'([.!?…])\s*\n{2,}'), (m) => '${m[1]} ');
    t = t.replaceAll(RegExp(r'\n{2,}'), '. ');
    t = t.replaceAll('\n', ' ');
    return t;
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
        case 'check_locale':
          result = _handleCheckLocale();
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
        case 'save_contact':
          result = await _handleSaveContact(args);
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
        case 'list_voices':
          result = await _handleListVoices();
          break;
        case 'lookup_flight':
          result = await _handleLookupFlight(args);
          break;
        case 'search_flights_by_route':
          result = await _handleSearchFlightsByRoute(args);
          break;
        case 'send_gmail':
          result = await _handleSendGmail(args);
          break;
        case 'search_gmail':
          result = await _handleSearchGmail(args);
          break;
        case 'read_gmail':
          result = await _handleReadGmail(args);
          break;
        case 'list_google_calendars':
          result = await _handleListGoogleCalendars(args);
          break;
        case 'create_google_calendar_event':
          result = await _handleCreateGoogleCalendarEvent(args);
          break;
        case 'create_new_google_calendar':
          result = await _handleCreateNewGoogleCalendar(args);
          break;
        case 'read_google_calendar':
          result = await _handleReadGoogleCalendar(args);
          break;
        case 'sync_google_calendar':
          result = await _handleSyncGoogleCalendar(args);
          break;
        case 'google_search':
          result = await _handleGoogleSearch(args);
          break;
        case 'transfer_call':
          result = _handleTransferCall(args);
          break;
        case 'hold_call':
          result = _handleHoldCall(args);
          break;
        case 'mute_call':
          result = _handleMuteCall(args);
          break;
        case 'add_conference_participant':
          result = await _handleAddConferenceParticipant(args);
          break;
        case 'merge_conference':
          result = await _handleMergeConference(args);
          break;
        case 'create_reminder':
          result = await _handleCreateReminder(args);
          break;
        case 'get_call_summary':
          result = await _handleGetCallSummary(args);
          break;
        case 'play_call_recording':
          result = await _handlePlayCallRecording(args);
          break;
        case 'list_reminders':
          result = await _handleListReminders(args);
          break;
        case 'create_transfer_rule':
          result = await _handleCreateTransferRule(args);
          break;
        case 'update_transfer_rule':
          result = await _handleUpdateTransferRule(args);
          break;
        case 'delete_transfer_rule':
          result = await _handleDeleteTransferRule(args);
          break;
        case 'list_transfer_rules':
          result = await _handleListTransferRules();
          break;
        case 'request_transfer_approval':
          result = await _handleRequestTransferApproval(args);
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
        case 'check_locale':
          result = _handleCheckLocale();
          break;
        case 'end_call':
          result = await _handleEndCall();
          break;
        case 'search_contacts':
          result = await _handleSearchContacts(req.arguments);
          break;
        case 'save_contact':
          result = await _handleSaveContact(req.arguments);
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
        case 'list_voices':
          result = await _handleListVoices();
          break;
        case 'lookup_flight':
          result = await _handleLookupFlight(req.arguments);
          break;
        case 'search_flights_by_route':
          result = await _handleSearchFlightsByRoute(req.arguments);
          break;
        case 'send_gmail':
          result = await _handleSendGmail(req.arguments);
          break;
        case 'search_gmail':
          result = await _handleSearchGmail(req.arguments);
          break;
        case 'read_gmail':
          result = await _handleReadGmail(req.arguments);
          break;
        case 'list_google_calendars':
          result = await _handleListGoogleCalendars(req.arguments);
          break;
        case 'create_google_calendar_event':
          result = await _handleCreateGoogleCalendarEvent(req.arguments);
          break;
        case 'create_new_google_calendar':
          result = await _handleCreateNewGoogleCalendar(req.arguments);
          break;
        case 'read_google_calendar':
          result = await _handleReadGoogleCalendar(req.arguments);
          break;
        case 'sync_google_calendar':
          result = await _handleSyncGoogleCalendar(req.arguments);
          break;
        case 'google_search':
          result = await _handleGoogleSearch(req.arguments);
          break;
        case 'transfer_call':
          result = _handleTransferCall(req.arguments);
          break;
        case 'hold_call':
          result = _handleHoldCall(req.arguments);
          break;
        case 'mute_call':
          result = _handleMuteCall(req.arguments);
          break;
        case 'add_conference_participant':
          result = await _handleAddConferenceParticipant(req.arguments);
          break;
        case 'merge_conference':
          result = await _handleMergeConference(req.arguments);
          break;
        case 'create_reminder':
          result = await _handleCreateReminder(req.arguments);
          break;
        case 'get_call_summary':
          result = await _handleGetCallSummary(req.arguments);
          break;
        case 'play_call_recording':
          result = await _handlePlayCallRecording(req.arguments);
          break;
        case 'list_reminders':
          result = await _handleListReminders(req.arguments);
          break;
        case 'create_transfer_rule':
          result = await _handleCreateTransferRule(req.arguments);
          break;
        case 'update_transfer_rule':
          result = await _handleUpdateTransferRule(req.arguments);
          break;
        case 'delete_transfer_rule':
          result = await _handleDeleteTransferRule(req.arguments);
          break;
        case 'list_transfer_rules':
          result = await _handleListTransferRules();
          break;
        case 'request_transfer_approval':
          result = await _handleRequestTransferApproval(req.arguments);
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
  // Inbound SMS → agent context
  // ---------------------------------------------------------------------------

  /// Phone numbers for which we've already injected conversation history into
  /// the current agent session, so we don't re-send 20 messages on every text.
  final Set<String> _smsHistoryLoadedPhones = {};

  Future<void> _onInboundSms(SmsMessage msg) async {
    if (!_active) return;

    String senderLabel = msg.from;
    if (contactService != null) {
      final contact = contactService!.lookupByPhone(msg.from);
      if (contact != null) {
        final name = contact['display_name'] as String?;
        if (name != null && name.isNotEmpty) {
          senderLabel = '$name (${msg.from})';
        }
      }
    }

    final preview = msg.text.length > 500
        ? '${msg.text.substring(0, 500)}…'
        : msg.text;

    debugPrint('[AgentService] Inbound SMS from $senderLabel: ${preview.length > 80 ? '${preview.substring(0, 80)}...' : preview}');

    String? contactName;
    if (contactService != null) {
      final contact = contactService!.lookupByPhone(msg.from);
      if (contact != null) {
        contactName = contact['display_name'] as String?;
      }
    }
    _messages.add(ChatMessage.sms(
      'Inbound SMS from $senderLabel: "$preview"',
      direction: 'inbound',
      remotePhone: msg.from,
      contactName: contactName,
    ));
    notifyListeners();

    // Build the context payload. On the first message from this number in the
    // current session, prepend the last 20 messages so the agent has the full
    // thread context.
    final buf = StringBuffer();
    final normalizedPhone = ensureE164(msg.from);
    if (!_smsHistoryLoadedPhones.contains(normalizedPhone)) {
      _smsHistoryLoadedPhones.add(normalizedPhone);
      try {
        final rows = await CallHistoryDb.getSmsMessagesForConversation(
          normalizedPhone,
          limit: 20,
        );
        if (rows.length > 1) {
          final history = rows
              .map((r) => SmsMessage.fromDbMap(r))
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          // Exclude the just-received message (last inbound) from the history
          // block since it's included in the main event line below.
          final prior = history.where((m) =>
              !(m.direction == SmsDirection.inbound &&
                  m.text == msg.text &&
                  m == history.last)).toList();
          if (prior.isNotEmpty) {
            buf.writeln(
                'SYSTEM CONTEXT — Recent SMS conversation history with '
                '$senderLabel (most recent last):');
            for (final m in prior) {
              final dir = m.direction == SmsDirection.inbound
                  ? senderLabel
                  : 'Manager (you)';
              final ts = '${m.createdAt.month}/${m.createdAt.day} '
                  '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}';
              final body = m.text.length > 300
                  ? '${m.text.substring(0, 300)}…'
                  : m.text;
              buf.writeln('  [$ts] $dir: "$body"');
            }
            buf.writeln('--- End of conversation history ---\n');
          }
        }
      } catch (e) {
        debugPrint('[AgentService] Failed to load SMS history for '
            '$normalizedPhone: $e');
      }
    }

    buf.write(
        'SYSTEM EVENT — New inbound SMS received on the manager\'s phone '
        'from $senderLabel: "$preview" — This text was sent to the manager. '
        'Use send_sms to reply to ${msg.from} on the manager\'s behalf if '
        'appropriate.');

    final contextLine = buf.toString();

    if (_textAgent != null) {
      _textAgent!.sendUserMessage(contextLine);
    } else if (_active) {
      _whisper.sendTextMessage(contextLine);
    }
  }

  // ---------------------------------------------------------------------------
  // SMS / Messaging tool handlers
  // ---------------------------------------------------------------------------

  /// Per-number send timestamps for rate limiting (prevents tool-call loops).
  final Map<String, List<DateTime>> _smsSendLog = {};
  static const _smsRateWindowSeconds = 60;
  static const _smsRateMaxPerWindow = 2;

  /// Dedup: last successfully sent message per number → (text, timestamp).
  final Map<String, ({String text, DateTime sentAt})> _smsLastSent = {};
  static const _smsDedupWindowSeconds = 30;

  /// Consecutive rate-limit hits per number. Reset on successful send or
  /// when a different number is targeted. Used to force-cancel the LLM
  /// response after repeated failed attempts.
  final Map<String, int> _smsConsecutiveRateLimits = {};
  static const _smsMaxConsecutiveRateLimits = 2;

  bool _isSmsRateLimited(String normalizedTo) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(seconds: _smsRateWindowSeconds));
    final log = _smsSendLog[normalizedTo];
    if (log == null) return false;
    log.removeWhere((t) => t.isBefore(cutoff));
    return log.length >= _smsRateMaxPerWindow;
  }

  bool _isSmsDuplicate(String normalizedTo, String text) {
    final last = _smsLastSent[normalizedTo];
    if (last == null) return false;
    final age = DateTime.now().difference(last.sentAt).inSeconds;
    return age < _smsDedupWindowSeconds && last.text == text;
  }

  void _recordSmsSend(String normalizedTo, String text) {
    _smsSendLog.putIfAbsent(normalizedTo, () => []).add(DateTime.now());
    _smsLastSent[normalizedTo] = (text: text, sentAt: DateTime.now());
    _smsConsecutiveRateLimits.remove(normalizedTo);
  }

  String _handleSmsRateLimit(String normalizedTo, String displayTo) {
    final count = (_smsConsecutiveRateLimits[normalizedTo] ?? 0) + 1;
    _smsConsecutiveRateLimits[normalizedTo] = count;
    debugPrint('[AgentService] SMS rate-limited to $normalizedTo '
        '(consecutive: $count)');
    if (count >= _smsMaxConsecutiveRateLimits) {
      _textAgent?.cancelCurrentResponse();
      debugPrint('[AgentService] Force-cancelled LLM response after '
          '$count consecutive SMS rate limits to $normalizedTo');
    }
    return 'Rate limited: you already sent $_smsRateMaxPerWindow messages to '
        'this number in the last $_smsRateWindowSeconds seconds. '
        'STOP sending and wait for their reply.';
  }

  Future<String> _handleSendSms(Map<String, dynamic> args) async {
    if (messagingService == null || !messagingService!.isConfigured) {
      return 'Messaging is not configured. Set up SMS (Telnyx or Twilio) in Settings.';
    }
    final to = args['to'] as String?;
    final text = args['text'] as String?;
    if (to == null || to.isEmpty || text == null || text.isEmpty) {
      return 'Both "to" and "text" are required.';
    }
    final normalizedTo = ensureE164(to);
    final displayTo = (demoModeService?.enabled ?? false)
        ? demoModeService!.maskPhone(to)
        : to;
    if (_isSmsRateLimited(normalizedTo)) {
      return _handleSmsRateLimit(normalizedTo, displayTo);
    }
    if (_isSmsDuplicate(normalizedTo, text)) {
      debugPrint('[AgentService] SMS dedup — suppressed duplicate to '
          '$normalizedTo: "$text"');
      return 'Message sent from the manager\'s phone to $displayTo. Do NOT '
          'send another message to this number — wait for their reply.';
    }
    final mediaUrl = args['media_url'] as String?;
    final mediaUrls =
        mediaUrl != null && mediaUrl.isNotEmpty ? [mediaUrl] : null;
    final msg = await messagingService!
        .sendMessage(to: to, text: text, mediaUrls: mediaUrls);
    if (msg != null) {
      _recordSmsSend(normalizedTo, text);
      String? contactName;
      if (contactService != null) {
        final contact = contactService!.lookupByPhone(to);
        if (contact != null) {
          contactName = contact['display_name'] as String?;
        }
      }
      _messages.add(ChatMessage.sms(
        'SMS sent to $displayTo: "$text"',
        direction: 'outbound',
        remotePhone: to,
        contactName: contactName,
      ));
      notifyListeners();
      return 'Message sent from the manager\'s phone to $displayTo. Do NOT '
          'send another message to this number — wait for their reply.';
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
    final displayTo = (demoModeService?.enabled ?? false)
        ? demoModeService!.maskPhone(selected)
        : selected;
    if (_isSmsRateLimited(selected)) {
      return _handleSmsRateLimit(selected, displayTo);
    }
    if (_isSmsDuplicate(selected, text)) {
      debugPrint('[AgentService] SMS reply dedup — suppressed duplicate to '
          '$selected: "$text"');
      return 'Reply sent from the manager\'s phone to $displayTo. Do NOT '
          'send another message — wait for their reply.';
    }
    final msg = await messagingService!.reply(text);
    if (msg != null) {
      _recordSmsSend(selected, text);
      String? contactName;
      if (contactService != null) {
        final contact = contactService!.lookupByPhone(selected);
        if (contact != null) {
          contactName = contact['display_name'] as String?;
        }
      }
      _messages.add(ChatMessage.sms(
        'SMS reply to $displayTo: "$text"',
        direction: 'outbound',
        remotePhone: selected,
        contactName: contactName,
      ));
      notifyListeners();
      return 'Reply sent from the manager\'s phone to $displayTo. Do NOT '
          'send another message — wait for their reply.';
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

  // ---------------------------------------------------------------------------
  // Reminder, Call Summary, and Recording Playback Handlers
  // ---------------------------------------------------------------------------

  Future<String> _handleCreateReminder(Map<String, dynamic> args) async {
    final title = args['title'] as String?;
    if (title == null || title.isEmpty) return 'Reminder title is required.';

    final remindAtRaw = args['remind_at'] as String?;
    if (remindAtRaw == null) return 'remind_at datetime is required.';

    DateTime remindAt;
    try {
      remindAt = DateTime.parse(remindAtRaw);
    } catch (_) {
      return 'Invalid remind_at format. Use ISO 8601 (e.g. 2026-04-17T15:00:00).';
    }

    final description = args['description'] as String?;
    final addToGcal = args['add_to_google_calendar'] as bool? ?? false;

    String? gcalEventId;
    if (addToGcal && googleCalendarService != null) {
      try {
        final gcalResult = await _handleCreateGoogleCalendarEvent({
          'title': title,
          'date':
              '${remindAt.year}-${remindAt.month.toString().padLeft(2, '0')}-${remindAt.day.toString().padLeft(2, '0')}',
          'start_time':
              '${remindAt.hour.toString().padLeft(2, '0')}:${remindAt.minute.toString().padLeft(2, '0')}',
          'end_time':
              '${remindAt.add(const Duration(minutes: 15)).hour.toString().padLeft(2, '0')}:${remindAt.add(const Duration(minutes: 15)).minute.toString().padLeft(2, '0')}',
          if (description != null) 'description': description,
        });
        debugPrint('[AgentService] GCal event for reminder: $gcalResult');
        gcalEventId = 'created';
      } catch (e) {
        debugPrint('[AgentService] Failed to create GCal event: $e');
      }
    }

    final id = await CallHistoryDb.insertReminder(
      title: title,
      description: description,
      remindAt: remindAt,
      googleCalendarEventId: gcalEventId,
    );

    final localTime = remindAt.toLocal();
    final timeStr =
        '${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}';

    final buf = StringBuffer('Reminder "$title" set for $timeStr');
    if (gcalEventId != null) {
      buf.write(' (also added to Google Calendar)');
    }
    buf.write('. [id=$id]');
    return buf.toString();
  }

  Future<String> _handleGetCallSummary(Map<String, dynamic> args) async {
    final sinceMinutes = args['since_minutes_ago'] as int?;
    DateTime? since;
    if (sinceMinutes != null) {
      since = DateTime.now().subtract(Duration(minutes: sinceMinutes));
    } else if (managerPresenceService?.lastBriefingAt != null) {
      since = managerPresenceService!.lastBriefingAt;
    }

    return getCallActivitySummary(since: since);
  }

  Future<String> getCallActivitySummary({DateTime? since}) async {
    final calls = await CallHistoryDb.searchCalls(
      since: since,
      limit: 50,
    );

    if (calls.isEmpty) {
      final qualifier = since != null ? 'since then' : 'recently';
      return 'No calls $qualifier.';
    }

    final buf = StringBuffer();
    buf.writeln('${calls.length} call(s) found:');

    final inbound = calls.where((c) => c['direction'] == 'inbound').toList();
    final outbound = calls.where((c) => c['direction'] == 'outbound').toList();

    if (inbound.isNotEmpty) buf.write('  ${inbound.length} inbound');
    if (inbound.isNotEmpty && outbound.isNotEmpty) buf.write(', ');
    if (outbound.isNotEmpty) buf.write('  ${outbound.length} outbound');
    buf.writeln();

    final totalDuration = calls.fold<int>(
        0, (sum, c) => sum + ((c['duration_seconds'] as int?) ?? 0));
    buf.writeln('Total duration: ${_formatDuration(totalDuration)}');

    buf.writeln('\nCalls:');
    for (final call in calls.take(10)) {
      final name = call['remote_display_name'] as String? ??
          call['remote_identity'] as String? ??
          'Unknown';
      final dir = call['direction'] as String? ?? '?';
      final status = call['status'] as String? ?? '?';
      final duration = (call['duration_seconds'] as int?) ?? 0;
      final hasRecording = (call['recording_path'] as String?)?.isNotEmpty ?? false;
      final callId = call['id'] as int?;

      buf.write('  - [$dir] $name ($status, ${_formatDuration(duration)})');
      if (hasRecording && callId != null) {
        buf.write(' [recording available, call_record_id=$callId]');
      }
      buf.writeln();
    }
    if (calls.length > 10) {
      buf.writeln('  ... and ${calls.length - 10} more.');
    }

    managerPresenceService?.markBriefingDone();
    return buf.toString();
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (mins < 60) return '${mins}m ${secs}s';
    final hours = mins ~/ 60;
    return '${hours}h ${mins % 60}m';
  }

  Future<String> _handlePlayCallRecording(Map<String, dynamic> args) async {
    final callId = args['call_record_id'] as int?;
    if (callId == null) return 'call_record_id is required.';

    final db = await CallHistoryDb.database;
    final rows = await db.query(
      'call_records',
      where: 'id = ?',
      whereArgs: [callId],
    );

    if (rows.isEmpty) return 'No call record found with id=$callId.';

    final recordingPath = rows.first['recording_path'] as String?;
    if (recordingPath == null || recordingPath.isEmpty) {
      return 'No recording exists for call $callId.';
    }

    if (!File(recordingPath).existsSync()) {
      return 'Recording file not found at $recordingPath.';
    }

    final remoteName = rows.first['remote_display_name'] as String? ??
        rows.first['remote_identity'] as String? ??
        'Unknown';

    _messages.add(ChatMessage(
      id: 'rec_${DateTime.now().millisecondsSinceEpoch}',
      role: ChatRole.system,
      type: MessageType.status,
      text: 'Recording: $remoteName',
      metadata: {
        'recording_playback': true,
        'filePath': recordingPath,
        'callId': callId,
      },
    ));
    notifyListeners();

    return 'Playing recording of call with $remoteName (call #$callId).';
  }

  Future<String> _handleListReminders(Map<String, dynamic> args) async {
    final includeFired = args['include_fired'] as bool? ?? false;

    final allReminders = await CallHistoryDb.getAllReminders(limit: 50);
    if (allReminders.isEmpty) return 'No reminders found.';

    final filtered = includeFired
        ? allReminders
        : allReminders.where((r) => r['status'] == 'pending').toList();

    if (filtered.isEmpty) return 'No pending reminders.';

    final buf = StringBuffer('${filtered.length} reminder(s):\n');
    for (final r in filtered) {
      final title = r['title'] as String? ?? 'Untitled';
      final desc = r['description'] as String?;
      final status = r['status'] as String? ?? 'pending';
      final remindAt = DateTime.parse(r['remind_at'] as String).toLocal();
      final id = r['id'] as int?;

      final mins = remindAt.difference(DateTime.now()).inMinutes;
      final timeLabel = mins > 0
          ? 'in $mins min (${_fmtTime(remindAt)})'
          : 'overdue by ${-mins} min';

      buf.write('- [$status] "$title" $timeLabel');
      if (desc != null && desc.isNotEmpty) buf.write(' — $desc');
      if (id != null) buf.write(' [id=$id]');
      buf.writeln();
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------

  String _handleCheckLocale() {
    return describeLocale(_bootContext.defaultCountryCode);
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
      debugPrint(
          '[AgentService] end_call deferred — waiting for TTS to finish');
      final speakingStream = _kokoroTts?.speakingState ?? _tts?.speakingState;
      if (speakingStream != null) {
        final completer = Completer<void>();
        late StreamSubscription<bool> sub;
        sub = speakingStream.listen((speaking) {
          if (!speaking && !completer.isCompleted) {
            completer.complete();
            sub.cancel();
          }
        });
        await completer.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            sub.cancel();
            debugPrint('[AgentService] end_call TTS wait timed out');
          },
        );
      }
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

  // ---------------------------------------------------------------------------
  // Call control tool handlers (transfer, hold, mute, conference)
  // ---------------------------------------------------------------------------

  String _handleTransferCall(Map<String, dynamic> args) {
    if (sipHelper == null) return 'SIP helper not available.';
    final target = args['target'] as String?;
    if (target == null || target.isEmpty) return 'No transfer target provided.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call to transfer.';
    final normalized = target.contains('@') ? target : ensureE164(target);
    active.refer(normalized);
    return 'Transferring call to $normalized.';
  }

  String _handleHoldCall(Map<String, dynamic> args) {
    if (sipHelper == null) return 'SIP helper not available.';
    final action = args['action'] as String?;
    if (action == null) return 'No action provided (hold or resume).';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call.';
    if (action == 'hold') {
      active.hold();
      return 'Call placed on hold.';
    } else if (action == 'resume') {
      active.unhold();
      return 'Call resumed.';
    }
    return 'Unknown action "$action". Use "hold" or "resume".';
  }

  String _handleMuteCall(Map<String, dynamic> args) {
    if (sipHelper == null) return 'SIP helper not available.';
    final muted = args['muted'] as bool?;
    if (muted == null) return 'Missing "muted" parameter.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call.';
    if (muted) {
      active.mute(true, false);
      return 'Microphone muted.';
    } else {
      active.unmute(true, false);
      return 'Microphone unmuted.';
    }
  }

  Future<String> _handleAddConferenceParticipant(
      Map<String, dynamic> args) async {
    if (sipHelper == null) return 'SIP helper not available.';
    final number = args['number'] as String?;
    if (number == null || number.isEmpty) return 'No number provided.';
    final active = sipHelper!.activeCall;
    if (active == null) return 'No active call to conference with.';

    if (active.state != CallStateEnum.HOLD) {
      active.hold();
    }

    final cleaned = ensureE164(number.contains('@') ? number : number);
    try {
      final stream = await navigator.mediaDevices
          .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
      final success =
          await sipHelper!.call(cleaned, voiceOnly: true, mediaStream: stream);
      if (success) {
        return 'Dialing $cleaned as conference participant. '
            'Use merge_conference once connected to bridge all parties.';
      }
      return 'Failed to initiate call to $cleaned.';
    } catch (e) {
      return 'Error adding participant: $e';
    }
  }

  Future<String> _handleMergeConference(Map<String, dynamic> args) async {
    if (conferenceService == null) return 'Conference service not available.';
    final conf = conferenceService!;
    if (conf.legCount < 2) {
      return 'Need at least 2 call legs to merge. '
          'Use add_conference_participant first.';
    }
    if (!conf.canMerge) {
      return 'Cannot merge right now. '
          '${conf.mergeError ?? "Ensure all legs are connected."}';
    }
    try {
      await conf.merge();
      if (conf.mergeError != null) {
        return 'Merge failed: ${conf.mergeError}';
      }
      return 'Conference merged successfully with ${conf.legCount} participants.';
    } catch (e) {
      return 'Merge error: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // Transfer rule context injection + tool handlers
  // ---------------------------------------------------------------------------

  /// When a call connects, check if a transfer rule matches the caller and
  /// inject context so the agent knows to execute the transfer.
  void _injectTransferRuleContext() {
    if (_transferRuleService == null) return;
    final caller = _remoteIdentity;
    if (caller == null || caller.isEmpty) return;

    final rule = _transferRuleService!.resolve(caller);
    if (rule == null) return;

    final mode = rule.silent ? 'SILENT (do not announce)' : 'ANNOUNCED (tell the caller you are transferring them)';
    final jfNote = rule.jobFunctionId != null
        ? ' Switch to job function #${rule.jobFunctionId} before transferring.'
        : '';
    final contextLine =
        'SYSTEM CONTEXT — Transfer rule "${rule.name}" is active for this '
        'caller. Transfer this call to ${rule.transferTarget} ($mode).$jfNote '
        'Execute the transfer now using the transfer_call tool unless the '
        'manager explicitly overrides.';

    debugPrint('[AgentService] Injecting transfer rule context: ${rule.name}');

    if (_textAgent != null) {
      _textAgent!.addSystemContext(contextLine);
    }
    if (_active) {
      _whisper.sendSystemContext(contextLine);
    }
  }

  Future<String> _handleCreateTransferRule(Map<String, dynamic> args) async {
    if (_transferRuleService == null) {
      return 'Transfer rule service not available.';
    }
    final name = args['name'] as String?;
    final target = args['transfer_target'] as String?;
    if (name == null || name.isEmpty) return '"name" is required.';
    if (target == null || target.isEmpty) return '"transfer_target" is required.';

    final patterns = (args['caller_patterns'] as List?)?.cast<String>() ??
        const <String>['*'];
    final silent = args['silent'] as bool? ?? false;
    final jfId = args['job_function_id'] as int?;
    final normalizedTarget = target.contains('@') ? target : ensureE164(target);

    final rule = TransferRule(
      name: name,
      callerPatterns: patterns.map((p) => p == '*' ? '*' : ensureE164(p)).toList(),
      transferTarget: normalizedTarget,
      silent: silent,
      jobFunctionId: jfId,
    );
    final saved = await _transferRuleService!.save(rule);
    return 'Transfer rule created (id=${saved.id}): ${saved.toSummary()}';
  }

  Future<String> _handleUpdateTransferRule(Map<String, dynamic> args) async {
    if (_transferRuleService == null) {
      return 'Transfer rule service not available.';
    }
    final id = args['id'] as int?;
    if (id == null) return '"id" is required.';

    final row = await CallHistoryDb.getTransferRule(id);
    if (row == null) return 'Transfer rule #$id not found.';
    var rule = TransferRule.fromMap(row);

    if (args.containsKey('name')) {
      rule = rule.copyWith(name: args['name'] as String?);
    }
    if (args.containsKey('enabled')) {
      rule = rule.copyWith(enabled: args['enabled'] as bool?);
    }
    if (args.containsKey('caller_patterns')) {
      final patterns = (args['caller_patterns'] as List).cast<String>();
      rule = rule.copyWith(
          callerPatterns:
              patterns.map((p) => p == '*' ? '*' : ensureE164(p)).toList());
    }
    if (args.containsKey('transfer_target')) {
      final t = args['transfer_target'] as String;
      rule = rule.copyWith(
          transferTarget: t.contains('@') ? t : ensureE164(t));
    }
    if (args.containsKey('silent')) {
      rule = rule.copyWith(silent: args['silent'] as bool?);
    }
    if (args.containsKey('job_function_id')) {
      final jfId = args['job_function_id'] as int?;
      rule = rule.copyWith(jobFunctionId: () => jfId);
    }

    await _transferRuleService!.save(rule);
    return 'Transfer rule #$id updated: ${rule.toSummary()}';
  }

  Future<String> _handleDeleteTransferRule(Map<String, dynamic> args) async {
    if (_transferRuleService == null) {
      return 'Transfer rule service not available.';
    }
    final id = args['id'] as int?;
    if (id == null) return '"id" is required.';

    final row = await CallHistoryDb.getTransferRule(id);
    if (row == null) return 'Transfer rule #$id not found.';
    await _transferRuleService!.delete(id);
    return 'Transfer rule #$id deleted.';
  }

  Future<String> _handleListTransferRules() async {
    if (_transferRuleService == null) {
      return 'Transfer rule service not available.';
    }
    await _transferRuleService!.loadAll();
    final rules = _transferRuleService!.items;
    if (rules.isEmpty) return 'No transfer rules configured.';

    final buf = StringBuffer('Transfer rules:\n');
    for (final r in rules) {
      final status = r.enabled ? 'enabled' : 'disabled';
      buf.writeln('  #${r.id} ($status): ${r.toSummary()}');
    }
    return buf.toString();
  }

  Future<String> _handleRequestTransferApproval(
      Map<String, dynamic> args) async {
    final reason = args['reason'] as String? ?? 'Caller requested a transfer.';
    final target = args['requested_target'] as String?;

    final callerName = _resolveCallerName() ?? _remoteIdentity ?? 'Unknown';
    final targetDesc =
        target != null && target.isNotEmpty ? ' to $target' : '';

    final canSms = messagingService != null &&
        messagingService!.isConfigured &&
        _agentManagerConfig.isConfigured;

    // Always show in the chat panel so it's visible if the manager is looking.
    _messages.add(ChatMessage.system(
      'TRANSFER REQUEST: $callerName wants to be transferred$targetDesc. '
      'Reason: $reason — Tell the agent YES or NO.',
    ));
    notifyListeners();

    // Send SMS to the manager's phone so they can approve even when away.
    if (canSms) {
      final smsText = 'TRANSFER REQUEST: $callerName is on the line and '
          'requesting to be transferred$targetDesc. Reason: $reason — '
          'Reply YES to approve or NO to decline.';

      await messagingService!.sendMessage(
          to: _agentManagerConfig.phoneNumber, text: smsText);

      return 'Approval request sent to the manager via SMS and posted in the '
          'chat panel. Tell the caller you are checking with the manager and '
          'will transfer them shortly if approved. Wait for the manager\'s '
          'response — do NOT transfer until you receive explicit approval.';
    }

    return 'Approval request posted in the chat for the manager (SMS not '
        'configured — manager phone or messaging must be set up in Settings). '
        'Tell the caller you are checking with the manager. Wait for the '
        'manager\'s response — do NOT transfer until you receive explicit '
        'approval.';
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
    if (filtered.length > 50) {
      buf.writeln('... and ${filtered.length - 50} more.');
    }
    return buf.toString();
  }

  Future<String> _handleSaveContact(Map<String, dynamic> args) async {
    var phone = args['phone_number'] as String? ?? '';
    if (phone.isEmpty && _callPhase.isActive) {
      phone = _remoteIdentity ?? '';
    }
    if (phone.isEmpty) return 'No phone number provided and no active call.';

    final name = args['display_name'] as String?;
    final email = args['email'] as String?;
    final company = args['company'] as String?;
    final notes = args['notes'] as String?;

    try {
      final existing = contactService?.lookupByPhone(phone);
      if (existing != null) {
        final id = existing['id'] as int;
        final updates = <String, dynamic>{};
        if (name != null && name.isNotEmpty) updates['display_name'] = name;
        if (email != null && email.isNotEmpty) updates['email'] = email;
        if (company != null && company.isNotEmpty) updates['company'] = company;
        if (notes != null && notes.isNotEmpty) updates['notes'] = notes;
        if (updates.isEmpty) return 'Contact already exists — no new fields to update.';
        await CallHistoryDb.updateContact(id, updates);
        await contactService?.loadAll();

        // Also update the remote speaker label if we just learned their name.
        if (name != null && name.isNotEmpty && _callPhase.isActive) {
          final rid = _remoteIdentity;
          if (rid != null &&
              CallHistoryDb.normalizePhone(phone) ==
                  CallHistoryDb.normalizePhone(rid)) {
            setRemotePartyName(name);
          }
        }
        return 'Contact updated: ${name ?? existing['display_name']} ($phone).';
      }

      final displayName = (name != null && name.isNotEmpty) ? name : phone;
      await CallHistoryDb.insertContact(
        displayName: displayName,
        phoneNumber: phone,
        email: email,
        company: company,
        notes: notes,
      );
      await contactService?.loadAll();

      if (name != null && name.isNotEmpty && _callPhase.isActive) {
        final rid = _remoteIdentity;
        if (rid != null &&
            CallHistoryDb.normalizePhone(phone) ==
                CallHistoryDb.normalizePhone(rid)) {
          setRemotePartyName(name);
        }
      }
      return 'Contact saved: $displayName ($phone).';
    } catch (e) {
      return 'Failed to save contact: ${e.toString().split('\n').first}';
    }
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
    if (_agentSampling) {
      return 'Already sampling. Stop the current sample first.';
    }

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
      _agentSamplingStartTime = DateTime.now();
      final msg = ChatMessage.system(
        'Capturing voice ($party)',
        metadata: {'voice_capture': true, 'capture_party': party},
      );
      msg.isStreaming = true;
      _samplingMessageId = msg.id;
      _messages.add(msg);
      notifyListeners();
      debugPrint(
          '[AgentService] Agent-initiated voice sample → $_agentSamplePath ($party)');
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
      _finalizeSamplingMessage(success: false);
      debugPrint('[AgentService] stopVoiceSample failed: $e');
      return 'Failed to stop voice sample: $e';
    }

    final name = (args['voice_name'] as String?)?.trim().isNotEmpty == true
        ? args['voice_name'] as String
        : 'Alter Ego ${DateTime.now().millisecondsSinceEpoch}';

    _finalizeSamplingMessage(success: true);

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

  void _finalizeSamplingMessage({required bool success}) {
    if (_samplingMessageId == null) return;
    final idx = _messages.indexWhere((m) => m.id == _samplingMessageId);
    if (idx >= 0) {
      final duration = _agentSamplingStartTime != null
          ? DateTime.now().difference(_agentSamplingStartTime!).inSeconds
          : 0;
      _messages[idx].isStreaming = false;
      final party = _messages[idx].metadata?['capture_party'] ?? 'remote';
      _messages[idx].text = success
          ? 'Voice captured ($party) — ${duration}s'
          : 'Voice capture failed ($party)';
    }
    _samplingMessageId = null;
    _agentSamplingStartTime = null;
    notifyListeners();
  }

  Future<String> _handleSetAgentVoice(Map<String, dynamic> args) async {
    var voiceId = args['voice_id'] as String?;
    final voiceName = args['voice_name'] as String?;

    if ((voiceId == null || voiceId.isEmpty) &&
        (voiceName != null && voiceName.isNotEmpty)) {
      final apiKey = _ttsConfig?.elevenLabsApiKey ?? '';
      if (apiKey.isEmpty) {
        return 'ElevenLabs API key is not configured. Cannot look up voice by name.';
      }
      try {
        final voices = await ElevenLabsApiService.listVoices(apiKey);
        final nameLower = voiceName.toLowerCase();
        final match = voices.cast<ElevenLabsVoice?>().firstWhere(
              (v) => v!.name.toLowerCase() == nameLower,
              orElse: () => null,
            );
        if (match == null) {
          final partial = voices.cast<ElevenLabsVoice?>().firstWhere(
                (v) => v!.name.toLowerCase().contains(nameLower),
                orElse: () => null,
              );
          if (partial == null) {
            return 'No voice found matching "$voiceName". '
                'Use list_voices to see available options.';
          }
          voiceId = partial.voiceId;
          debugPrint('[AgentService] Resolved voice name "$voiceName" → '
              '${partial.name} (${partial.voiceId})');
        } else {
          voiceId = match.voiceId;
        }
      } catch (e) {
        return 'Failed to look up voice by name: $e';
      }
    }

    if (voiceId == null || voiceId.isEmpty) {
      return 'Provide either voice_id or voice_name.';
    }

    if (_tts != null) {
      _tts!.updateVoiceId(voiceId);
    } else if (_kokoroTts != null) {
      await _kokoroTts!.setVoice(voiceId);
    } else {
      return 'No TTS provider is active. Cannot change voice.';
    }

    _messages.add(ChatMessage.system('Agent voice changed to $voiceId'));
    notifyListeners();
    debugPrint('[AgentService] Agent voice swapped to: $voiceId');
    return 'Voice updated. You are now speaking with voice_id=$voiceId. '
        'All subsequent speech will use this voice.';
  }

  Future<String> _handleListVoices() async {
    final apiKey = _ttsConfig?.elevenLabsApiKey ?? '';
    if (apiKey.isEmpty) {
      return 'ElevenLabs API key is not configured. '
          'Cannot list voices.';
    }

    try {
      final voices = await ElevenLabsApiService.listVoices(apiKey);
      if (voices.isEmpty) {
        return 'No voices found on this ElevenLabs account.';
      }

      final currentVoiceId =
          _bootContext.elevenLabsVoiceId ?? _ttsConfig?.elevenLabsVoiceId ?? '';

      final buf = StringBuffer('Available voices (${voices.length}):\n');
      for (final v in voices) {
        final active = v.voiceId == currentVoiceId ? ' [ACTIVE]' : '';
        buf.writeln('- ${v.name} (${v.category}) id=${v.voiceId}$active');
      }
      buf.writeln('\nUse set_agent_voice with voice_name or voice_id to switch.');
      return buf.toString();
    } catch (e) {
      debugPrint('[AgentService] list_voices failed: $e');
      return 'Failed to list voices: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // FlightAware tool handlers
  // ---------------------------------------------------------------------------

  Future<String> _handleLookupFlight(Map<String, dynamic> args) async {
    if (flightAwareService == null || !flightAwareService!.config.enabled) {
      return 'FlightAware integration is not enabled. Enable it in Settings > Integrations.';
    }
    final flightNumber = args['flight_number'] as String?;
    if (flightNumber == null || flightNumber.isEmpty) {
      return 'No flight number provided.';
    }

    try {
      final info = await flightAwareService!.lookupFlight(flightNumber);
      if (info == null || !info.hasRoute) {
        return 'Could not find flight $flightNumber. '
            'Make sure Chrome debug is running and the flight number is valid.';
      }
      final buf = StringBuffer('Flight $flightNumber:\n');
      if (info.airline.isNotEmpty) buf.writeln('Airline: ${info.airline}');
      buf.writeln('Origin: ${info.origin}');
      buf.writeln('Destination: ${info.destination}');
      if (info.departureTime != null) {
        buf.writeln('Departure: ${info.departureTime}');
      }
      if (info.arrivalTime != null) {
        buf.writeln('Arrival: ${info.arrivalTime}');
      }
      if (info.status != null) buf.writeln('Status: ${info.status}');
      if (info.gate != null) buf.writeln('Gate: ${info.gate}');
      return buf.toString();
    } catch (e) {
      return 'Flight lookup failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleSearchFlightsByRoute(Map<String, dynamic> args) async {
    if (flightAwareService == null || !flightAwareService!.config.enabled) {
      return 'FlightAware integration is not enabled. Enable it in Settings > Integrations.';
    }
    final origin = args['origin'] as String?;
    final destination = args['destination'] as String?;
    if (origin == null ||
        origin.isEmpty ||
        destination == null ||
        destination.isEmpty) {
      return 'Both origin and destination airport codes are required.';
    }

    try {
      final result = await flightAwareService!.searchRoute(origin, destination);
      if (result == null || result.flights.isEmpty) {
        return 'No flights found for $origin → $destination.';
      }
      final buf = StringBuffer(
          'Flights from $origin to $destination (${result.flights.length} total):\n');
      for (final f in result.flights.take(15)) {
        buf.write('${f.flightNumber} (${f.airline})');
        if (f.aircraft != null && f.aircraft!.isNotEmpty) {
          buf.write(' [${f.aircraft}]');
        }
        buf.write(' — ${f.status ?? "Unknown"}');
        if (f.departureTime != null) buf.write('  Dep: ${f.departureTime}');
        if (f.arrivalTime != null) buf.write('  Arr: ${f.arrivalTime}');
        buf.writeln();
      }
      if (result.flights.length > 15) {
        buf.writeln('(${result.flights.length - 15} more flights not shown)');
      }
      return buf.toString();
    } catch (e) {
      return 'Route search failed: ${e.toString().split('\n').first}';
    }
  }

  // ---------------------------------------------------------------------------
  // Access control helper for Gmail / Google Calendar read operations
  // ---------------------------------------------------------------------------

  /// Returns the known display name for the current remote party, or null.
  String? _resolveCallerName() {
    // Prefer the speaker label if it was set (e.g. from contacts or voiceprint).
    if (remoteSpeaker.name.isNotEmpty) return remoteSpeaker.name;
    // Fall back to the SIP display name.
    if (_remoteDisplayName != null && _remoteDisplayName!.isNotEmpty) {
      return _remoteDisplayName;
    }
    // Try a contact lookup by phone.
    final rid = _remoteIdentity;
    if (rid != null && rid.isNotEmpty) {
      final contact = contactService?.lookupByPhone(rid);
      final name = contact?['display_name'] as String?;
      if (name != null && name.isNotEmpty && name != rid) return name;
    }
    return null;
  }

  /// True when the current inbound caller matches the configured agent manager
  /// phone number — this caller should be treated with host-level privileges.
  bool get _isCallerAgentManager {
    if (!_agentManagerConfig.isConfigured) return false;
    if (!_callPhase.isActive || _isOutbound) return false;
    final remote = _remoteIdentity;
    if (remote == null || remote.isEmpty) return false;
    final normalizedRemote = CallHistoryDb.normalizePhone(remote);
    final normalizedManager =
        CallHistoryDb.normalizePhone(_agentManagerConfig.phoneNumber);
    return normalizedRemote == normalizedManager;
  }

  /// Returns null if access is granted, or a rejection message if denied.
  String? _checkReadAccess({
    required dynamic readAccessMode,
    required List<String> allowedPhones,
  }) {
    // Unrestricted always passes
    if (readAccessMode == GmailReadAccess.unrestricted ||
        readAccessMode == CalendarReadAccess.unrestricted) {
      return null;
    }

    // Agent manager callers are treated as the host for access control.
    if (_isCallerAgentManager) return null;

    final hasInboundCall = _callPhase.isActive && !_isOutbound;

    // hostOnly: block if there's an active inbound call (meaning a remote
    // caller is on the line and may be the one requesting the read).
    if (readAccessMode == GmailReadAccess.hostOnly ||
        readAccessMode == CalendarReadAccess.hostOnly) {
      if (hasInboundCall) {
        return 'Reading is restricted to the host only. '
            'There is an active inbound call, so this request is denied.';
      }
      return null;
    }

    // allowList: host always passes; remote caller must be on the list.
    if (!hasInboundCall) return null;

    final remote = _remoteIdentity;
    if (remote == null || remote.isEmpty) {
      return 'Cannot verify caller identity. Reading denied by access policy.';
    }

    final normalizedRemote = CallHistoryDb.normalizePhone(remote);
    for (final phone in allowedPhones) {
      if (CallHistoryDb.normalizePhone(phone) == normalizedRemote) {
        return null;
      }
    }

    // Also check by contact lookup
    final contact = contactService?.lookupByPhone(remote);
    if (contact != null) {
      final contactPhone = contact['phone_number'] as String? ?? '';
      for (final phone in allowedPhones) {
        if (CallHistoryDb.normalizePhone(phone) ==
            CallHistoryDb.normalizePhone(contactPhone)) {
          return null;
        }
      }
    }

    return 'The caller is not on the approved list for reading. Access denied.';
  }

  // ---------------------------------------------------------------------------
  // Gmail tool handlers
  // ---------------------------------------------------------------------------

  Future<String> _handleSendGmail(Map<String, dynamic> args) async {
    if (gmailService == null || !gmailService!.config.enabled) {
      return 'Gmail integration is not enabled. Enable it in Settings > Integrations.';
    }
    final to = args['to'] as String?;
    final subject = args['subject'] as String?;
    final body = args['body'] as String?;
    if (to == null || to.isEmpty) return 'No recipient email provided.';
    if (subject == null || subject.isEmpty) return 'No subject provided.';
    if (body == null || body.isEmpty) return 'No body provided.';

    try {
      final ok = await gmailService!.sendEmail(to, subject, body);
      return ok
          ? 'Email sent successfully to $to with subject "$subject".'
          : 'Failed to send email: ${gmailService!.error ?? "unknown error"}';
    } catch (e) {
      return 'Email send failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleSearchGmail(Map<String, dynamic> args) async {
    if (gmailService == null || !gmailService!.config.enabled) {
      return 'Gmail integration is not enabled. Enable it in Settings > Integrations.';
    }
    final denial = _checkReadAccess(
      readAccessMode: gmailService!.config.readAccessMode,
      allowedPhones: gmailService!.config.allowedPhoneNumbers,
    );
    if (denial != null) return denial;

    final query = args['query'] as String?;
    if (query == null || query.isEmpty) return 'No search query provided.';

    try {
      final result = await gmailService!.searchEmails(query);
      if (result == null || result.emails.isEmpty) {
        return 'No emails found for "$query".';
      }
      final buf = StringBuffer(
          'Found ${result.emails.length} email(s) for "$query":\n');
      for (var i = 0; i < result.emails.length && i < 10; i++) {
        final e = result.emails[i];
        buf.write('${i + 1}. ');
        if (e.sender.isNotEmpty) buf.write('From: ${e.sender} ');
        buf.write('Subject: ${e.subject}');
        if (e.date.isNotEmpty) buf.write(' (${e.date})');
        if (e.isUnread) buf.write(' [UNREAD]');
        buf.writeln();
        if (e.snippet.isNotEmpty) buf.writeln('   ${e.snippet}');
      }
      if (result.emails.length > 10) {
        buf.writeln('(${result.emails.length - 10} more not shown)');
      }
      return buf.toString();
    } catch (e) {
      return 'Gmail search failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleReadGmail(Map<String, dynamic> args) async {
    if (gmailService == null || !gmailService!.config.enabled) {
      return 'Gmail integration is not enabled. Enable it in Settings > Integrations.';
    }
    final denial = _checkReadAccess(
      readAccessMode: gmailService!.config.readAccessMode,
      allowedPhones: gmailService!.config.allowedPhoneNumbers,
    );
    if (denial != null) return denial;

    final query = args['query'] as String?;
    final index = args['index'] as int? ?? 0;
    if (query == null || query.isEmpty) return 'No search query provided.';

    try {
      final info = await gmailService!.readEmail(query, index: index);
      if (info == null || !info.hasContent) {
        return 'Could not read email. Make sure Chrome is running and you are logged into Gmail.';
      }
      final buf = StringBuffer();
      if (info.sender.isNotEmpty) buf.writeln('From: ${info.sender}');
      if (info.recipient.isNotEmpty) buf.writeln('To: ${info.recipient}');
      buf.writeln('Subject: ${info.subject}');
      if (info.date.isNotEmpty) buf.writeln('Date: ${info.date}');
      buf.writeln('---');
      buf.writeln(info.body.length > 2000
          ? '${info.body.substring(0, 2000)}...(truncated)'
          : info.body);
      return buf.toString();
    } catch (e) {
      return 'Email read failed: ${e.toString().split('\n').first}';
    }
  }

  // ---------------------------------------------------------------------------
  // Google Calendar tool handlers
  // ---------------------------------------------------------------------------

  Future<String> _handleListGoogleCalendars(
      Map<String, dynamic> args) async {
    if (googleCalendarService == null ||
        !googleCalendarService!.config.enabled) {
      return 'Google Calendar integration is not enabled. Enable it in Settings > Integrations.';
    }
    try {
      final calendars = await googleCalendarService!
          .listCalendars()
          .timeout(const Duration(seconds: 30),
              onTimeout: () => <Map<String, String>>[]);
      if (calendars.isEmpty) {
        return 'No calendars found. The sidebar may not have loaded, no calendars are visible, or the request timed out.';
      }
      final buf = StringBuffer('Available calendars (${calendars.length}):\n');
      for (var i = 0; i < calendars.length; i++) {
        buf.writeln('${i + 1}. ${calendars[i]['name']} (id: ${calendars[i]['id']})');
      }
      return buf.toString();
    } catch (e) {
      return 'Failed to list calendars: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleCreateGoogleCalendarEvent(
      Map<String, dynamic> args) async {
    if (googleCalendarService == null ||
        !googleCalendarService!.config.enabled) {
      return 'Google Calendar integration is not enabled. Enable it in Settings > Integrations.';
    }
    final title = args['title'] as String?;
    final date = args['date'] as String?;
    final startTime = args['start_time'] as String?;
    final endTime = args['end_time'] as String?;
    if (title == null || title.isEmpty) return 'No event title provided.';
    if (date == null || date.isEmpty) return 'No date provided.';
    if (startTime == null || startTime.isEmpty) {
      return 'No start time provided.';
    }

    if (endTime == null || endTime.isEmpty) return 'No end time provided.';

    try {
      final ok = await googleCalendarService!
          .createEvent(
            title: title,
            date: date,
            startTime: startTime,
            endTime: endTime,
            description: args['description'] as String?,
            location: args['location'] as String?,
            calendarId: args['calendar_id'] as String?,
          )
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      return ok
          ? 'Event "$title" created on $date from $startTime to $endTime.'
          : 'Failed to create event: ${googleCalendarService!.error ?? "timed out or unknown error"}';
    } catch (e) {
      return 'Event creation failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleCreateNewGoogleCalendar(
      Map<String, dynamic> args) async {
    if (googleCalendarService == null ||
        !googleCalendarService!.config.enabled) {
      return 'Google Calendar integration is not enabled. Enable it in Settings > Integrations.';
    }
    final name = args['name'] as String?;
    if (name == null || name.isEmpty) return 'No calendar name provided.';

    try {
      final ok = await googleCalendarService!
          .createCalendar(name: name)
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
      return ok
          ? 'New calendar "$name" created successfully.'
          : 'Failed to create calendar: ${googleCalendarService!.error ?? "timed out or unknown error"}';
    } catch (e) {
      return 'Calendar creation failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleReadGoogleCalendar(Map<String, dynamic> args) async {
    if (googleCalendarService == null ||
        !googleCalendarService!.config.enabled) {
      return 'Google Calendar integration is not enabled. Enable it in Settings > Integrations.';
    }
    final denial = _checkReadAccess(
      readAccessMode: googleCalendarService!.config.readAccessMode,
      allowedPhones: googleCalendarService!.config.allowedPhoneNumbers,
    );
    if (denial != null) return denial;

    final date = args['date'] as String?;
    if (date == null || date.isEmpty) return 'No date provided.';

    try {
      final events = await googleCalendarService!
          .readEvents(date)
          .timeout(const Duration(seconds: 30), onTimeout: () => []);
      if (events.isEmpty) {
        return 'No events found on $date (or the request timed out).';
      }
      final buf = StringBuffer('Events on $date (${events.length}):\n');
      for (var i = 0; i < events.length; i++) {
        final e = events[i];
        buf.write('${i + 1}. ${e.title}');
        if (e.startTime.isNotEmpty || e.endTime.isNotEmpty) {
          buf.write(' (${e.startTime}–${e.endTime})');
        }
        if (e.location.isNotEmpty) buf.write(' @ ${e.location}');
        buf.writeln();
      }
      return buf.toString();
    } catch (e) {
      return 'Calendar read failed: ${e.toString().split('\n').first}';
    }
  }

  Future<String> _handleSyncGoogleCalendar(Map<String, dynamic> args) async {
    if (googleCalendarService == null ||
        !googleCalendarService!.config.enabled) {
      return 'Google Calendar integration is not enabled. Enable it in Settings > Integrations.';
    }
    try {
      return await googleCalendarService!
          .syncBidirectional()
          .timeout(const Duration(seconds: 30),
              onTimeout: () => 'Calendar sync timed out after 30s.');
    } catch (e) {
      return 'Calendar sync failed: ${e.toString().split('\n').first}';
    }
  }

  // ---------------------------------------------------------------------------
  // Google Search tool handler
  // ---------------------------------------------------------------------------

  Future<String> _handleGoogleSearch(Map<String, dynamic> args) async {
    if (googleSearchService == null || !googleSearchService!.config.enabled) {
      return 'Google Search integration is not enabled. Enable it in Settings > Integrations.';
    }
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) return 'No search query provided.';

    try {
      final result = await googleSearchService!.searchGoogle(query);
      if (result == null || result.items.isEmpty) {
        return 'No results found for "$query".';
      }
      final buf = StringBuffer('Google results for "$query":\n\n');
      for (final item in result.items.take(8)) {
        buf.writeln('**${item.title}**');
        if (item.url.isNotEmpty) buf.writeln(item.url);
        if (item.snippet.isNotEmpty) buf.writeln(item.snippet);
        buf.writeln();
      }
      if (result.items.length > 8) {
        buf.writeln('(${result.items.length - 8} more results not shown)');
      }
      return buf.toString();
    } catch (e) {
      return 'Google search failed: ${e.toString().split('\n').first}';
    }
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
      // Respect text-only job function even with stayUnmuted policy.
      if (!_bootContext.textOnly) {
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
      // Don't auto-unmute TTS when the job function is text-only.
      if (!_bootContext.textOnly) {
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

  /// Max gap between transcript chunks to still merge into one bubble.
  static const _transcriptMergeWindowMs = 12000;

  /// Append [text] to the last transcript bubble if it's from the same
  /// [role] and within the merge window, otherwise create a new bubble.
  void _addOrMergeTranscript(
    ChatRole role,
    String text, {
    String? speakerName,
    Map<String, dynamic>? metadata,
  }) {
    if (_messages.isNotEmpty) {
      final last = _messages.last;
      if (last.type == MessageType.transcript &&
          last.role == role &&
          !last.isStreaming &&
          last.metadata?['isPreviousCall'] != true &&
          DateTime.now().difference(last.timestamp).inMilliseconds <
              _transcriptMergeWindowMs) {
        last.text = '${last.text} $text';
        notifyListeners();
        return;
      }
    }
    _messages.add(ChatMessage.transcript(
      role,
      text,
      speakerName: speakerName,
      metadata: metadata,
    ));
    notifyListeners();
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

  void addReminderMessage(String text, {int? reminderId}) {
    _messages.add(ChatMessage.reminder(
      text,
      reminderId: reminderId,
      actions: [
        if (reminderId != null) ...[
          const MessageAction(label: 'Dismiss', value: 'dismiss_reminder'),
          const MessageAction(label: 'Snooze 15m', value: 'snooze_reminder'),
        ],
        const MessageAction(label: 'Tell me more', value: 'tell_me_more'),
      ],
    ));
    notifyListeners();
  }

  void addMissedReminderMessage(String text, {int? reminderId}) {
    _messages.add(ChatMessage.reminder(
      text,
      reminderId: reminderId,
      actions: [
        if (reminderId != null) ...[
          const MessageAction(
              label: 'Still do this', value: 'confirm_missed_reminder'),
          const MessageAction(label: 'Dismiss', value: 'dismiss_reminder'),
        ],
      ],
    ));
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

  void sendFileAttachment({required String fileName, required String content}) {
    if (content.trim().isEmpty) return;

    _messages.add(ChatMessage.attachment(
      'Attached file: $fileName',
      fileName: fileName,
    ));
    notifyListeners();

    final contextMsg = '[ATTACHED FILE "$fileName" — read silently, do NOT read '
        'this aloud or repeat it back. Understand the content and use it as '
        'context for the conversation.]\n\n$content';

    if (_active) {
      if (_splitPipeline && _textAgent != null) {
        _textAgent!.addSystemContext(contextMsg);
      } else {
        _whisper.sendSystemContext(contextMsg);
      }
    }
  }

  void updateSpeakerName(String speakerRole, String name) {
    final idx = _bootContext.speakers.indexWhere((s) => s.role == speakerRole);
    if (idx >= 0) {
      _bootContext.speakers[idx].name = name;
      notifyListeners();
    }
  }

  /// When true, the agent ignores `failed`/`ended` phase transitions so that
  /// SIP fork replacements (e.g. Telnyx multi-proxy delivery) don't tear down
  /// agent state between forks. Set by the dialpad during fork coalescing.
  bool forkCoalescing = false;

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
    // During fork coalescing, suppress failed/ended so the agent doesn't
    // tear down state between SIP forks of the same logical call.
    if (forkCoalescing &&
        (phase == CallPhase.ended || phase == CallPhase.failed)) {
      debugPrint(
          '[AgentService] Suppressed ${phase.name} during fork coalescing');
      return;
    }

    final phaseChanged = phase != _callPhase || partyCount != _partyCount;

    _callPhase = phase;
    _partyCount = partyCount;
    if (remoteIdentity != null) _remoteIdentity = remoteIdentity;
    if (remoteDisplayName != null) _remoteDisplayName = remoteDisplayName;
    if (localIdentity != null) _localIdentity = localIdentity;
    if (outbound != null) _isOutbound = outbound;

    // Auto-mute/unmute based on policy
    _applyMutePolicy(phase);

    // Refresh text agent instructions when call state changes so that
    // context like agent-manager elevation is present during the call.
    if (phase == CallPhase.initiating || phase == CallPhase.ended ||
        phase == CallPhase.failed) {
      _textAgent?.updateInstructions(_buildTextAgentInstructions());
    }

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

      // Pre-fetch the last transcript with this remote party so it's ready
      // by the time the connected greeting fires.
      final priorRid = remoteIdentity ?? _remoteIdentity;
      if (priorRid != null && priorRid.isNotEmpty) {
        _fetchPriorCallTranscript(priorRid);
      }
    }

    if (phase == CallPhase.ended || phase == CallPhase.failed) {
      final String status;
      if (!_isOutbound && _connectedAt == null) {
        status = 'missed';
      } else if (phase == CallPhase.failed) {
        status = 'failed';
      } else {
        status = 'completed';
      }
      callHistory?.endCallRecord(status: status);

      // Store the remote party's voiceprint if we know who they are
      _saveRemoteVoiceprint();

      if (_remoteIdentity != null) _lastDialedNumber = _remoteIdentity;
      _remoteIdentity = null;
      _remoteDisplayName = null;
      _localIdentity = null;
      _connectedAt = null;
      _priorCallTranscript = null;
      _priorTranscriptWhispered = false;
      _beepDetected = false;
      _voicemailPromptSent = false;
      _ivrHeard = false;
      _hasConnectedBefore = false;
      _inBeepWatchMode = false;
      _settleWordCount = 0;
      _preGreetInFlight = false;
      _preGreetTextBuffer = null;
      _preGreetFinalText = null;
      _preGreetReady = false;
      _preGreetGraceUntil = null;
      _postGreetGraceUntil = null;
      _cumulativeSpeechMs = 0;
      _clearRemotePartyName();
      _cancelSettleTimer();
      _cancelBeepWatch();
      _stopCadenceTracking();
      _cancelConnectedGreeting();
      _recentAgentTexts.clear();
      _pendingTranscripts.clear();
      _settleTranscripts.clear();
      _settleAccumulatedTexts.clear();
      _postSpeakFlushTimer?.cancel();
      _playbackEndDebounce?.cancel();
      _ttsGenerationComplete = false;
      _stopTtsLevelDrain();
      _whisper.resetSpeakerIdentifier();
      _whisper.stopResponseAudio();
      _whisper.inCallMode = false;
      _activeTtsEndGeneration();
      _textAgent?.reset();

      // Clean up any agent-initiated voice sampling still in progress
      if (_agentSampling) {
        try {
          _tapChannel.invokeMethod('stopVoiceSample');
        } catch (_) {}
        _agentSampling = false;
        _agentSamplePath = null;
        _finalizeSamplingMessage(success: false);
      }

      // Reset any cloned-voice override so the agent reverts to its default
      // voice for subsequent interactions (prevents sticky voice bug).
      _tts?.updateVoiceId(_bootContext.elevenLabsVoiceId);

      // Return to idle after a brief delay so the agent can listen again
      // between calls. Without this, _callPhase stays at ended forever,
      // which blocks agent responses and keeps TTS muted.
      Future.delayed(const Duration(seconds: 2), () {
        if (_callPhase == CallPhase.ended || _callPhase == CallPhase.failed) {
          _callPhase = CallPhase.idle;
          _partyCount = 1;
          _userMuteOverride = false;
          // Restore listening state so the agent can hear new commands
          if (_muted) {
            _muted = false;
            _whisper.muted = false;
            _statusText = _speaking ? 'Speaking...' : 'Listening...';
          }
          if (_splitPipeline && _ttsMuted && !_bootContext.textOnly) {
            _ttsMuted = false;
          }
          notifyListeners();
          debugPrint('[AgentService] Returned to idle after call ended');
        }
      });
    }

    if (phase == CallPhase.settling) {
      _whisper.inCallMode = true;
      _startSettleTimer();
      _activeTtsWarmUp();
    } else if (_callPhase != CallPhase.settling) {
      _cancelSettleTimer();
    }

    if (!phaseChanged) {
      notifyListeners();
      return;
    }

    final demo = demoModeService;
    final maskedRemoteId =
        (demo != null && demo.enabled && _remoteIdentity != null)
            ? demo.maskPhone(_remoteIdentity!)
            : _remoteIdentity;
    final maskedRemoteName =
        (demo != null && demo.enabled && _remoteDisplayName != null)
            ? demo.maskDisplayName(_remoteDisplayName!)
            : _remoteDisplayName;
    final maskedLocalId =
        (demo != null && demo.enabled && _localIdentity != null)
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
    // Skip text agent context when (a) promoting to connected after the
    // pre-greeting already fired, or (b) during settling while a
    // pre-greeting LLM call is in flight — that context would accumulate
    // in _pendingContext and trigger a duplicate greeting via the
    // _respond() finally block's _scheduleFlush().
    final skipContext =
        (phase == CallPhase.connected && _hasConnectedBefore) ||
        _preGreetInFlight;
    if (!skipContext) {
      _textAgent?.addSystemContext(contextText);
    }

    if (phase == CallPhase.connected) {
      if (!_hasConnectedBefore) {
        _scheduleConnectedGreeting();
        _hasConnectedBefore = true;
        _injectTransferRuleContext();
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
    _settleAccumulatedTexts.clear();
    _settleStartTime = DateTime.now();
    _cancelBeepWatch();
    _startCadenceTracking();
    final windowMs = _isOutbound ? _settleWindowOutboundMs : _settleWindowInboundMs;
    _settleTimer = Timer(Duration(milliseconds: windowMs), () {
      _tryPromoteFromSettle();
    });

    // Pre-generate the greeting during settle so LLM + TTS latency is
    // absorbed by the settle window. Safe for both directions: inbound
    // callers are real humans (no IVR risk), outbound may hit voicemail.
    if (_splitPipeline && _textAgent != null) {
      _firePreGreeting();
    }
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
  ///
  /// When IVR has been detected, instead of promoting immediately on silence,
  /// enter beep-watch mode to wait for the voicemail recording tone.
  void _tryPromoteFromSettle() {
    if (_callPhase != CallPhase.settling) return;
    final int elapsed = _settleStartTime != null
        ? DateTime.now().difference(_settleStartTime!).inMilliseconds
        : 0;
    if (_whisper.vadActive && elapsed < _maxSettleMs) {
      debugPrint(
          '[AgentService] Settle timer fired but VAD active — deferring');
      _settleTimer = Timer(const Duration(milliseconds: 1000), () {
        _tryPromoteFromSettle();
      });
      return;
    }
    if (elapsed >= _maxSettleMs) {
      debugPrint(
          '[AgentService] Settle ceiling reached in VAD loop — force-promoting');
      _promoteToConnected();
      return;
    }

    // If we heard IVR content and speech just stopped, enter beep-watch
    // instead of promoting immediately — the voicemail beep may be imminent.
    // (Outbound only — inbound calls never do IVR/voicemail detection.)
    if (_isOutbound && _ivrHeard && !_inBeepWatchMode) {
      debugPrint(
          '[AgentService] Settle timer fired with IVR heard — entering beep watch');
      _enterBeepWatchMode();
      return;
    }

    _promoteToConnected();
  }

  void _cancelSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _preGreetTimer?.cancel();
    _preGreetTimer = null;
    _ivrHitsInSettle = 0;
    _settleAccumulatedTexts.clear();
    _cancelBeepWatch();
    _stopCadenceTracking();
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

    // Pre-greeting already buffered — flush immediately.
    if (_preGreetReady) {
      _flushPreGreeting();
      return;
    }
    // Pre-greeting still streaming — it will flush on arrival.
    if (_preGreetInFlight) {
      debugPrint(
          '[AgentService] Pre-greeting in flight — will flush on arrival');
      return;
    }

    _connectedGreetTimer = Timer(
      const Duration(milliseconds: _connectedGreetDelayMs),
      () => _tryFireConnectedGreeting(),
    );
  }

  void _tryFireConnectedGreeting() {
    if (_callPhase != CallPhase.connected) return;

    _greetDeferStart ??= DateTime.now();
    final elapsed = DateTime.now().difference(_greetDeferStart!).inMilliseconds;

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
      debugPrint(
          '[AgentService] Connected greeting — forwarding ${_settleTranscripts.length} settle transcript(s)');
      _drainSettleTranscripts();
      return;
    }

    _whisperPriorTranscriptOnce();

    String prompt;
    if (_isOutbound) {
      prompt = '[SYSTEM] The call is connected and the line is quiet. '
          'If you heard a voicemail greeting followed by a beep, leave a brief voicemail now. '
          'Otherwise, begin the conversation per your job function instructions.';
    } else {
      final callerName = _resolveCallerName();
      final nameClause = callerName != null
          ? 'The caller is $callerName. Address them by name.'
          : 'You do not know the caller\'s name yet — if they provide it, '
              'use save_contact to remember it for next time.';
      prompt = '[SYSTEM] An incoming call has connected. The caller is now on the line. '
          'This is an INBOUND call — someone called you. Do NOT say "calling" or act as if you placed this call. '
          '$nameClause '
          'Greet the caller warmly and help them per your job function instructions.';
    }
    if (_splitPipeline && _textAgent != null) {
      _textAgent!.sendUserMessage(prompt);
    } else if (_active) {
      _whisper.sendSystemDirective(prompt);
    }
    _postGreetGraceUntil = DateTime.now().add(const Duration(seconds: 8));
    debugPrint('[AgentService] Connected greeting triggered (line quiet, ${_isOutbound ? "outbound" : "inbound"})');
  }

  void _cancelConnectedGreeting() {
    _connectedGreetTimer?.cancel();
    _connectedGreetTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Prior-call transcript: fetch last conversation with the same remote party
  // ---------------------------------------------------------------------------

  bool _priorTranscriptWhispered = false;

  /// Send the prior-call transcript to the LLM exactly once per call.
  void _whisperPriorTranscriptOnce() {
    if (_priorTranscriptWhispered || _priorCallTranscript == null) return;
    _priorTranscriptWhispered = true;

    final historyPrompt =
        '[SYSTEM] Here is the transcript from your last call with this person. '
        'Use it for context — reference prior topics naturally if relevant, '
        'but do NOT recite or summarize it unprompted.\n\n'
        '$_priorCallTranscript';
    if (_splitPipeline && _textAgent != null) {
      _textAgent!.addSystemContext(historyPrompt);
    } else if (_active) {
      _whisper.sendSystemDirective(historyPrompt);
    }
    debugPrint(
        '[AgentService] Prior transcript whispered (${_priorCallTranscript!.length} chars)');
  }

  Future<void> _fetchPriorCallTranscript(String remoteIdentity) async {
    try {
      final rows =
          await CallHistoryDb.getLastTranscriptForRemote(remoteIdentity);
      if (rows.isEmpty) {
        _priorCallTranscript = null;
        return;
      }

      final buf = StringBuffer();
      for (final row in rows) {
        final role = row['role'] as String? ?? 'unknown';
        final speaker = row['speaker_name'] as String? ?? '';
        final text = row['text'] as String? ?? '';
        if (text.isEmpty) continue;
        final label = speaker.isNotEmpty ? speaker : role;
        buf.writeln('$label: $text');
      }

      var transcript = buf.toString().trim();
      if (transcript.isEmpty) {
        _priorCallTranscript = null;
        return;
      }

      const maxLen = 2000;
      if (transcript.length > maxLen) {
        transcript = '…${transcript.substring(transcript.length - maxLen)}';
      }
      _priorCallTranscript = transcript;
      debugPrint(
          '[AgentService] Prior transcript loaded (${transcript.length} chars)');
    } catch (e) {
      debugPrint('[AgentService] Failed to fetch prior transcript: $e');
      _priorCallTranscript = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Pre-greeting: fire LLM during settle, flush on connect
  // ---------------------------------------------------------------------------

  void _firePreGreeting() {
    _preGreetInFlight = true;
    _preGreetTextBuffer = StringBuffer();
    _preGreetFinalText = null;
    _preGreetReady = false;

    _whisperPriorTranscriptOnce();

    String prompt;
    if (_isOutbound) {
      prompt = '[SYSTEM] The call is connected and the line is quiet. '
          'If you heard a voicemail greeting followed by a beep, leave a brief voicemail now. '
          'Otherwise, begin the conversation per your job function instructions.';
    } else {
      final callerName = _resolveCallerName();
      final nameClause = callerName != null
          ? 'The caller is $callerName. Address them by name.'
          : 'You do not know the caller\'s name yet — if they provide it, '
              'use save_contact to remember it for next time.';
      prompt = '[SYSTEM] An incoming call has connected. The caller is now on the line. '
          'This is an INBOUND call — someone called you. Do NOT say "calling" or act as if you placed this call. '
          '$nameClause '
          'Greet the caller warmly and help them per your job function instructions.';
    }
    _textAgent!.sendUserMessage(prompt);
    debugPrint('[AgentService] Pre-greeting fired during settle (${_isOutbound ? "outbound" : "inbound"})');
  }

  /// Play the pre-generated greeting through TTS and add it to chat.
  void _flushPreGreeting() {
    final text = _preGreetFinalText;
    if (text == null || text.isEmpty) {
      _discardPreGreeting();
      return;
    }
    _preGreetReady = false;
    _preGreetFinalText = null;
    _preGreetTextBuffer = null;
    _cancelConnectedGreeting();

    if (_ivrHeard) {
      debugPrint('[AgentService] Pre-greeting discarded — IVR detected');
      return;
    }

    debugPrint('[AgentService] Flushing pre-generated greeting');

    _preGreetGraceUntil = DateTime.now().add(const Duration(seconds: 10));

    // Insert settle-phase transcripts BEFORE the greeting so the UI
    // reflects chronological order (remote "Hello?" → agent greeting).
    // Added as system context (not addTranscript) to avoid triggering a
    // duplicate LLM response.
    if (_settleTranscripts.isNotEmpty) {
      final speaker = remoteSpeaker;
      for (final event in _settleTranscripts) {
        final settleText = event.text.trim();
        if (settleText.isEmpty) continue;
        if (IvrDetector.isIvr(settleText)) continue;
        _addOrMergeTranscript(
          ChatRole.remoteParty,
          settleText,
          speakerName: speaker.label,
        );
        callHistory?.addTranscript(
          role: 'remote',
          speakerName: speaker.label,
          text: settleText,
        );
        _textAgent?.addSystemContext('[${speaker.label}]: $settleText');
      }
      _settleTranscripts.clear();
      debugPrint(
          '[AgentService] Pre-greet: added settle transcripts as context');
    }

    // Clear any context that accumulated during the pre-greeting LLM call
    // (e.g. transfer rules, call state) BEFORE adding the greeting to
    // _messages. Without this, the text agent's finally-block _scheduleFlush
    // races to produce a duplicate response.
    _textAgent?.clearPendingContext();

    final displayText = VocalExpressionRegistry.stripForDisplay(text);

    _recentAgentTexts.add(displayText);
    while (_recentAgentTexts.length > _maxRecentAgentTexts) {
      _recentAgentTexts.removeAt(0);
    }
    callHistory?.addTranscript(role: 'agent', text: displayText);

    final msg = ChatMessage.agent(displayText);
    _messages.add(msg);
    notifyListeners();

    if (_hasTts && !_ttsMuted && !_muted) {
      _ttsBracketDepth = 0;
      _activeTtsStartGeneration();
      final ttsText = _flattenMarkdownForTtsDelta(
        _stripBracketsForTts(VocalExpressionRegistry.processForTts(text)),
      ).trim();
      if (ttsText.isNotEmpty) {
        _activeTtsSendText(ttsText);
      }
      _activeTtsEndGeneration();
    }

  }

  void _discardPreGreeting() {
    _preGreetInFlight = false;
    _preGreetTextBuffer = null;
    _preGreetFinalText = null;
    _preGreetReady = false;
  }

  /// Forward any transcripts captured during the settling phase to the LLM.
  /// Unlike the normal live path, we skip the async getSpeakerInfo() call
  /// because the speaker state has changed since these were captured.
  /// Settle-phase audio is always from the remote party.
  void _drainSettleTranscripts() {
    if (_settleTranscripts.isEmpty) return;

    // Inject prior-call transcript before the settle transcripts so the agent
    // has historical context even when the greeting path is bypassed.
    _whisperPriorTranscriptOnce();

    final batch = List<TranscriptionEvent>.from(_settleTranscripts);
    _settleTranscripts.clear();

    final speaker = remoteSpeaker;

    for (final event in batch) {
      final text = event.text.trim();
      if (text.isEmpty) continue;
      if (IvrDetector.isIvr(text)) continue;
      if (_isEchoOfAgentResponse(text)) continue;

      _addOrMergeTranscript(
        ChatRole.remoteParty,
        text,
        speakerName: speaker.label,
      );

      callHistory?.addTranscript(
        role: 'remote',
        speakerName: speaker.label,
        text: text,
      );

      _textAgent?.addTranscript(speaker.label, text);
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

  // MARK: - Beep-watch mode

  /// Enter beep-watch: after IVR content is detected and speech stops, wait
  /// up to [_beepWatchTimeoutMs] for the native Goertzel filter to detect a
  /// recording tone. If no beep arrives, trigger the voicemail prompt anyway
  /// (many systems don't produce a detectable beep).
  void _enterBeepWatchMode() {
    if (_inBeepWatchMode) return;
    _inBeepWatchMode = true;
    _beepWatchTimer?.cancel();
    _beepWatchSilenceTimer?.cancel();

    // If VAD is still active, wait for silence first before starting the
    // beep timeout. Otherwise start immediately.
    if (_whisper.vadActive) {
      debugPrint('[AgentService] Beep-watch: waiting for silence');
      _beepWatchSilenceTimer =
          Timer(const Duration(milliseconds: _beepWatchSilenceMs), () {
        if (_whisper.vadActive) {
          // Still speaking — recheck in 500ms, up to settle ceiling.
          final int elapsed = _settleStartTime != null
              ? DateTime.now().difference(_settleStartTime!).inMilliseconds
              : 0;
          if (elapsed < _maxSettleMs) {
            _beepWatchSilenceTimer =
                Timer(const Duration(milliseconds: 500), () {
              _enterBeepWatchMode();
            });
            _inBeepWatchMode = false;
            return;
          }
        }
        _startBeepWatchTimeout();
      });
    } else {
      _startBeepWatchTimeout();
    }
  }

  void _startBeepWatchTimeout() {
    debugPrint('[AgentService] Beep-watch: started ${_beepWatchTimeoutMs}ms timeout');
    _beepWatchTimer?.cancel();
    _beepWatchTimer =
        Timer(const Duration(milliseconds: _beepWatchTimeoutMs), () {
      debugPrint('[AgentService] Beep-watch: timeout — no beep detected');
      _inBeepWatchMode = false;
      // Promote to connected so the voicemail prompt can fire.
      if (_callPhase == CallPhase.settling) {
        _promoteToConnected();
      }
      // Trigger voicemail even without a beep — many systems don't beep.
      if (!_voicemailPromptSent && _ivrHeard) {
        _triggerVoicemailPrompt();
      }
    });
  }

  void _cancelBeepWatch() {
    _beepWatchTimer?.cancel();
    _beepWatchTimer = null;
    _beepWatchSilenceTimer?.cancel();
    _beepWatchSilenceTimer = null;
    _inBeepWatchMode = false;
  }

  // MARK: - Cadence tracking

  /// Start periodic cadence checks during settling. Monitors cumulative
  /// VAD-active time and word count to detect long automated greetings.
  void _startCadenceTracking() {
    _cadenceTimer?.cancel();
    _cumulativeSpeechMs = 0;
    _settleWordCount = 0;
    _vadSpeechStartTime = _whisper.vadActive ? DateTime.now() : null;
    _cadenceTimer = Timer.periodic(
      const Duration(milliseconds: _cadenceCheckIntervalMs),
      (_) => _cadenceTick(),
    );
  }

  void _cadenceTick() {
    if (_callPhase != CallPhase.settling) {
      _stopCadenceTracking();
      return;
    }

    // Accumulate VAD-active time.
    if (_whisper.vadActive) {
      _vadSpeechStartTime ??= DateTime.now();
    } else if (_vadSpeechStartTime != null) {
      _cumulativeSpeechMs +=
          DateTime.now().difference(_vadSpeechStartTime!).inMilliseconds;
      _vadSpeechStartTime = null;
    }

    final int totalSpeechMs = _cumulativeSpeechMs +
        (_vadSpeechStartTime != null
            ? DateTime.now().difference(_vadSpeechStartTime!).inMilliseconds
            : 0);

    // Long continuous speech (>5s) with many words and no IVR keyword hits
    // yet — run accumulated confidence check. (Outbound only.)
    if (_isOutbound && totalSpeechMs > 5000 && _settleWordCount >= 15 && !_ivrHeard) {
      final IvrConfidence acc =
          IvrDetector.accumulatedConfidence(_settleAccumulatedTexts);
      if (acc.type == CallPartyType.ivr) {
        debugPrint(
            '[AgentService] Cadence: long speech (${totalSpeechMs}ms, $_settleWordCount words) '
            'classified as IVR by accumulated analysis');
        _ivrHeard = true;
        _ivrHitsInSettle++;
        _extendSettleTimer();
        if (acc.ivrEnding) {
          _enterBeepWatchMode();
        }
      }
    }
  }

  void _stopCadenceTracking() {
    _cadenceTimer?.cancel();
    _cadenceTimer = null;
    _vadSpeechStartTime = null;
  }

  // MARK: - Mailbox full / undeliverable

  /// Handle "mailbox is full" or "not in service" detections. These mean
  /// leaving a voicemail is not possible — notify the host via a system
  /// message instead of attempting to record.
  void _handleMailboxFull(String transcriptText) {
    _cancelSettleTimer();
    _cancelBeepWatch();

    if (_callPhase == CallPhase.settling) {
      _promoteToConnected();
    }
    _voicemailPromptSent = true; // prevent normal voicemail prompt

    const String prompt =
        '[SYSTEM] The voicemail box is full or the number is not accepting '
        'messages. You cannot leave a voicemail. Inform the host briefly '
        'and do NOT attempt to record a message.';
    if (_splitPipeline && _textAgent != null) {
      _textAgent!.sendUserMessage(prompt);
    } else if (_active) {
      _whisper.sendSystemDirective(prompt);
    }
    debugPrint('[AgentService] Mailbox full — voicemail skipped');
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
      case 'onPlaybackComplete':
        if (_splitPipeline) {
          // AudioTap fires this per-buffer drain, not once at the end.
          // Debounce: keep the echo guard open until Nms after the LAST event.
          // Use a short window once generation is done (no more chunks coming).
          _playbackEndDebounce?.cancel();
          final debounce = _ttsGenerationComplete
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 2);
          _playbackEndDebounce = Timer(debounce, () {
            _ttsGenerationComplete = false;
            _whisper.isTtsPlaying = false;
            if (_speaking) {
              _speaking = false;
              _speakingEndTime = DateTime.now();
              _statusText = _muted ? 'Not Listening...' : 'Listening';
              notifyListeners();
              _schedulePostSpeakFlush();
            }
          });
        } else {
          _playbackSafetyTimer?.cancel();
          _whisper.isTtsPlaying = false;
        }
        break;
      case 'onBeepDetected':
        if (!_isOutbound) {
          debugPrint(
              '[AgentService] Native beep IGNORED (inbound call)');
          break;
        }
        if (!_inBeepWindow || _voicemailPromptSent) {
          debugPrint(
              '[AgentService] Native beep IGNORED (window=$_inBeepWindow sent=$_voicemailPromptSent)');
          break;
        }
        // A beep during settle/early-connected is a strong voicemail signal
        // on its own — don't require prior IVR transcript classification.
        if (!_ivrHeard) {
          debugPrint(
              '[AgentService] Beep overrides settle classification → IVR');
          _ivrHeard = true;
        }
        _beepDetected = true;
        _beepWatchTimer?.cancel();
        debugPrint('[AgentService] Native beep tone DETECTED (IVR confirmed)');
        if (_callPhase == CallPhase.settling) {
          _promoteToConnected();
        }
        break;
      case 'onBeepEnded':
        if (!_beepDetected) break;
        debugPrint('[AgentService] Native beep tone ENDED');
        _cancelBeepWatch();
        if (_callPhase == CallPhase.connected) {
          _cancelConnectedGreeting();
          _triggerVoicemailPrompt();
        } else if (_callPhase == CallPhase.settling) {
          _promoteToConnected();
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
    if (_muted && _splitPipeline) {
      _activeTtsEndGeneration();
    }
    if (!_speaking) {
      _statusText = _muted ? 'Not Listening...' : 'Listening';
    }
    _pushInstructionsIfLive();
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
    _activeTtsDispose();
    _ttsConfig = null;
    _isLocalSttMode = false;
    _localAudioSub?.cancel();
    _localAudioSub = null;
    await _whisperKitStt?.stopTranscription();
    await _whisperKitStt?.dispose();
    _whisperKitStt = null;
    _levelSub?.cancel();
    _speakingSub?.cancel();
    _vadSub?.cancel();
    _vadInterruptDebounce?.cancel();
    _audioSub?.cancel();
    _transcriptSub?.cancel();
    _responseTextSub?.cancel();
    _functionCallSub?.cancel();
    await _whisper.disconnect();
    _active = false;
    _speaking = false;
    _muted = false;
    _ttsMuted = false;
    _ttsInterrupted = false;
    _userMuteOverride = false;
    _callPhase = CallPhase.idle;
    _levels.clear();
    _messages.clear();
    _smsHistoryLoadedPhones.clear();
    _resetVoiceUiSyncState();
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
    _playbackEndDebounce?.cancel();
    _ttsGenerationComplete = false;
    _stopTtsLevelDrain();
    _tapChannel.setMethodCallHandler(null);
    _inboundSmsSub?.cancel();
    _textAgentToolSub?.cancel();
    _textAgentSub?.cancel();
    _textAgent?.dispose();
    _ttsAudioSub?.cancel();
    _ttsSpeakingSub?.cancel();
    _activeTtsDispose();
    _localAudioSub?.cancel();
    _localAudioSub = null;
    _whisperKitStt?.stopTranscription();
    _whisperKitStt?.dispose();
    _whisperKitStt = null;
    _levelSub?.cancel();
    _speakingSub?.cancel();
    _vadSub?.cancel();
    _vadInterruptDebounce?.cancel();
    _audioSub?.cancel();
    _transcriptSub?.cancel();
    _responseTextSub?.cancel();
    _functionCallSub?.cancel();
    _resetVoiceUiSyncState();
    _streamingMessageId = null;
    _whisper.dispose();
    super.dispose();
  }
}
