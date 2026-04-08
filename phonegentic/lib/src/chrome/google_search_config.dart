import 'package:shared_preferences/shared_preferences.dart';

class GoogleSearchConfig {
  final bool enabled;

  static const _prefix = 'user_google_search_';

  const GoogleSearchConfig({this.enabled = false});

  bool get isConfigured => enabled;

  GoogleSearchConfig copyWith({bool? enabled}) {
    return GoogleSearchConfig(enabled: enabled ?? this.enabled);
  }

  static Future<GoogleSearchConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return GoogleSearchConfig(
      enabled: prefs.getBool('${_prefix}enabled') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', enabled);
  }
}
