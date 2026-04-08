import 'package:shared_preferences/shared_preferences.dart';

enum GmailReadAccess { unrestricted, hostOnly, allowList }

class GmailConfig {
  final bool enabled;
  final GmailReadAccess readAccessMode;
  final List<String> allowedPhoneNumbers;

  static const _prefix = 'user_gmail_';

  const GmailConfig({
    this.enabled = false,
    this.readAccessMode = GmailReadAccess.unrestricted,
    this.allowedPhoneNumbers = const [],
  });

  bool get isConfigured => enabled;

  GmailConfig copyWith({
    bool? enabled,
    GmailReadAccess? readAccessMode,
    List<String>? allowedPhoneNumbers,
  }) {
    return GmailConfig(
      enabled: enabled ?? this.enabled,
      readAccessMode: readAccessMode ?? this.readAccessMode,
      allowedPhoneNumbers: allowedPhoneNumbers ?? this.allowedPhoneNumbers,
    );
  }

  static Future<GmailConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt('${_prefix}read_access_mode') ?? 0;
    final phones = prefs.getStringList('${_prefix}allowed_phones') ?? [];
    return GmailConfig(
      enabled: prefs.getBool('${_prefix}enabled') ?? false,
      readAccessMode: GmailReadAccess.values[modeIndex.clamp(0, GmailReadAccess.values.length - 1)],
      allowedPhoneNumbers: phones,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', enabled);
    await prefs.setInt('${_prefix}read_access_mode', readAccessMode.index);
    await prefs.setStringList('${_prefix}allowed_phones', allowedPhoneNumbers);
  }
}
