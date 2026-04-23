import 'dart:convert';

enum SmsDirection { inbound, outbound }

enum SmsStatus { queued, sent, delivered, failed, received }

/// A single reaction "hit" on a message: who added it, and when.
class SmsReactor {
  /// `'me'` when the local user added it, `'them'` for the remote party.
  final String actor;
  final DateTime at;

  /// For reaction echoes the local user sent over the wire as plain-text
  /// tapbacks (e.g. `Loved "..."`), this is the provider id of the outbound
  /// fallback message. Used to dedupe when the carrier round-trips the
  /// fallback back to us.
  final String? echoProviderId;

  const SmsReactor({
    required this.actor,
    required this.at,
    this.echoProviderId,
  });

  Map<String, dynamic> toJson() => {
        'actor': actor,
        'at': at.toIso8601String(),
        if (echoProviderId != null) 'echo_provider_id': echoProviderId,
      };

  factory SmsReactor.fromJson(Map<String, dynamic> j) => SmsReactor(
        actor: (j['actor'] as String?) ?? 'me',
        at: DateTime.tryParse((j['at'] as String?) ?? '') ?? DateTime.now(),
        echoProviderId: j['echo_provider_id'] as String?,
      );
}

class SmsMessage {
  final int? localId;
  final String? providerId;
  final String providerType;
  final String from;
  final String to;
  final String text;
  final SmsDirection direction;
  final SmsStatus status;
  final DateTime createdAt;
  final List<String> mediaUrls;
  final bool isRead;
  final bool isDeleted;
  final String? errorReason;

  /// Emoji -> list of reactors. Multiple people / multiple taps of the same
  /// emoji are tracked as separate entries so we can render counts / dedupe.
  final Map<String, List<SmsReactor>> reactions;

  /// When this message is a reply, the carrier id of the parent (if known).
  final String? replyToProviderId;

  /// When this message is a reply, the local row id of the parent (if known).
  final int? replyToLocalId;

  /// When non-null, this row exists purely as the echo of a fallback tapback /
  /// reaction we sent over the wire. It mirrors the reaction applied to the
  /// target message and should NOT be rendered as its own bubble.
  /// Stored inside `reactions_json` as `{"__reflects": "<providerId>"}`.
  final String? reflectsProviderId;

  const SmsMessage({
    this.localId,
    this.providerId,
    this.providerType = 'telnyx',
    required this.from,
    required this.to,
    required this.text,
    required this.direction,
    this.status = SmsStatus.queued,
    required this.createdAt,
    this.mediaUrls = const [],
    this.isRead = false,
    this.isDeleted = false,
    this.errorReason,
    this.reactions = const {},
    this.replyToProviderId,
    this.replyToLocalId,
    this.reflectsProviderId,
  });

  String get remotePhone => direction == SmsDirection.inbound ? from : to;
  String get localPhone => direction == SmsDirection.inbound ? to : from;

  bool get hasReactions => reactions.isNotEmpty;
  bool get isReactionEcho => reflectsProviderId != null;

  SmsMessage copyWith({
    int? localId,
    String? providerId,
    String? providerType,
    String? from,
    String? to,
    String? text,
    SmsDirection? direction,
    SmsStatus? status,
    DateTime? createdAt,
    List<String>? mediaUrls,
    bool? isRead,
    bool? isDeleted,
    String? errorReason,
    Map<String, List<SmsReactor>>? reactions,
    String? replyToProviderId,
    int? replyToLocalId,
    String? reflectsProviderId,
  }) {
    return SmsMessage(
      localId: localId ?? this.localId,
      providerId: providerId ?? this.providerId,
      providerType: providerType ?? this.providerType,
      from: from ?? this.from,
      to: to ?? this.to,
      text: text ?? this.text,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      mediaUrls: mediaUrls ?? this.mediaUrls,
      isRead: isRead ?? this.isRead,
      isDeleted: isDeleted ?? this.isDeleted,
      errorReason: errorReason ?? this.errorReason,
      reactions: reactions ?? this.reactions,
      replyToProviderId: replyToProviderId ?? this.replyToProviderId,
      replyToLocalId: replyToLocalId ?? this.replyToLocalId,
      reflectsProviderId: reflectsProviderId ?? this.reflectsProviderId,
    );
  }

  Map<String, dynamic> toDbMap() => {
        if (localId != null) 'id': localId,
        'provider_id': providerId,
        'provider_type': providerType,
        'remote_phone': remotePhone,
        'local_phone': localPhone,
        'direction': direction.name,
        'body': text,
        'media_urls': mediaUrls.isNotEmpty ? mediaUrls.join(',') : null,
        'status': status.name,
        'is_read': isRead ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'error_reason': errorReason,
        'reactions_json': _encodeReactions(reactions, reflectsProviderId),
        'reply_to_provider_id': replyToProviderId,
        'reply_to_local_id': replyToLocalId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

  factory SmsMessage.fromDbMap(Map<String, dynamic> map) {
    final direction = SmsDirection.values.byName(map['direction'] as String);
    final remotePhone = map['remote_phone'] as String;
    final localPhone = map['local_phone'] as String;
    final decoded = _decodeReactions(map['reactions_json'] as String?);
    return SmsMessage(
      localId: map['id'] as int?,
      providerId: map['provider_id'] as String?,
      providerType: (map['provider_type'] as String?) ?? 'telnyx',
      from: direction == SmsDirection.inbound ? remotePhone : localPhone,
      to: direction == SmsDirection.inbound ? localPhone : remotePhone,
      text: (map['body'] as String?) ?? '',
      direction: direction,
      status: _parseStatus((map['status'] as String?) ?? 'queued'),
      createdAt: DateTime.parse(map['created_at'] as String),
      mediaUrls: _splitMedia(map['media_urls'] as String?),
      isRead: (map['is_read'] as int?) == 1,
      isDeleted: (map['is_deleted'] as int?) == 1,
      errorReason: map['error_reason'] as String?,
      reactions: decoded.$1,
      reflectsProviderId: decoded.$2,
      replyToProviderId: map['reply_to_provider_id'] as String?,
      replyToLocalId: map['reply_to_local_id'] as int?,
    );
  }

  static SmsStatus _parseStatus(String s) {
    for (final v in SmsStatus.values) {
      if (v.name == s) return v;
    }
    return SmsStatus.queued;
  }

  static List<String> _splitMedia(String? csv) {
    if (csv == null || csv.isEmpty) return const [];
    return csv.split(',').where((s) => s.isNotEmpty).toList();
  }

  static String? _encodeReactions(
    Map<String, List<SmsReactor>> reactions,
    String? reflectsProviderId,
  ) {
    if (reactions.isEmpty && reflectsProviderId == null) return null;
    final payload = <String, dynamic>{};
    if (reactions.isNotEmpty) {
      payload['reactions'] = reactions.map(
        (emoji, list) => MapEntry(emoji, list.map((r) => r.toJson()).toList()),
      );
    }
    if (reflectsProviderId != null) {
      payload['__reflects'] = reflectsProviderId;
    }
    return jsonEncode(payload);
  }

  static (Map<String, List<SmsReactor>>, String?) _decodeReactions(
    String? raw,
  ) {
    if (raw == null || raw.isEmpty) return (const <String, List<SmsReactor>>{}, null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return (const <String, List<SmsReactor>>{}, null);
      }
      final reflects = decoded['__reflects'] as String?;
      final rMap = decoded['reactions'];
      if (rMap is! Map<String, dynamic>) {
        return (const <String, List<SmsReactor>>{}, reflects);
      }
      final out = <String, List<SmsReactor>>{};
      for (final e in rMap.entries) {
        final list = e.value;
        if (list is! List) continue;
        out[e.key] = list
            .whereType<Map<String, dynamic>>()
            .map(SmsReactor.fromJson)
            .toList();
      }
      return (out, reflects);
    } catch (_) {
      return (const <String, List<SmsReactor>>{}, null);
    }
  }
}
