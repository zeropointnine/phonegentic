import 'dart:convert';

class TransferRule {
  final int? id;
  final String name;
  final bool enabled;
  final List<String> callerPatterns;
  final String transferTarget;
  final bool silent;
  final int? jobFunctionId;
  final DateTime createdAt;
  final DateTime updatedAt;

  TransferRule({
    this.id,
    required this.name,
    this.enabled = true,
    List<String>? callerPatterns,
    required this.transferTarget,
    this.silent = false,
    this.jobFunctionId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : callerPatterns = callerPatterns ?? const ['*'],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  TransferRule copyWith({
    int? id,
    String? name,
    bool? enabled,
    List<String>? callerPatterns,
    String? transferTarget,
    bool? silent,
    int? Function()? jobFunctionId,
    DateTime? updatedAt,
  }) =>
      TransferRule(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        callerPatterns: callerPatterns ?? this.callerPatterns,
        transferTarget: transferTarget ?? this.transferTarget,
        silent: silent ?? this.silent,
        jobFunctionId:
            jobFunctionId != null ? jobFunctionId() : this.jobFunctionId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'enabled': enabled ? 1 : 0,
        'caller_patterns': jsonEncode(callerPatterns),
        'transfer_target': transferTarget,
        'silent': silent ? 1 : 0,
        'job_function_id': jobFunctionId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory TransferRule.fromMap(Map<String, dynamic> map) {
    final patternsRaw = map['caller_patterns'] as String? ?? '["*"]';
    return TransferRule(
      id: map['id'] as int?,
      name: map['name'] as String? ?? '',
      enabled: (map['enabled'] as int? ?? 1) == 1,
      callerPatterns: (jsonDecode(patternsRaw) as List).cast<String>(),
      transferTarget: map['transfer_target'] as String? ?? '',
      silent: (map['silent'] as int? ?? 0) == 1,
      jobFunctionId: map['job_function_id'] as int?,
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// Returns true if [callerNumber] matches any of the caller patterns.
  bool matches(String callerNumber) {
    for (final pattern in callerPatterns) {
      if (pattern == '*') return true;
      if (pattern == callerNumber) return true;
    }
    return false;
  }

  String toSummary() {
    final patternStr = callerPatterns.join(', ');
    final silentStr = silent ? ' (silent)' : '';
    return '"$name": [$patternStr] → $transferTarget$silentStr';
  }
}
