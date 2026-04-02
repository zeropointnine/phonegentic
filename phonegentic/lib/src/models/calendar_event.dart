class CalendarEvent {
  final int? id;
  final String? calendlyEventId;
  final String title;
  final String? description;
  final DateTime startTime;
  final DateTime endTime;
  final String? inviteeName;
  final String? inviteeEmail;
  final String? eventType;
  final int? jobFunctionId;
  final String? location;
  final String status;
  final DateTime? syncedAt;
  final DateTime? createdAt;

  const CalendarEvent({
    this.id,
    this.calendlyEventId,
    required this.title,
    this.description,
    required this.startTime,
    required this.endTime,
    this.inviteeName,
    this.inviteeEmail,
    this.eventType,
    this.jobFunctionId,
    this.location,
    this.status = 'active',
    this.syncedAt,
    this.createdAt,
  });

  CalendarEvent copyWith({
    int? id,
    String? calendlyEventId,
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    String? inviteeName,
    String? inviteeEmail,
    String? eventType,
    int? jobFunctionId,
    String? location,
    String? status,
    DateTime? syncedAt,
    DateTime? createdAt,
  }) {
    return CalendarEvent(
      id: id ?? this.id,
      calendlyEventId: calendlyEventId ?? this.calendlyEventId,
      title: title ?? this.title,
      description: description ?? this.description,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      inviteeName: inviteeName ?? this.inviteeName,
      inviteeEmail: inviteeEmail ?? this.inviteeEmail,
      eventType: eventType ?? this.eventType,
      jobFunctionId: jobFunctionId ?? this.jobFunctionId,
      location: location ?? this.location,
      status: status ?? this.status,
      syncedAt: syncedAt ?? this.syncedAt,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'calendly_event_id': calendlyEventId,
      'title': title,
      'description': description,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'invitee_name': inviteeName,
      'invitee_email': inviteeEmail,
      'event_type': eventType,
      'job_function_id': jobFunctionId,
      'location': location,
      'status': status,
      'synced_at': syncedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
    };
  }

  factory CalendarEvent.fromMap(Map<String, dynamic> map) {
    return CalendarEvent(
      id: map['id'] as int?,
      calendlyEventId: map['calendly_event_id'] as String?,
      title: map['title'] as String? ?? '',
      description: map['description'] as String?,
      startTime: DateTime.parse(map['start_time'] as String),
      endTime: DateTime.parse(map['end_time'] as String),
      inviteeName: map['invitee_name'] as String?,
      inviteeEmail: map['invitee_email'] as String?,
      eventType: map['event_type'] as String?,
      jobFunctionId: map['job_function_id'] as int?,
      location: map['location'] as String?,
      status: map['status'] as String? ?? 'active',
      syncedAt: map['synced_at'] != null
          ? DateTime.tryParse(map['synced_at'] as String)
          : null,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
    );
  }
}
