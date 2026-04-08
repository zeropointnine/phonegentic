import 'package:shared_preferences/shared_preferences.dart';

class FlightAwareConfig {
  final bool enabled;
  final int debugPort;

  static const _prefix = 'user_flightaware_';

  const FlightAwareConfig({
    this.enabled = false,
    this.debugPort = 9222,
  });

  bool get isConfigured => enabled;

  FlightAwareConfig copyWith({
    bool? enabled,
    int? debugPort,
  }) {
    return FlightAwareConfig(
      enabled: enabled ?? this.enabled,
      debugPort: debugPort ?? this.debugPort,
    );
  }

  static Future<FlightAwareConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return FlightAwareConfig(
      enabled: prefs.getBool('${_prefix}enabled') ?? false,
      debugPort: prefs.getInt('${_prefix}debug_port') ?? 9222,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}enabled', enabled);
    await prefs.setInt('${_prefix}debug_port', debugPort);
  }
}
