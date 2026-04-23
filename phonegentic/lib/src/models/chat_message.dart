import 'dart:convert';

enum ChatRole { user, agent, host, remoteParty, system }

enum MessageType { text, transcript, action, status, callState, whisper, attachment, sms, reminder, note }

class MessageAction {
  final String label;
  final String value;
  const MessageAction({required this.label, required this.value});

  Map<String, String> toMap() => {'label': label, 'value': value};

  factory MessageAction.fromMap(Map<String, dynamic> map) =>
      MessageAction(label: map['label'] as String, value: map['value'] as String);
}

class ChatMessage {
  final String id;
  final ChatRole role;
  final MessageType type;
  String text;
  final DateTime timestamp;
  final String? speakerName;
  bool isStreaming;
  final List<MessageAction> actions;
  final Map<String, dynamic>? metadata;

  ChatMessage({
    required this.id,
    required this.role,
    required this.type,
    required this.text,
    DateTime? timestamp,
    this.speakerName,
    this.isStreaming = false,
    this.actions = const [],
    this.metadata,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage.agent(
    this.text, {
    String? id,
    this.isStreaming = false,
    this.actions = const [],
    this.metadata,
  })  : id = id ?? _uid(),
        role = ChatRole.agent,
        type = MessageType.text,
        timestamp = DateTime.now(),
        speakerName = null;

  ChatMessage.user(this.text, {String? id, this.metadata})
      : id = id ?? _uid(),
        role = ChatRole.user,
        type = MessageType.text,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [];

  ChatMessage.system(this.text, {String? id, this.metadata})
      : id = id ?? _uid(),
        role = ChatRole.system,
        type = MessageType.status,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [];

  ChatMessage.transcript(
    this.role,
    this.text, {
    String? id,
    this.speakerName,
    this.metadata,
  })  : id = id ?? _uid(),
        type = MessageType.transcript,
        timestamp = DateTime.now(),
        isStreaming = false,
        actions = const [];

  ChatMessage.callState(
    this.text, {
    String? id,
    this.metadata,
  })  : id = id ?? _uid(),
        role = ChatRole.system,
        type = MessageType.callState,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [];

  ChatMessage.whisper(this.text, {String? id, this.metadata})
      : id = id ?? _uid(),
        role = ChatRole.user,
        type = MessageType.whisper,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [];

  /// A private, read-only note entered by the manager via the `/note`
  /// command. Notes are **never** sent to the LLM — they live purely in the
  /// transcript as UI annotations.
  ChatMessage.note(this.text, {String? id, this.metadata})
      : id = id ?? _uid(),
        role = ChatRole.user,
        type = MessageType.note,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [];

  ChatMessage.attachment(
    this.text, {
    String? id,
    required String fileName,
  })  : id = id ?? _uid(),
        role = ChatRole.user,
        type = MessageType.attachment,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        actions = const [],
        metadata = {'fileName': fileName};

  /// An SMS message rendered inline as a threaded conversation bubble.
  ///
  /// [direction] is `'inbound'` or `'outbound'`.
  /// [remotePhone] is the other party's number.
  /// [contactName] is the display name if known.
  ChatMessage.sms(
    this.text, {
    String? id,
    required String direction,
    required String remotePhone,
    String? contactName,
    String? smsProviderId,
    String? smsProviderType,
    int? smsLocalId,
  })  : id = id ?? _uid(),
        role = ChatRole.system,
        type = MessageType.sms,
        timestamp = DateTime.now(),
        speakerName = contactName,
        isStreaming = false,
        actions = const [],
        metadata = {
          'sms_direction': direction,
          'sms_remote_phone': remotePhone,
          if (contactName != null) 'sms_contact_name': contactName,
          if (smsProviderId != null) 'sms_provider_id': smsProviderId,
          if (smsProviderType != null) 'sms_provider_type': smsProviderType,
          if (smsLocalId != null) 'sms_local_id': smsLocalId,
        };

  /// A timed reminder surfaced in the agent chat with action chips.
  ///
  /// [metadata] should include `'reminder_id'` (int) for dismiss/snooze actions
  /// and optionally `'recording_playback'` / `'filePath'` for inline players.
  ChatMessage.reminder(
    this.text, {
    String? id,
    int? reminderId,
    String? contactName,
    this.actions = const [],
  })  : id = id ?? _uid(),
        role = ChatRole.system,
        type = MessageType.reminder,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        metadata = {
          if (reminderId != null) 'reminder_id': reminderId,
          if (contactName != null) 'contact_name': contactName,
        };

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toDbMap() => {
        'message_id': id,
        'role': role.name,
        'type': type.name,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        'speaker_name': speakerName,
        'actions_json': actions.isEmpty
            ? null
            : jsonEncode(actions.map((a) => a.toMap()).toList()),
        'metadata_json':
            metadata != null && metadata!.isNotEmpty ? jsonEncode(metadata) : null,
      };

  factory ChatMessage.fromDbMap(Map<String, dynamic> map) {
    final roleStr = map['role'] as String;
    final typeStr = map['type'] as String;

    List<MessageAction> actions = const [];
    final actionsJson = map['actions_json'] as String?;
    if (actionsJson != null && actionsJson.isNotEmpty) {
      final decoded = jsonDecode(actionsJson) as List;
      actions = decoded
          .map((e) => MessageAction.fromMap(e as Map<String, dynamic>))
          .toList();
    }

    Map<String, dynamic>? metadata;
    final metaJson = map['metadata_json'] as String?;
    if (metaJson != null && metaJson.isNotEmpty) {
      metadata = jsonDecode(metaJson) as Map<String, dynamic>;
    }

    return ChatMessage(
      id: map['message_id'] as String,
      role: ChatRole.values.firstWhere((r) => r.name == roleStr,
          orElse: () => ChatRole.system),
      type: MessageType.values.firstWhere((t) => t.name == typeStr,
          orElse: () => MessageType.text),
      text: map['text'] as String? ?? '',
      timestamp: DateTime.tryParse(map['timestamp'] as String? ?? ''),
      speakerName: map['speaker_name'] as String?,
      actions: actions,
      metadata: metadata,
    );
  }

  static int _counter = 0;
  static String _uid() => 'msg_${DateTime.now().millisecondsSinceEpoch}_${_counter++}';
}
