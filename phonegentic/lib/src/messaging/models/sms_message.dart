enum SmsDirection { inbound, outbound }

enum SmsStatus { queued, sent, delivered, failed, received }

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
  });

  String get remotePhone => direction == SmsDirection.inbound ? from : to;
  String get localPhone => direction == SmsDirection.inbound ? to : from;

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
        'created_at': createdAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

  factory SmsMessage.fromDbMap(Map<String, dynamic> map) {
    final direction = SmsDirection.values.byName(map['direction'] as String);
    final remotePhone = map['remote_phone'] as String;
    final localPhone = map['local_phone'] as String;
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
}
