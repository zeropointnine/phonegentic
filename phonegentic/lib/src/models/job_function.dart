import 'dart:convert';

class SpeakerDef {
  final String role;
  final String source;

  const SpeakerDef({required this.role, required this.source});

  Map<String, dynamic> toMap() => {'role': role, 'source': source};

  factory SpeakerDef.fromMap(Map<String, dynamic> map) => SpeakerDef(
        role: map['role'] as String? ?? '',
        source: map['source'] as String? ?? '',
      );

  SpeakerDef copyWith({String? role, String? source}) => SpeakerDef(
        role: role ?? this.role,
        source: source ?? this.source,
      );

  static const defaultSpeakers = [
    SpeakerDef(role: 'Host', source: 'mic'),
    SpeakerDef(role: 'Remote Party 1', source: 'remote'),
  ];
}

class JobFunction {
  final int? id;
  final String title;
  final String? agentName;
  final String role;
  final String jobDescription;
  final List<SpeakerDef> speakers;
  final List<String> guardrails;
  final bool whisperByDefault;
  final String? elevenLabsVoiceId;
  final String? kokoroVoiceStyle;
  final int? pocketTtsVoiceId;
  /// Per-job mute policy override. null = use global setting.
  /// 0 = autoToggle, 1 = stayMuted, 2 = stayUnmuted (matches AgentMutePolicy.index).
  final int? mutePolicyOverride;
  /// Per-job comfort noise override. null = use global, non-empty path = use file.
  final String? comfortNoisePath;

  /// When a second call arrives while on a call, make the toast's primary
  /// Answer button default to Hold-Current+Answer (rather than Hangup+Answer).
  final bool autoAnswerAndHold;

  /// When the manager is away and a second inbound arrives, auto-send the
  /// [awaySmsTemplate] SMS to the caller and decline the leg (no toast).
  final bool respondBySmsWhenAway;

  /// When the user picks Hold+Answer in the toast, have the agent briefly
  /// speak a polite hold notice on the primary call before hold is applied.
  final bool speakPoliteHoldNotice;

  /// SMS template used when [respondBySmsWhenAway] is on.
  /// Null means "use the built-in default".
  final String? awaySmsTemplate;

  final DateTime createdAt;
  final DateTime updatedAt;

  static const String defaultAwaySmsTemplate =
      "I'm on another call right now, I'll call you back shortly.";

  JobFunction({
    this.id,
    required this.title,
    this.agentName,
    this.role = 'You are a voice AI agent participating in a 3-party phone call.',
    required this.jobDescription,
    List<SpeakerDef>? speakers,
    List<String>? guardrails,
    this.whisperByDefault = false,
    this.elevenLabsVoiceId,
    this.kokoroVoiceStyle,
    this.pocketTtsVoiceId,
    this.mutePolicyOverride,
    this.comfortNoisePath,
    this.autoAnswerAndHold = false,
    this.respondBySmsWhenAway = false,
    this.speakPoliteHoldNotice = false,
    this.awaySmsTemplate,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : speakers = speakers ?? List.of(SpeakerDef.defaultSpeakers),
        guardrails = guardrails ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  JobFunction copyWith({
    int? id,
    String? title,
    String? agentName,
    bool clearAgentName = false,
    String? role,
    String? jobDescription,
    List<SpeakerDef>? speakers,
    List<String>? guardrails,
    bool? whisperByDefault,
    String? elevenLabsVoiceId,
    String? kokoroVoiceStyle,
    bool clearKokoroVoice = false,
    int? pocketTtsVoiceId,
    bool clearPocketTtsVoice = false,
    int? mutePolicyOverride,
    bool clearMutePolicy = false,
    String? comfortNoisePath,
    bool clearComfortNoise = false,
    bool? autoAnswerAndHold,
    bool? respondBySmsWhenAway,
    bool? speakPoliteHoldNotice,
    String? awaySmsTemplate,
    bool clearAwaySmsTemplate = false,
    DateTime? updatedAt,
  }) =>
      JobFunction(
        id: id ?? this.id,
        title: title ?? this.title,
        agentName: clearAgentName ? null : (agentName ?? this.agentName),
        role: role ?? this.role,
        jobDescription: jobDescription ?? this.jobDescription,
        speakers: speakers ?? this.speakers,
        guardrails: guardrails ?? this.guardrails,
        whisperByDefault: whisperByDefault ?? this.whisperByDefault,
        elevenLabsVoiceId: elevenLabsVoiceId ?? this.elevenLabsVoiceId,
        kokoroVoiceStyle: clearKokoroVoice ? null : (kokoroVoiceStyle ?? this.kokoroVoiceStyle),
        pocketTtsVoiceId: clearPocketTtsVoice ? null : (pocketTtsVoiceId ?? this.pocketTtsVoiceId),
        mutePolicyOverride: clearMutePolicy ? null : (mutePolicyOverride ?? this.mutePolicyOverride),
        comfortNoisePath: clearComfortNoise ? null : (comfortNoisePath ?? this.comfortNoisePath),
        autoAnswerAndHold: autoAnswerAndHold ?? this.autoAnswerAndHold,
        respondBySmsWhenAway: respondBySmsWhenAway ?? this.respondBySmsWhenAway,
        speakPoliteHoldNotice:
            speakPoliteHoldNotice ?? this.speakPoliteHoldNotice,
        awaySmsTemplate: clearAwaySmsTemplate
            ? null
            : (awaySmsTemplate ?? this.awaySmsTemplate),
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': title,
        'agent_name': agentName,
        'role': role,
        'job_description': jobDescription,
        'speakers_json': jsonEncode(speakers.map((s) => s.toMap()).toList()),
        'guardrails_json': jsonEncode(guardrails),
        'whisper_by_default': whisperByDefault ? 1 : 0,
        'elevenlabs_voice_id': elevenLabsVoiceId,
        'kokoro_voice_style': kokoroVoiceStyle,
        'pocket_tts_voice_id': pocketTtsVoiceId,
        'mute_policy_override': mutePolicyOverride,
        'comfort_noise_path': comfortNoisePath,
        'auto_answer_and_hold': autoAnswerAndHold ? 1 : 0,
        'respond_by_sms_when_away': respondBySmsWhenAway ? 1 : 0,
        'speak_polite_hold_notice': speakPoliteHoldNotice ? 1 : 0,
        'away_sms_template': awaySmsTemplate,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory JobFunction.fromMap(Map<String, dynamic> map) {
    final speakersRaw = map['speakers_json'] as String? ?? '[]';
    final guardrailsRaw = map['guardrails_json'] as String? ?? '[]';

    return JobFunction(
      id: map['id'] as int?,
      title: map['name'] as String? ?? '',
      agentName: map['agent_name'] as String?,
      role: map['role'] as String? ??
          'You are a voice AI agent participating in a 3-party phone call.',
      jobDescription: map['job_description'] as String? ?? '',
      speakers: (jsonDecode(speakersRaw) as List)
          .map((e) => SpeakerDef.fromMap(e as Map<String, dynamic>))
          .toList(),
      guardrails: (jsonDecode(guardrailsRaw) as List).cast<String>(),
      whisperByDefault: (map['whisper_by_default'] as int? ?? 0) == 1,
      elevenLabsVoiceId: map['elevenlabs_voice_id'] as String?,
      kokoroVoiceStyle: map['kokoro_voice_style'] as String?,
      pocketTtsVoiceId: map['pocket_tts_voice_id'] as int?,
      mutePolicyOverride: map['mute_policy_override'] as int?,
      comfortNoisePath: map['comfort_noise_path'] as String?,
      autoAnswerAndHold: (map['auto_answer_and_hold'] as int? ?? 0) == 1,
      respondBySmsWhenAway: (map['respond_by_sms_when_away'] as int? ?? 0) == 1,
      speakPoliteHoldNotice: (map['speak_polite_hold_notice'] as int? ?? 0) == 1,
      awaySmsTemplate: map['away_sms_template'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static JobFunction triviaDefault() => JobFunction(
        title: 'Trivia Host',
        role: 'You are a voice AI agent participating in a 3-party phone call.',
        jobDescription:
            'Host a 3-party trivia game with 3 easy questions. Keep score. Award the winner.',
        guardrails: [
          'Stay in character as the trivia host.',
          'Keep questions family-friendly and easy.',
          'Announce scores after each question.',
          'Declare a winner after all 3 questions.',
        ],
      );
}
