import 'package:shared_preferences/shared_preferences.dart';

import 'chrome/flight_aware_config.dart';

class CalendlyConfig {
  final String apiKey;
  final bool syncToMacOS;

  const CalendlyConfig({
    this.apiKey = '',
    this.syncToMacOS = false,
  });

  bool get isConfigured => apiKey.isNotEmpty;

  CalendlyConfig copyWith({
    String? apiKey,
    bool? syncToMacOS,
  }) {
    return CalendlyConfig(
      apiKey: apiKey ?? this.apiKey,
      syncToMacOS: syncToMacOS ?? this.syncToMacOS,
    );
  }
}

class DemoModeConfig {
  final bool enabled;
  final String fakeNumber;

  const DemoModeConfig({
    this.enabled = false,
    this.fakeNumber = '',
  });

  DemoModeConfig copyWith({
    bool? enabled,
    String? fakeNumber,
  }) {
    return DemoModeConfig(
      enabled: enabled ?? this.enabled,
      fakeNumber: fakeNumber ?? this.fakeNumber,
    );
  }
}

class AgentManagerConfig {
  final String phoneNumber;
  final String name;

  const AgentManagerConfig({this.phoneNumber = '', this.name = ''});

  bool get isConfigured => phoneNumber.isNotEmpty;

  AgentManagerConfig copyWith({String? phoneNumber, String? name}) {
    return AgentManagerConfig(
      phoneNumber: phoneNumber ?? this.phoneNumber,
      name: name ?? this.name,
    );
  }
}

enum AwayReturnMode { quietBadge, proactiveGreeting }

class AwayReturnConfig {
  final AwayReturnMode mode;

  const AwayReturnConfig({this.mode = AwayReturnMode.quietBadge});

  AwayReturnConfig copyWith({AwayReturnMode? mode}) {
    return AwayReturnConfig(mode: mode ?? this.mode);
  }
}

class UserConfigService {
  static const _prefix = 'user_';

  static Future<CalendlyConfig> loadCalendlyConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return CalendlyConfig(
      apiKey: prefs.getString('${_prefix}calendly_api_key') ?? '',
      syncToMacOS: prefs.getBool('${_prefix}calendly_sync_macos') ?? false,
    );
  }

  static Future<void> saveCalendlyConfig(CalendlyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}calendly_api_key', config.apiKey);
    await prefs.setBool('${_prefix}calendly_sync_macos', config.syncToMacOS);
  }

  static Future<DemoModeConfig> loadDemoModeConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return DemoModeConfig(
      enabled: prefs.getBool('${_prefix}demo_mode_enabled') ?? false,
      fakeNumber: prefs.getString('${_prefix}demo_fake_number') ?? '',
    );
  }

  static Future<void> saveDemoModeConfig(DemoModeConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}demo_mode_enabled', config.enabled);
    await prefs.setString('${_prefix}demo_fake_number', config.fakeNumber);
  }

  static Future<AgentManagerConfig> loadAgentManagerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return AgentManagerConfig(
      phoneNumber:
          prefs.getString('${_prefix}agent_manager_phone') ?? '',
      name: prefs.getString('${_prefix}agent_manager_name') ?? '',
    );
  }

  static Future<void> saveAgentManagerConfig(
      AgentManagerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        '${_prefix}agent_manager_phone', config.phoneNumber);
    await prefs.setString(
        '${_prefix}agent_manager_name', config.name);
  }

  static Future<AwayReturnConfig> loadAwayReturnConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('${_prefix}away_return_mode') ?? 'quietBadge';
    final mode = AwayReturnMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AwayReturnMode.quietBadge,
    );
    return AwayReturnConfig(mode: mode);
  }

  static Future<void> saveAwayReturnConfig(AwayReturnConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}away_return_mode', config.mode.name);
  }

  static Future<FlightAwareConfig> loadFlightAwareConfig() =>
      FlightAwareConfig.load();

  static Future<void> saveFlightAwareConfig(FlightAwareConfig config) =>
      config.save();
}
