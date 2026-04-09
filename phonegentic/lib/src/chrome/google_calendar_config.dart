import 'package:shared_preferences/shared_preferences.dart';

enum CalendarReadAccess { unrestricted, hostOnly, allowList }

class GoogleCalendarConfig {
  final bool enabled;
  final CalendarReadAccess readAccessMode;
  final List<String> allowedPhoneNumbers;
  final bool syncEnabled;

  static const _prefix = 'user_gcal_';

  const GoogleCalendarConfig({
    this.enabled = false,
    this.readAccessMode = CalendarReadAccess.unrestricted,
    this.allowedPhoneNumbers = const [],
    this.syncEnabled = false,
  });

  bool get isConfigured => enabled;

  GoogleCalendarConfig copyWith({
    bool? enabled,
    CalendarReadAccess? readAccessMode,
    List<String>? allowedPhoneNumbers,
    bool? syncEnabled,
  }) {
    return GoogleCalendarConfig(
      enabled: enabled ?? this.enabled,
      readAccessMode: readAccessMode ?? this.readAccessMode,
      allowedPhoneNumbers: allowedPhoneNumbers ?? this.allowedPhoneNumbers,
      syncEnabled: syncEnabled ?? this.syncEnabled,
    );
  }

  static Future<GoogleCalendarConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt('${_prefix}read_access_mode') ?? 0;
    final phones = prefs.getStringList('${_prefix}allowed_phones') ?? [];
    return GoogleCalendarConfig(
      enabled: prefs.getBool('${_prefix}enabled') ?? false,
      readAccessMode: CalendarReadAccess.values[modeIndex.clamp(0, CalendarReadAccess.values.length - 1)],
      allowedPhoneNumbers: phones,
      syncEnabled: prefs.getBool('${_prefix}sync_enabled') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', enabled);
    await prefs.setInt('${_prefix}read_access_mode', readAccessMode.index);
    await prefs.setStringList('${_prefix}allowed_phones', allowedPhoneNumbers);
    await prefs.setBool('${_prefix}sync_enabled', syncEnabled);
  }
}
