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
  /// Per-job mute policy override. null = use global setting.
  /// 0 = autoToggle, 1 = stayMuted, 2 = stayUnmuted (matches AgentMutePolicy.index).
  final int? mutePolicyOverride;
  final DateTime createdAt;
  final DateTime updatedAt;

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
    this.mutePolicyOverride,
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
    int? mutePolicyOverride,
    bool clearMutePolicy = false,
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
        mutePolicyOverride: clearMutePolicy ? null : (mutePolicyOverride ?? this.mutePolicyOverride),
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
        'mute_policy_override': mutePolicyOverride,
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
      mutePolicyOverride: map['mute_policy_override'] as int?,
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
