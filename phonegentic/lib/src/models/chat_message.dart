enum ChatRole { user, agent, host, remoteParty, system }

enum MessageType { text, transcript, action, status, callState, whisper, attachment, sms, reminder }

class MessageAction {
  final String label;
  final String value;
  const MessageAction({required this.label, required this.value});
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
        };

  /// A timed reminder surfaced in the agent chat with action chips.
  ///
  /// [metadata] should include `'reminder_id'` (int) for dismiss/snooze actions
  /// and optionally `'recording_playback'` / `'filePath'` for inline players.
  ChatMessage.reminder(
    this.text, {
    String? id,
    int? reminderId,
    this.actions = const [],
  })  : id = id ?? _uid(),
        role = ChatRole.system,
        type = MessageType.reminder,
        timestamp = DateTime.now(),
        speakerName = null,
        isStreaming = false,
        metadata = {
          if (reminderId != null) 'reminder_id': reminderId,
        };

  static int _counter = 0;
  static String _uid() => 'msg_${DateTime.now().millisecondsSinceEpoch}_${_counter++}';
}
