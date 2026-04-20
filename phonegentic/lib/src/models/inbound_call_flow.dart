import 'dart:convert';

class InboundRule {
  final int jobFunctionId;
  final List<String> phonePatterns;

  const InboundRule({
    required this.jobFunctionId,
    List<String>? phonePatterns,
  }) : phonePatterns = phonePatterns ?? const ['*'];

  Map<String, dynamic> toMap() => {
        'job_function_id': jobFunctionId,
        'phone_patterns': phonePatterns,
      };

  factory InboundRule.fromMap(Map<String, dynamic> map) => InboundRule(
        jobFunctionId: map['job_function_id'] as int? ?? 0,
        phonePatterns:
            (map['phone_patterns'] as List?)?.cast<String>() ?? const ['*'],
      );

  bool matches(String callerNumber) {
    for (final pattern in phonePatterns) {
      if (pattern == '*') return true;
      if (pattern == callerNumber) return true;
    }
    return false;
  }
}

class InboundCallFlow {
  final int? id;
  final String name;
  final bool enabled;
  final List<InboundRule> rules;
  final DateTime createdAt;
  final DateTime updatedAt;

  InboundCallFlow({
    this.id,
    required this.name,
    this.enabled = true,
    List<InboundRule>? rules,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : rules = rules ?? const [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  InboundCallFlow copyWith({
    int? id,
    String? name,
    bool? enabled,
    List<InboundRule>? rules,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      InboundCallFlow(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        rules: rules ?? this.rules,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'enabled': enabled ? 1 : 0,
        'rules_json': jsonEncode(rules.map((r) => r.toMap()).toList()),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory InboundCallFlow.fromMap(Map<String, dynamic> map) {
    final rulesRaw = map['rules_json'] as String? ?? '[]';
    return InboundCallFlow(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      enabled: (map['enabled'] as int? ?? 1) == 1,
      rules: (jsonDecode(rulesRaw) as List)
          .map((e) => InboundRule.fromMap(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
