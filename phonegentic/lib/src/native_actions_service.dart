import 'package:flutter/services.dart';

class NativeActionsAvailability {
  final bool reminders;
  final bool facetime;
  final bool notes;

  const NativeActionsAvailability({
    required this.reminders,
    required this.facetime,
    required this.notes,
  });

  factory NativeActionsAvailability.fromMap(Map<dynamic, dynamic> map) {
    return NativeActionsAvailability(
      reminders: map['reminders'] as bool? ?? false,
      facetime: map['facetime'] as bool? ?? false,
      notes: map['notes'] as bool? ?? false,
    );
  }
}

class ReminderList {
  final String title;
  final bool isDefault;

  const ReminderList({required this.title, required this.isDefault});

  factory ReminderList.fromMap(Map<dynamic, dynamic> map) {
    return ReminderList(
      title: map['title'] as String,
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }
}

class NativeActionsService {
  static const _channel = MethodChannel('com.agentic_ai/native_actions');

  static Future<NativeActionsAvailability> getAvailableActions() async {
    final Map<dynamic, dynamic> result =
        await _channel.invokeMethod('getAvailableActions');
    return NativeActionsAvailability.fromMap(result);
  }

  /// Creates a reminder in Apple Reminders.
  ///
  /// [priority]: 0 = none, 1-4 = high, 5 = medium, 6-9 = low.
  /// Returns the reminder's calendar item identifier on success.
  static Future<String?> createReminder({
    required String title,
    String? body,
    DateTime? dueDate,
    DateTime? remindDate,
    int? priority,
    String? listName,
  }) async {
    final Map<dynamic, dynamic>? result =
        await _channel.invokeMethod('createReminder', {
      'title': title,
      if (body != null) 'body': body,
      if (dueDate != null) 'dueDateMs': dueDate.millisecondsSinceEpoch,
      if (remindDate != null) 'remindDateMs': remindDate.millisecondsSinceEpoch,
      if (priority != null) 'priority': priority,
      if (listName != null) 'listName': listName,
    });
    return result?['id'] as String?;
  }

  static Future<List<ReminderList>> getReminderLists() async {
    final List<dynamic> result =
        await _channel.invokeMethod('getReminderLists');
    return result
        .cast<Map<dynamic, dynamic>>()
        .map(ReminderList.fromMap)
        .toList();
  }

  /// Initiates a FaceTime call to [target] (phone number or email).
  ///
  /// macOS always prompts the user before dialing.
  /// Set [audioOnly] to false for a video call (defaults to audio-only).
  static Future<void> startFaceTimeCall({
    required String target,
    bool audioOnly = true,
  }) async {
    await _channel.invokeMethod('startFaceTimeCall', {
      'target': target,
      'audioOnly': audioOnly,
    });
  }

  /// Creates a note in Apple Notes via AppleScript.
  ///
  /// Only available for direct distribution builds (not App Store).
  /// Check [getAvailableActions] first to see if this is supported.
  /// The [body] can contain HTML content.
  static Future<bool> createNote({
    required String title,
    String? body,
    String? folderName,
  }) async {
    final Map<dynamic, dynamic>? result =
        await _channel.invokeMethod('createNote', {
      'title': title,
      if (body != null) 'body': body,
      if (folderName != null) 'folderName': folderName,
    });
    return result?['success'] as bool? ?? false;
  }
}
