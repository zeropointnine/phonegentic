import 'package:shared_preferences/shared_preferences.dart';

class AppleRemindersConfig {
  final bool enabled;
  final String defaultList;

  static const _prefix = 'user_apple_reminders_';

  const AppleRemindersConfig({
    this.enabled = false,
    this.defaultList = '',
  });

  bool get isConfigured => enabled;

  AppleRemindersConfig copyWith({
    bool? enabled,
    String? defaultList,
  }) {
    return AppleRemindersConfig(
      enabled: enabled ?? this.enabled,
      defaultList: defaultList ?? this.defaultList,
    );
  }

  static Future<AppleRemindersConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppleRemindersConfig(
      enabled: prefs.getBool('${_prefix}enabled') ?? false,
      defaultList: prefs.getString('${_prefix}default_list') ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', enabled);
    await prefs.setString('${_prefix}default_list', defaultList);
  }
}
