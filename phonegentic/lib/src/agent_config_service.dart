import 'package:shared_preferences/shared_preferences.dart';

import 'conference/conference_config.dart';
import 'models/agent_context.dart';

enum AgentMutePolicy {
  /// Unmute (voice on) when a call starts, mute (text-only) when it ends.
  autoToggle,

  /// Stay muted unless the user manually unmutes.
  stayMuted,

  /// Always keep the agent unmuted (voice on) regardless of call state.
  stayUnmuted,
}

enum TextAgentProvider { openai, claude, custom }

enum TranscriptionTarget { both, localOnly, remoteOnly }

class VoiceAgentConfig {
  final bool enabled;
  final String apiKey;
  final String model;
  final String voice;
  final String instructions;
  final TranscriptionTarget target;
  final int echoGuardMs;

  const VoiceAgentConfig({
    this.enabled = false,
    this.apiKey = '',
    this.model = 'gpt-4o-mini-realtime-preview',
    this.voice = 'coral',
    this.instructions = '',
    this.target = TranscriptionTarget.both,
    this.echoGuardMs = 2500,
  });

  bool get isConfigured => apiKey.isNotEmpty;

  VoiceAgentConfig copyWith({
    bool? enabled,
    String? apiKey,
    String? model,
    String? voice,
    String? instructions,
    TranscriptionTarget? target,
    int? echoGuardMs,
  }) {
    return VoiceAgentConfig(
      enabled: enabled ?? this.enabled,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      voice: voice ?? this.voice,
      instructions: instructions ?? this.instructions,
      target: target ?? this.target,
      echoGuardMs: echoGuardMs ?? this.echoGuardMs,
    );
  }
}

class TextAgentConfig {
  final bool enabled;
  final TextAgentProvider provider;
  final String openaiApiKey;
  final String claudeApiKey;
  final String openaiModel;
  final String claudeModel;
  final String customApiKey;
  final String customEndpointUrl;
  final String customModel;
  final String systemPrompt;

  // Fallback ("smarter") models used by the stuck-detection escalation
  // path. When the agent is detected to be stalling (asking the same
  // question, no tool use, terse non-progress replies), the next LLM
  // request is one-shot retargeted at the fallback model with a nudge
  // appended to the system prompt. Empty string disables escalation
  // for that provider.
  final String openaiFallbackModel;
  final String claudeFallbackModel;
  final String customFallbackModel;

  /// Master switch — when off, the stuck detector is disabled entirely.
  final bool stuckEscalationEnabled;

  const TextAgentConfig({
    this.enabled = false,
    this.provider = TextAgentProvider.openai,
    this.openaiApiKey = '',
    this.claudeApiKey = '',
    this.openaiModel = 'gpt-5.4-mini',
    this.claudeModel = 'claude-sonnet-4-20250514',
    this.customApiKey = '',
    this.customEndpointUrl = '',
    this.customModel = '',
    this.systemPrompt = '',
    this.openaiFallbackModel = 'gpt-5.5',
    this.claudeFallbackModel = 'claude-sonnet-4-20250514',
    this.customFallbackModel = '',
    this.stuckEscalationEnabled = true,
  });

  bool get isConfigured {
    switch (provider) {
      case TextAgentProvider.openai:
        return openaiApiKey.isNotEmpty;
      case TextAgentProvider.claude:
        return claudeApiKey.isNotEmpty;
      case TextAgentProvider.custom:
        return customEndpointUrl.isNotEmpty;
    }
  }

  String get activeApiKey {
    switch (provider) {
      case TextAgentProvider.openai:
        return openaiApiKey;
      case TextAgentProvider.claude:
        return claudeApiKey;
      case TextAgentProvider.custom:
        return customApiKey;
    }
  }

  String get activeModel {
    switch (provider) {
      case TextAgentProvider.openai:
        return openaiModel;
      case TextAgentProvider.claude:
        return claudeModel;
      case TextAgentProvider.custom:
        return customModel;
    }
  }

  /// Active "smarter" fallback model for the current provider, or empty
  /// string when none is configured (disables escalation).
  String get activeFallbackModel {
    switch (provider) {
      case TextAgentProvider.openai:
        return openaiFallbackModel.trim();
      case TextAgentProvider.claude:
        return claudeFallbackModel.trim();
      case TextAgentProvider.custom:
        return customFallbackModel.trim();
    }
  }

  /// True when escalation is enabled AND a distinct fallback model is
  /// configured (i.e. we'd actually swap to a different model).
  bool get canEscalate {
    if (!stuckEscalationEnabled) return false;
    final fb = activeFallbackModel;
    return fb.isNotEmpty && fb != activeModel;
  }

  TextAgentConfig copyWith({
    bool? enabled,
    TextAgentProvider? provider,
    String? openaiApiKey,
    String? claudeApiKey,
    String? openaiModel,
    String? claudeModel,
    String? customApiKey,
    String? customEndpointUrl,
    String? customModel,
    String? systemPrompt,
    String? openaiFallbackModel,
    String? claudeFallbackModel,
    String? customFallbackModel,
    bool? stuckEscalationEnabled,
  }) {
    return TextAgentConfig(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      openaiApiKey: openaiApiKey ?? this.openaiApiKey,
      claudeApiKey: claudeApiKey ?? this.claudeApiKey,
      openaiModel: openaiModel ?? this.openaiModel,
      claudeModel: claudeModel ?? this.claudeModel,
      customApiKey: customApiKey ?? this.customApiKey,
      customEndpointUrl: customEndpointUrl ?? this.customEndpointUrl,
      customModel: customModel ?? this.customModel,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      openaiFallbackModel: openaiFallbackModel ?? this.openaiFallbackModel,
      claudeFallbackModel: claudeFallbackModel ?? this.claudeFallbackModel,
      customFallbackModel: customFallbackModel ?? this.customFallbackModel,
      stuckEscalationEnabled:
          stuckEscalationEnabled ?? this.stuckEscalationEnabled,
    );
  }
}

enum TtsProvider { none, elevenlabs, kokoro, pocketTts }

class TtsConfig {
  final TtsProvider provider;
  final String elevenLabsApiKey;
  final String elevenLabsVoiceId;
  final String elevenLabsModelId;
  final String kokoroVoiceStyle;
  final String pocketTtsVoiceClonePath;
  /// Selected Pocket TTS voice ID from the pocket_tts_voices SQLite table.
  final int? pocketTtsVoiceId;

  const TtsConfig({
    this.provider = TtsProvider.none,
    this.elevenLabsApiKey = '',
    this.elevenLabsVoiceId = '',
    this.elevenLabsModelId = 'eleven_flash_v2_5',
    this.kokoroVoiceStyle = 'af_heart',
    this.pocketTtsVoiceClonePath = '',
    this.pocketTtsVoiceId,
  });

  bool get isConfigured {
    switch (provider) {
      case TtsProvider.none:
        return false;
      case TtsProvider.elevenlabs:
        return elevenLabsApiKey.isNotEmpty && elevenLabsVoiceId.isNotEmpty;
      case TtsProvider.kokoro:
        return true;
      case TtsProvider.pocketTts:
        return true;
    }
  }

  TtsConfig copyWith({
    TtsProvider? provider,
    String? elevenLabsApiKey,
    String? elevenLabsVoiceId,
    String? elevenLabsModelId,
    String? kokoroVoiceStyle,
    String? pocketTtsVoiceClonePath,
    int? pocketTtsVoiceId,
    bool clearPocketTtsVoiceId = false,
  }) {
    return TtsConfig(
      provider: provider ?? this.provider,
      elevenLabsApiKey: elevenLabsApiKey ?? this.elevenLabsApiKey,
      elevenLabsVoiceId: elevenLabsVoiceId ?? this.elevenLabsVoiceId,
      elevenLabsModelId: elevenLabsModelId ?? this.elevenLabsModelId,
      kokoroVoiceStyle: kokoroVoiceStyle ?? this.kokoroVoiceStyle,
      pocketTtsVoiceClonePath: pocketTtsVoiceClonePath ?? this.pocketTtsVoiceClonePath,
      pocketTtsVoiceId: clearPocketTtsVoiceId ? null : (pocketTtsVoiceId ?? this.pocketTtsVoiceId),
    );
  }
}

enum SttProvider { openaiRealtime, whisperKit }

class SttConfig {
  final SttProvider provider;
  final String whisperKitModelSize;
  // Linux only: whether to use GPU acceleration (Vulkan/CUDA) when available.
  // On macOS, WhisperKit always uses the Neural Engine; this flag is ignored.
  final bool whisperKitUseGpu;

  const SttConfig({
    this.provider = SttProvider.openaiRealtime,
    this.whisperKitModelSize = 'base',
    this.whisperKitUseGpu = true,
  });

  SttConfig copyWith({
    SttProvider? provider,
    String? whisperKitModelSize,
    bool? whisperKitUseGpu,
  }) {
    return SttConfig(
      provider: provider ?? this.provider,
      whisperKitModelSize: whisperKitModelSize ?? this.whisperKitModelSize,
      whisperKitUseGpu: whisperKitUseGpu ?? this.whisperKitUseGpu,
    );
  }
}

/// Voice-activity / turn-detection profile for the OpenAI Realtime API.
///
/// `server_vad` profiles map to a (threshold, silenceMs) tuple — `manual`
/// hands control off to the user-tunable values on [VadConfig]. The
/// `semantic*` entries switch to `semantic_vad` and pin a specific
/// `eagerness` so the model decides turn ends contextually.
enum RealtimeVadProfile {
  snappy,
  natural,
  patient,
  manual,
  semanticLow,
  semanticMedium,
  semanticHigh,
  semanticAuto,
}

/// VAD / turn-detection / hallucination knobs.
///
/// Two domains live here intentionally:
///   1. WhisperKit on-device thresholds (`adaptiveNoiseFloor`,
///      `rmsNoiseGate`, `noSpeechThreshold`, `logProbThreshold`,
///      `compressionRatioThreshold`). These get pushed to native
///      `WhisperKitChannel` over a method channel.
///   2. OpenAI Realtime turn-detection (`realtimeProfile` plus the
///      `realtime*` overrides used in `manual` mode). These flow into
///      the `session.update` payload sent to the Realtime API.
///
/// Both pipelines are wired so the user can tune them live from
/// `Settings > Agents > VAD` without restarting the agent.
class VadConfig {
  // ── WhisperKit (on-device) ──
  /// When true, the native side runs a rolling-percentile estimator and
  /// auto-tunes the RMS noise gate to whatever quiet ambient sits at —
  /// keeps the gate firmly above HVAC / fan hum without clipping soft
  /// speech. When false, [rmsNoiseGate] is used verbatim.
  final bool adaptiveNoiseFloor;

  /// Manual RMS gate when [adaptiveNoiseFloor] is off. Typical speech
  /// sits in 0.02–0.10; ambient room noise usually <0.005. Default 0.01
  /// matches the legacy hard-coded value in `WhisperKitChannel.swift`.
  final double rmsNoiseGate;

  /// WhisperKit `DecodingOptions.noSpeechThreshold` — model's
  /// no-speech probability above which the result is dropped. Lower =
  /// stricter. Default 0.4 (vs. WhisperKit upstream 0.6).
  final double noSpeechThreshold;

  /// WhisperKit `DecodingOptions.logProbThreshold` — average token
  /// log-probability below which the result is dropped. Higher (less
  /// negative) = stricter. Default -0.6 (vs. upstream -1.0).
  final double logProbThreshold;

  /// WhisperKit `DecodingOptions.compressionRatioThreshold` — repetition
  /// ratio above which the result is dropped. Lower = stricter. Default
  /// 1.8 (vs. upstream 2.4).
  final double compressionRatioThreshold;

  // ── OpenAI Realtime API ──
  final RealtimeVadProfile realtimeProfile;

  /// Manual `server_vad` threshold (ignored unless profile == manual).
  final double realtimeThreshold;

  /// Manual `server_vad` silence_duration_ms (ignored unless manual).
  final int realtimeSilenceDurationMs;

  /// Manual `server_vad` prefix_padding_ms (ignored unless manual).
  final int realtimePrefixPaddingMs;

  const VadConfig({
    this.adaptiveNoiseFloor = true,
    this.rmsNoiseGate = 0.01,
    this.noSpeechThreshold = 0.4,
    this.logProbThreshold = -0.6,
    this.compressionRatioThreshold = 1.8,
    this.realtimeProfile = RealtimeVadProfile.patient,
    this.realtimeThreshold = 0.8,
    this.realtimeSilenceDurationMs = 1800,
    this.realtimePrefixPaddingMs = 300,
  });

  /// Resolve the profile to a payload suitable for the Realtime API
  /// `session.update.turn_detection` field. Manual mode honours the
  /// `realtime*` fields verbatim.
  Map<String, dynamic> toTurnDetection() {
    switch (realtimeProfile) {
      case RealtimeVadProfile.snappy:
        return {
          'type': 'server_vad',
          'threshold': 0.5,
          'prefix_padding_ms': 300,
          'silence_duration_ms': 500,
        };
      case RealtimeVadProfile.natural:
        return {
          'type': 'server_vad',
          'threshold': 0.6,
          'prefix_padding_ms': 300,
          'silence_duration_ms': 1000,
        };
      case RealtimeVadProfile.patient:
        return {
          'type': 'server_vad',
          'threshold': 0.8,
          'prefix_padding_ms': 300,
          'silence_duration_ms': 1800,
        };
      case RealtimeVadProfile.manual:
        return {
          'type': 'server_vad',
          'threshold': realtimeThreshold,
          'prefix_padding_ms': realtimePrefixPaddingMs,
          'silence_duration_ms': realtimeSilenceDurationMs,
        };
      case RealtimeVadProfile.semanticLow:
        return {'type': 'semantic_vad', 'eagerness': 'low'};
      case RealtimeVadProfile.semanticMedium:
        return {'type': 'semantic_vad', 'eagerness': 'medium'};
      case RealtimeVadProfile.semanticHigh:
        return {'type': 'semantic_vad', 'eagerness': 'high'};
      case RealtimeVadProfile.semanticAuto:
        return {'type': 'semantic_vad', 'eagerness': 'auto'};
    }
  }

  VadConfig copyWith({
    bool? adaptiveNoiseFloor,
    double? rmsNoiseGate,
    double? noSpeechThreshold,
    double? logProbThreshold,
    double? compressionRatioThreshold,
    RealtimeVadProfile? realtimeProfile,
    double? realtimeThreshold,
    int? realtimeSilenceDurationMs,
    int? realtimePrefixPaddingMs,
  }) {
    return VadConfig(
      adaptiveNoiseFloor: adaptiveNoiseFloor ?? this.adaptiveNoiseFloor,
      rmsNoiseGate: rmsNoiseGate ?? this.rmsNoiseGate,
      noSpeechThreshold: noSpeechThreshold ?? this.noSpeechThreshold,
      logProbThreshold: logProbThreshold ?? this.logProbThreshold,
      compressionRatioThreshold:
          compressionRatioThreshold ?? this.compressionRatioThreshold,
      realtimeProfile: realtimeProfile ?? this.realtimeProfile,
      realtimeThreshold: realtimeThreshold ?? this.realtimeThreshold,
      realtimeSilenceDurationMs:
          realtimeSilenceDurationMs ?? this.realtimeSilenceDurationMs,
      realtimePrefixPaddingMs:
          realtimePrefixPaddingMs ?? this.realtimePrefixPaddingMs,
    );
  }
}

/// "Always-on" hands-free mode: the agent listens for a wake phrase even
/// when no call is active. Once triggered, the agent enters a multi-turn
/// conversation session that stays open until either an idle timeout
/// elapses or the user says a close phrase ("thanks", "goodbye", ...).
///
/// Speech in idle mode is captured by the same on-device WhisperKit
/// pipeline used in calls; the only thing this config gates is whether
/// transcripts coming through `_onTranscript` while `_callPhase == idle`
/// are *routed* to the LLM (and answered through Pocket TTS) vs. dropped.
///
/// Wake-phrase aliases are derived dynamically at runtime from the active
/// persona's name (see `AgentBootContext.name`) plus the universal
/// fallback "agent" / "hey agent". That keeps personalisation free —
/// rename a persona to "Kara" and the wake phrase follows automatically.
class IdleConversationConfig {
  /// Master switch for the whole feature. When false the agent behaves
  /// exactly like before (Whisper paused at idle, audio gated).
  ///
  /// When true, WhisperKit stays warm whenever the app is idle so the
  /// wake phrase can be heard. We don't have a dedicated low-power wake
  /// engine yet, so "listen for wake word" and "save CPU between sessions"
  /// are mutually exclusive — we deliberately choose reliability.
  final bool enabled;

  /// How long the conversation session stays open after the last user or
  /// agent utterance. Reset on every transcript / TTS turn. When this
  /// elapses the session closes silently and we go back to wake-word mode.
  final int sessionTimeoutSeconds;

  /// Whether the agent should speak its replies through Pocket TTS while
  /// in an idle session. When false the response only appears in the
  /// chat panel — useful as a desktop dictation/assistant surface.
  final bool speakInIdle;

  /// Whether to also accept a generic "agent" / "hey agent" wake phrase
  /// in addition to the persona's name. Off → strict, persona-name only.
  final bool acceptGenericAlias;

  const IdleConversationConfig({
    this.enabled = false,
    this.sessionTimeoutSeconds = 60,
    this.speakInIdle = true,
    this.acceptGenericAlias = true,
  });

  IdleConversationConfig copyWith({
    bool? enabled,
    int? sessionTimeoutSeconds,
    bool? speakInIdle,
    bool? acceptGenericAlias,
  }) {
    return IdleConversationConfig(
      enabled: enabled ?? this.enabled,
      sessionTimeoutSeconds:
          sessionTimeoutSeconds ?? this.sessionTimeoutSeconds,
      speakInIdle: speakInIdle ?? this.speakInIdle,
      acceptGenericAlias: acceptGenericAlias ?? this.acceptGenericAlias,
    );
  }

  @override
  String toString() =>
      'IdleConversationConfig(enabled=$enabled, window=${sessionTimeoutSeconds}s, '
      'speakInIdle=$speakInIdle, acceptGenericAlias=$acceptGenericAlias)';
}

class CallRecordingConfig {
  final bool autoRecord;

  const CallRecordingConfig({this.autoRecord = false});

  CallRecordingConfig copyWith({bool? autoRecord}) {
    return CallRecordingConfig(autoRecord: autoRecord ?? this.autoRecord);
  }
}

class ComfortNoiseConfig {
  final bool enabled;
  final double volume;
  final String? selectedPath;

  const ComfortNoiseConfig({
    this.enabled = false,
    this.volume = 0.3,
    this.selectedPath,
  });

  ComfortNoiseConfig copyWith({
    bool? enabled,
    double? volume,
    String? selectedPath,
    bool clearPath = false,
  }) {
    return ComfortNoiseConfig(
      enabled: enabled ?? this.enabled,
      volume: volume ?? this.volume,
      selectedPath: clearPath ? null : (selectedPath ?? this.selectedPath),
    );
  }
}

class AgentConfigService {
  static const _prefix = 'agent_';

  static const validRealtimeModels = {
    'gpt-4o-mini-realtime-preview',
    'gpt-4o-realtime-preview',
  };

  static const validVoices = {
    'coral',
    'alloy',
    'ash',
    'ballad',
    'echo',
    'sage',
    'shimmer',
    'verse',
    'marin',
    'cedar',
  };

  static String get defaultInstructions => AgentBootContext.trivia().toInstructions();

  static String _migrateModel(String? stored) {
    if (stored == null || !validRealtimeModels.contains(stored)) {
      return 'gpt-4o-mini-realtime-preview';
    }
    return stored;
  }

  static const _validClaudeModels = {
    'claude-sonnet-4-20250514',
    'claude-haiku-4-5-20251001',
  };

  static String _migrateClaudeModel(String? stored) {
    if (stored == null || !_validClaudeModels.contains(stored)) {
      return 'claude-sonnet-4-20250514';
    }
    return stored;
  }

  static String _migrateVoice(String? stored) {
    if (stored == null || !validVoices.contains(stored)) {
      return 'coral';
    }
    return stored;
  }

  static Future<VoiceAgentConfig> loadVoiceConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return VoiceAgentConfig(
      enabled: prefs.getBool('${_prefix}voice_enabled') ?? false,
      apiKey: prefs.getString('${_prefix}voice_api_key') ?? '',
      model: _migrateModel(prefs.getString('${_prefix}voice_model')),
      voice: _migrateVoice(prefs.getString('${_prefix}voice_voice')),
      instructions: prefs.getString('${_prefix}voice_instructions') ?? '',
      target: TranscriptionTarget.values[
          prefs.getInt('${_prefix}voice_target') ?? 0],
      echoGuardMs: prefs.getInt('${_prefix}voice_echo_guard_ms') ?? 2500,
    );
  }

  static Future<void> saveVoiceConfig(VoiceAgentConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}voice_enabled', config.enabled);
    await prefs.setString('${_prefix}voice_api_key', config.apiKey);
    await prefs.setString('${_prefix}voice_model', config.model);
    await prefs.setString('${_prefix}voice_voice', config.voice);
    await prefs.setString('${_prefix}voice_instructions', config.instructions);
    await prefs.setInt('${_prefix}voice_target', config.target.index);
    await prefs.setInt('${_prefix}voice_echo_guard_ms', config.echoGuardMs);
  }

  static Future<TextAgentConfig> loadTextConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final providerIdx = prefs.getInt('${_prefix}text_provider') ?? 0;
    return TextAgentConfig(
      enabled: prefs.getBool('${_prefix}text_enabled') ?? false,
      provider: TextAgentProvider.values[
          providerIdx.clamp(0, TextAgentProvider.values.length - 1)],
      openaiApiKey: prefs.getString('${_prefix}text_openai_key') ?? '',
      claudeApiKey: prefs.getString('${_prefix}text_claude_key') ?? '',
      openaiModel:
          prefs.getString('${_prefix}text_openai_model') ?? 'gpt-5.4-mini',
      claudeModel: _migrateClaudeModel(
          prefs.getString('${_prefix}text_claude_model')),
      customApiKey: prefs.getString('${_prefix}text_custom_key') ?? '',
      customEndpointUrl:
          prefs.getString('${_prefix}text_custom_endpoint') ?? '',
      customModel: prefs.getString('${_prefix}text_custom_model') ?? '',
      systemPrompt: prefs.getString('${_prefix}text_system_prompt') ?? '',
      openaiFallbackModel:
          prefs.getString('${_prefix}text_openai_fallback_model') ??
              'gpt-5.5',
      claudeFallbackModel:
          prefs.getString('${_prefix}text_claude_fallback_model') ??
              'claude-sonnet-4-20250514',
      customFallbackModel:
          prefs.getString('${_prefix}text_custom_fallback_model') ?? '',
      stuckEscalationEnabled:
          prefs.getBool('${_prefix}text_stuck_escalation_enabled') ?? true,
    );
  }

  static Future<void> saveTextConfig(TextAgentConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}text_enabled', config.enabled);
    await prefs.setInt('${_prefix}text_provider', config.provider.index);
    await prefs.setString('${_prefix}text_openai_key', config.openaiApiKey);
    await prefs.setString('${_prefix}text_claude_key', config.claudeApiKey);
    await prefs.setString('${_prefix}text_openai_model', config.openaiModel);
    await prefs.setString('${_prefix}text_claude_model', config.claudeModel);
    await prefs.setString('${_prefix}text_custom_key', config.customApiKey);
    await prefs.setString(
        '${_prefix}text_custom_endpoint', config.customEndpointUrl);
    await prefs.setString('${_prefix}text_custom_model', config.customModel);
    await prefs.setString(
        '${_prefix}text_system_prompt', config.systemPrompt);
    await prefs.setString('${_prefix}text_openai_fallback_model',
        config.openaiFallbackModel);
    await prefs.setString('${_prefix}text_claude_fallback_model',
        config.claudeFallbackModel);
    await prefs.setString('${_prefix}text_custom_fallback_model',
        config.customFallbackModel);
    await prefs.setBool('${_prefix}text_stuck_escalation_enabled',
        config.stuckEscalationEnabled);
  }

  static Future<TtsConfig> loadTtsConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final providerIdx = prefs.getInt('${_prefix}tts_provider') ?? 0;
    final pocketVoiceId = prefs.getInt('${_prefix}tts_pocket_voice_id');
    return TtsConfig(
      provider: TtsProvider
          .values[providerIdx.clamp(0, TtsProvider.values.length - 1)],
      elevenLabsApiKey:
          prefs.getString('${_prefix}tts_elevenlabs_key') ?? '',
      elevenLabsVoiceId:
          prefs.getString('${_prefix}tts_elevenlabs_voice_id') ?? '',
      elevenLabsModelId:
          prefs.getString('${_prefix}tts_elevenlabs_model') ??
              'eleven_flash_v2_5',
      kokoroVoiceStyle:
          prefs.getString('${_prefix}tts_kokoro_voice') ?? 'af_heart',
      pocketTtsVoiceClonePath:
          prefs.getString('${_prefix}tts_pocket_clone_path') ?? '',
      pocketTtsVoiceId: pocketVoiceId,
    );
  }

  static Future<void> saveTtsConfig(TtsConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}tts_provider', config.provider.index);
    await prefs.setString(
        '${_prefix}tts_elevenlabs_key', config.elevenLabsApiKey);
    await prefs.setString(
        '${_prefix}tts_elevenlabs_voice_id', config.elevenLabsVoiceId);
    await prefs.setString(
        '${_prefix}tts_elevenlabs_model', config.elevenLabsModelId);
    await prefs.setString(
        '${_prefix}tts_kokoro_voice', config.kokoroVoiceStyle);
    await prefs.setString(
        '${_prefix}tts_pocket_clone_path', config.pocketTtsVoiceClonePath);
    if (config.pocketTtsVoiceId != null) {
      await prefs.setInt(
          '${_prefix}tts_pocket_voice_id', config.pocketTtsVoiceId!);
    } else {
      await prefs.remove('${_prefix}tts_pocket_voice_id');
    }
  }

  // -- STT config (on-device WhisperKit) -------------------------------------

  static Future<SttConfig> loadSttConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final providerIdx = prefs.getInt('${_prefix}stt_provider') ?? 0;
    return SttConfig(
      provider: SttProvider
          .values[providerIdx.clamp(0, SttProvider.values.length - 1)],
      whisperKitModelSize:
          prefs.getString('${_prefix}stt_whisperkit_model') ?? 'base',
      whisperKitUseGpu:
          prefs.getBool('${_prefix}stt_whisperkit_use_gpu') ?? true,
    );
  }

  static Future<void> saveSttConfig(SttConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}stt_provider', config.provider.index);
    await prefs.setString(
        '${_prefix}stt_whisperkit_model', config.whisperKitModelSize);
    await prefs.setBool(
        '${_prefix}stt_whisperkit_use_gpu', config.whisperKitUseGpu);
  }

  static Future<CallRecordingConfig> loadCallRecordingConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return CallRecordingConfig(
      autoRecord: prefs.getBool('${_prefix}call_auto_record') ?? false,
    );
  }

  static Future<void> saveCallRecordingConfig(
      CallRecordingConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}call_auto_record', config.autoRecord);
  }

  static Future<AgentMutePolicy> loadMutePolicy() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt('${_prefix}mute_policy') ?? 0;
    return AgentMutePolicy.values[idx.clamp(0, AgentMutePolicy.values.length - 1)];
  }

  static Future<void> saveMutePolicy(AgentMutePolicy policy) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}mute_policy', policy.index);
  }

  // -- VAD / turn-detection / hallucination thresholds -----------------------

  static Future<VadConfig> loadVadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final profileIdx = prefs.getInt('${_prefix}vad_realtime_profile') ??
        RealtimeVadProfile.patient.index;
    return VadConfig(
      adaptiveNoiseFloor:
          prefs.getBool('${_prefix}vad_adaptive_noise_floor') ?? true,
      rmsNoiseGate: prefs.getDouble('${_prefix}vad_rms_noise_gate') ?? 0.01,
      noSpeechThreshold:
          prefs.getDouble('${_prefix}vad_no_speech_threshold') ?? 0.4,
      logProbThreshold:
          prefs.getDouble('${_prefix}vad_log_prob_threshold') ?? -0.6,
      compressionRatioThreshold:
          prefs.getDouble('${_prefix}vad_compression_ratio_threshold') ?? 1.8,
      realtimeProfile: RealtimeVadProfile.values[
          profileIdx.clamp(0, RealtimeVadProfile.values.length - 1)],
      realtimeThreshold:
          prefs.getDouble('${_prefix}vad_realtime_threshold') ?? 0.8,
      realtimeSilenceDurationMs:
          prefs.getInt('${_prefix}vad_realtime_silence_ms') ?? 1800,
      realtimePrefixPaddingMs:
          prefs.getInt('${_prefix}vad_realtime_prefix_ms') ?? 300,
    );
  }

  static Future<void> saveVadConfig(VadConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        '${_prefix}vad_adaptive_noise_floor', config.adaptiveNoiseFloor);
    await prefs.setDouble(
        '${_prefix}vad_rms_noise_gate', config.rmsNoiseGate);
    await prefs.setDouble(
        '${_prefix}vad_no_speech_threshold', config.noSpeechThreshold);
    await prefs.setDouble(
        '${_prefix}vad_log_prob_threshold', config.logProbThreshold);
    await prefs.setDouble('${_prefix}vad_compression_ratio_threshold',
        config.compressionRatioThreshold);
    await prefs.setInt(
        '${_prefix}vad_realtime_profile', config.realtimeProfile.index);
    await prefs.setDouble(
        '${_prefix}vad_realtime_threshold', config.realtimeThreshold);
    await prefs.setInt('${_prefix}vad_realtime_silence_ms',
        config.realtimeSilenceDurationMs);
    await prefs.setInt('${_prefix}vad_realtime_prefix_ms',
        config.realtimePrefixPaddingMs);
  }

  // -- Idle conversation (wake-word + session) -------------------------------

  static Future<IdleConversationConfig> loadIdleConversationConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return IdleConversationConfig(
      enabled: prefs.getBool('${_prefix}idle_conv_enabled') ?? false,
      sessionTimeoutSeconds:
          prefs.getInt('${_prefix}idle_conv_session_timeout_s') ?? 60,
      speakInIdle: prefs.getBool('${_prefix}idle_conv_speak') ?? true,
      acceptGenericAlias:
          prefs.getBool('${_prefix}idle_conv_accept_generic') ?? true,
    );
  }

  static Future<void> saveIdleConversationConfig(
      IdleConversationConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}idle_conv_enabled', config.enabled);
    await prefs.setInt('${_prefix}idle_conv_session_timeout_s',
        config.sessionTimeoutSeconds);
    await prefs.setBool('${_prefix}idle_conv_speak', config.speakInIdle);
    await prefs.setBool(
        '${_prefix}idle_conv_accept_generic', config.acceptGenericAlias);
    // Legacy 'idle_conv_pause_between' key is intentionally ignored — the
    // option was removed because pausing Whisper between sessions makes
    // the wake word undetectable.
  }

  // -- Comfort noise config ---------------------------------------------------

  static Future<ComfortNoiseConfig> loadComfortNoiseConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return ComfortNoiseConfig(
      enabled: prefs.getBool('${_prefix}comfort_noise_enabled') ?? false,
      volume: prefs.getDouble('${_prefix}comfort_noise_volume') ?? 0.3,
      selectedPath: prefs.getString('${_prefix}comfort_noise_path'),
    );
  }

  static Future<void> saveComfortNoiseConfig(ComfortNoiseConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}comfort_noise_enabled', config.enabled);
    await prefs.setDouble('${_prefix}comfort_noise_volume', config.volume);
    if (config.selectedPath != null) {
      await prefs.setString(
          '${_prefix}comfort_noise_path', config.selectedPath!);
    } else {
      await prefs.remove('${_prefix}comfort_noise_path');
    }
  }

  // -- Conference config ------------------------------------------------------

  static Future<ConferenceConfig> loadConferenceConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt('${_prefix}conf_provider') ?? 0;
    return ConferenceConfig(
      provider: ConferenceProviderType
          .values[idx.clamp(0, ConferenceProviderType.values.length - 1)],
      maxParticipants:
          prefs.getInt('${_prefix}conf_max_participants') ?? 5,
      basicSupportsUpdate:
          prefs.getBool('${_prefix}conf_basic_supports_update') ?? false,
      basicRenegotiateMedia:
          prefs.getBool('${_prefix}conf_basic_renegotiate_media') ?? false,
    );
  }

  static Future<void> saveConferenceConfig(ConferenceConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}conf_provider', config.provider.index);
    await prefs.setInt(
        '${_prefix}conf_max_participants', config.maxParticipants);
    await prefs.setBool(
        '${_prefix}conf_basic_supports_update', config.basicSupportsUpdate);
    await prefs.setBool('${_prefix}conf_basic_renegotiate_media',
        config.basicRenegotiateMedia);
  }

  // -- GitHub config -----------------------------------------------------------

  static const gitHubRepo = 'reduxdj/phonegentic';

  static Future<String> loadGitHubToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefix}github_token') ?? '';
  }

  static Future<void> saveGitHubToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}github_token', token);
  }
}
