import 'sms_message.dart';

String formatPhoneNumber(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.length == 11 && digits.startsWith('1')) {
    return '(${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
  }
  if (digits.length == 10) {
    return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
  }
  return raw;
}

class SmsConversation {
  final String remotePhone;
  final String localPhone;
  final String? contactName;
  final SmsMessage? lastMessage;
  final int unreadCount;
  final int totalMessages;

  const SmsConversation({
    required this.remotePhone,
    required this.localPhone,
    this.contactName,
    this.lastMessage,
    this.unreadCount = 0,
    this.totalMessages = 0,
  });

  String get displayName => contactName ?? formatPhoneNumber(remotePhone);

  String get initials {
    if (contactName != null && contactName!.isNotEmpty) {
      final parts = contactName!.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
      }
      return parts.first[0].toUpperCase();
    }
    return '#';
  }

  SmsConversation copyWith({
    String? remotePhone,
    String? localPhone,
    String? contactName,
    SmsMessage? lastMessage,
    int? unreadCount,
    int? totalMessages,
  }) {
    return SmsConversation(
      remotePhone: remotePhone ?? this.remotePhone,
      localPhone: localPhone ?? this.localPhone,
      contactName: contactName ?? this.contactName,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
      totalMessages: totalMessages ?? this.totalMessages,
    );
  }
}
