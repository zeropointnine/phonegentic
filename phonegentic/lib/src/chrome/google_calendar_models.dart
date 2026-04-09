class GCalEventInfo {
  final String title;
  final String date;
  final String startTime;
  final String endTime;
  final String location;
  final String description;
  final List<String> attendees;

  const GCalEventInfo({
    this.title = '',
    this.date = '',
    this.startTime = '',
    this.endTime = '',
    this.location = '',
    this.description = '',
    this.attendees = const [],
  });

  factory GCalEventInfo.fromMap(Map<String, dynamic> map) {
    final rawAttendees = map['attendees'];
    final attendeeList = rawAttendees is List
        ? rawAttendees.map((a) => a.toString()).toList()
        : <String>[];
    return GCalEventInfo(
      title: map['title'] as String? ?? '',
      date: map['date'] as String? ?? '',
      startTime: map['startTime'] as String? ?? '',
      endTime: map['endTime'] as String? ?? '',
      location: map['location'] as String? ?? '',
      description: map['description'] as String? ?? '',
      attendees: attendeeList,
    );
  }

  bool get hasContent => title.isNotEmpty;

  @override
  String toString() =>
      'GCalEventInfo(title: $title, date: $date, $startTime-$endTime)';
}
