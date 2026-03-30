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
  final String name;
  final String role;
  final String jobDescription;
  final List<SpeakerDef> speakers;
  final List<String> guardrails;
  final bool whisperByDefault;
  final String? elevenLabsVoiceId;
  final DateTime createdAt;
  final DateTime updatedAt;

  JobFunction({
    this.id,
    required this.name,
    this.role = 'You are a voice AI agent participating in a 3-party phone call.',
    required this.jobDescription,
    List<SpeakerDef>? speakers,
    List<String>? guardrails,
    this.whisperByDefault = false,
    this.elevenLabsVoiceId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : speakers = speakers ?? List.of(SpeakerDef.defaultSpeakers),
        guardrails = guardrails ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  JobFunction copyWith({
    int? id,
    String? name,
    String? role,
    String? jobDescription,
    List<SpeakerDef>? speakers,
    List<String>? guardrails,
    bool? whisperByDefault,
    String? elevenLabsVoiceId,
    DateTime? updatedAt,
  }) =>
      JobFunction(
        id: id ?? this.id,
        name: name ?? this.name,
        role: role ?? this.role,
        jobDescription: jobDescription ?? this.jobDescription,
        speakers: speakers ?? this.speakers,
        guardrails: guardrails ?? this.guardrails,
        whisperByDefault: whisperByDefault ?? this.whisperByDefault,
        elevenLabsVoiceId: elevenLabsVoiceId ?? this.elevenLabsVoiceId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'role': role,
        'job_description': jobDescription,
        'speakers_json': jsonEncode(speakers.map((s) => s.toMap()).toList()),
        'guardrails_json': jsonEncode(guardrails),
        'whisper_by_default': whisperByDefault ? 1 : 0,
        'elevenlabs_voice_id': elevenLabsVoiceId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory JobFunction.fromMap(Map<String, dynamic> map) {
    final speakersRaw = map['speakers_json'] as String? ?? '[]';
    final guardrailsRaw = map['guardrails_json'] as String? ?? '[]';

    return JobFunction(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      role: map['role'] as String? ??
          'You are a voice AI agent participating in a 3-party phone call.',
      jobDescription: map['job_description'] as String? ?? '',
      speakers: (jsonDecode(speakersRaw) as List)
          .map((e) => SpeakerDef.fromMap(e as Map<String, dynamic>))
          .toList(),
      guardrails: (jsonDecode(guardrailsRaw) as List).cast<String>(),
      whisperByDefault: (map['whisper_by_default'] as int? ?? 0) == 1,
      elevenLabsVoiceId: map['elevenlabs_voice_id'] as String?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static JobFunction triviaDefault() => JobFunction(
        name: 'Trivia Host',
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
