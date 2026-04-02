import 'package:flutter/foundation.dart';

import 'phone_formatter.dart';
import 'user_config_service.dart';

class DemoModeService extends ChangeNotifier {
  bool _enabled = false;
  String _fakeNumber = '';

  bool get enabled => _enabled;
  String get fakeNumber => _fakeNumber;

  Future<void> load() async {
    final config = await UserConfigService.loadDemoModeConfig();
    _enabled = config.enabled;
    _fakeNumber = config.fakeNumber;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _persist();
    notifyListeners();
  }

  Future<void> setFakeNumber(String value) async {
    _fakeNumber = value;
    await _persist();
    notifyListeners();
  }

  /// Returns the fake number (formatted) when demo mode is on,
  /// otherwise returns the real formatted number.
  String maskPhone(String raw) {
    if (!_enabled) return PhoneFormatter.format(raw);
    if (_fakeNumber.isNotEmpty) return PhoneFormatter.format(_fakeNumber);
    return '(555) 000-0000';
  }

  /// Returns only the first name when demo mode is on,
  /// otherwise returns the full display name.
  String maskDisplayName(String fullName) {
    if (!_enabled) return fullName;
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return trimmed;
    final spaceIdx = trimmed.indexOf(' ');
    if (spaceIdx < 0) return trimmed;
    return trimmed.substring(0, spaceIdx);
  }

  Future<void> _persist() async {
    await UserConfigService.saveDemoModeConfig(
      DemoModeConfig(enabled: _enabled, fakeNumber: _fakeNumber),
    );
  }
}
