class EmailInfo {
  final String sender;
  final String recipient;
  final String subject;
  final String snippet;
  final String body;
  final String date;
  final bool isUnread;

  const EmailInfo({
    this.sender = '',
    this.recipient = '',
    this.subject = '',
    this.snippet = '',
    this.body = '',
    this.date = '',
    this.isUnread = false,
  });

  factory EmailInfo.fromMap(Map<String, dynamic> map) {
    return EmailInfo(
      sender: map['sender'] as String? ?? '',
      recipient: map['recipient'] as String? ?? '',
      subject: map['subject'] as String? ?? '',
      snippet: map['snippet'] as String? ?? '',
      body: map['body'] as String? ?? '',
      date: map['date'] as String? ?? '',
      isUnread: map['isUnread'] as bool? ?? false,
    );
  }

  bool get hasContent => subject.isNotEmpty || body.isNotEmpty;

  @override
  String toString() =>
      'EmailInfo(from: $sender, subject: $subject, date: $date)';
}

class EmailSearchResult {
  final String query;
  final List<EmailInfo> emails;
  final DateTime lastUpdated;

  const EmailSearchResult({
    required this.query,
    required this.emails,
    required this.lastUpdated,
  });
}
