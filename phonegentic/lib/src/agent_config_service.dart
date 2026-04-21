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

  const TextAgentConfig({
    this.enabled = false,
    this.provider = TextAgentProvider.openai,
    this.openaiApiKey = '',
    this.claudeApiKey = '',
    this.openaiModel = 'gpt-4o',
    this.claudeModel = 'claude-sonnet-4-20250514',
    this.customApiKey = '',
    this.customEndpointUrl = '',
    this.customModel = '',
    this.systemPrompt = '',
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
          prefs.getString('${_prefix}text_openai_model') ?? 'gpt-4o',
      claudeModel: _migrateClaudeModel(
          prefs.getString('${_prefix}text_claude_model')),
      customApiKey: prefs.getString('${_prefix}text_custom_key') ?? '',
      customEndpointUrl:
          prefs.getString('${_prefix}text_custom_endpoint') ?? '',
      customModel: prefs.getString('${_prefix}text_custom_model') ?? '',
      systemPrompt: prefs.getString('${_prefix}text_system_prompt') ?? '',
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
