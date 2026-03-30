import 'package:shared_preferences/shared_preferences.dart';

import 'models/agent_context.dart';

enum TextAgentProvider { openai, claude }

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
  final String systemPrompt;

  const TextAgentConfig({
    this.enabled = false,
    this.provider = TextAgentProvider.openai,
    this.openaiApiKey = '',
    this.claudeApiKey = '',
    this.openaiModel = 'gpt-4o',
    this.claudeModel = 'claude-sonnet-4-20250514',
    this.systemPrompt = '',
  });

  bool get isConfigured {
    if (provider == TextAgentProvider.openai) return openaiApiKey.isNotEmpty;
    return claudeApiKey.isNotEmpty;
  }

  String get activeApiKey =>
      provider == TextAgentProvider.openai ? openaiApiKey : claudeApiKey;

  String get activeModel =>
      provider == TextAgentProvider.openai ? openaiModel : claudeModel;

  TextAgentConfig copyWith({
    bool? enabled,
    TextAgentProvider? provider,
    String? openaiApiKey,
    String? claudeApiKey,
    String? openaiModel,
    String? claudeModel,
    String? systemPrompt,
  }) {
    return TextAgentConfig(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      openaiApiKey: openaiApiKey ?? this.openaiApiKey,
      claudeApiKey: claudeApiKey ?? this.claudeApiKey,
      openaiModel: openaiModel ?? this.openaiModel,
      claudeModel: claudeModel ?? this.claudeModel,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }
}

enum TtsProvider { none, elevenlabs }

class TtsConfig {
  final TtsProvider provider;
  final String elevenLabsApiKey;
  final String elevenLabsVoiceId;
  final String elevenLabsModelId;

  const TtsConfig({
    this.provider = TtsProvider.none,
    this.elevenLabsApiKey = '',
    this.elevenLabsVoiceId = '',
    this.elevenLabsModelId = 'eleven_flash_v2_5',
  });

  bool get isConfigured {
    if (provider == TtsProvider.none) return false;
    return elevenLabsApiKey.isNotEmpty && elevenLabsVoiceId.isNotEmpty;
  }

  TtsConfig copyWith({
    TtsProvider? provider,
    String? elevenLabsApiKey,
    String? elevenLabsVoiceId,
    String? elevenLabsModelId,
  }) {
    return TtsConfig(
      provider: provider ?? this.provider,
      elevenLabsApiKey: elevenLabsApiKey ?? this.elevenLabsApiKey,
      elevenLabsVoiceId: elevenLabsVoiceId ?? this.elevenLabsVoiceId,
      elevenLabsModelId: elevenLabsModelId ?? this.elevenLabsModelId,
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
    return TextAgentConfig(
      enabled: prefs.getBool('${_prefix}text_enabled') ?? false,
      provider: TextAgentProvider.values[
          prefs.getInt('${_prefix}text_provider') ?? 0],
      openaiApiKey: prefs.getString('${_prefix}text_openai_key') ?? '',
      claudeApiKey: prefs.getString('${_prefix}text_claude_key') ?? '',
      openaiModel:
          prefs.getString('${_prefix}text_openai_model') ?? 'gpt-4o',
      claudeModel: prefs.getString('${_prefix}text_claude_model') ??
          'claude-sonnet-4-20250514',
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
    await prefs.setString(
        '${_prefix}text_system_prompt', config.systemPrompt);
  }

  static Future<TtsConfig> loadTtsConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return TtsConfig(
      provider: TtsProvider
          .values[prefs.getInt('${_prefix}tts_provider') ?? 0],
      elevenLabsApiKey:
          prefs.getString('${_prefix}tts_elevenlabs_key') ?? '',
      elevenLabsVoiceId:
          prefs.getString('${_prefix}tts_elevenlabs_voice_id') ?? '',
      elevenLabsModelId:
          prefs.getString('${_prefix}tts_elevenlabs_model') ??
              'eleven_flash_v2_5',
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
}
