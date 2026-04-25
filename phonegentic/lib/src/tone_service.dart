import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Touchtone synthesis style.
enum TouchToneStyle {
  /// Standard DTMF dual-tone pairs (697/770/852/941 × 1209/1336/1477/1633 Hz).
  dtmf,

  /// AT&T R1 "Blue Box" multi-frequency tones (700/900/1100/1300/1500/1700 Hz).
  blue,
}

extension TouchToneStyleX on TouchToneStyle {
  String get wireValue {
    switch (this) {
      case TouchToneStyle.dtmf:
        return 'dtmf';
      case TouchToneStyle.blue:
        return 'blue';
    }
  }

  String get displayName {
    switch (this) {
      case TouchToneStyle.dtmf:
        return 'DTMF (standard)';
      case TouchToneStyle.blue:
        return 'Blue Box (MF)';
    }
  }

  static TouchToneStyle fromWire(String? raw) {
    if (raw == 'blue' || raw == 'bluebox' || raw == 'mf') {
      return TouchToneStyle.blue;
    }
    return TouchToneStyle.dtmf;
  }
}

/// Owns the user-facing tone settings (touchtone style, call-waiting +
/// call-ended toggles, agent-announce sub-toggles) and forwards play
/// requests to the native `com.agentic_ai/audio_tap_control` channel
/// where `ToneGenerator` synthesises the actual audio.
///
/// The DTMF press behaviour intentionally guarantees a 300 ms minimum
/// hold: pressing a key starts a tone and a release fires only after the
/// minimum has elapsed, even if the user tapped briefly.
class ToneService extends ChangeNotifier {
  ToneService({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.agentic_ai/audio_tap_control');

  static const String _kTouchTonesEnabled = 'tone_touch_enabled';
  static const String _kTouchToneStyle = 'tone_touch_style';
  static const String _kCallWaitingEnabled = 'tone_call_waiting_enabled';
  static const String _kCallWaitingAnnounce = 'tone_call_waiting_announce';
  static const String _kCallEndedEnabled = 'tone_call_ended_enabled';
  static const String _kCallEndedAnnounce = 'tone_call_ended_announce';

  /// Floor on key-press tone duration. The native side keeps the
  /// oscillator running until a corresponding stop arrives, so we just
  /// make sure we don't deliver the stop too early.
  static const Duration minTouchToneDuration = Duration(milliseconds: 300);

  final MethodChannel _channel;

  bool _touchTonesEnabled = true;
  TouchToneStyle _touchToneStyle = TouchToneStyle.dtmf;
  bool _callWaitingEnabled = true;
  bool _callWaitingAnnounce = false;
  bool _callEndedEnabled = true;
  bool _callEndedAnnounce = false;
  bool _loaded = false;

  /// Per-key press start time, used to enforce [minTouchToneDuration].
  final Map<String, DateTime> _pressStarts = <String, DateTime>{};

  /// Per-key pending release timer for the minimum-hold extension.
  final Map<String, Timer> _pendingReleases = <String, Timer>{};

  bool get touchTonesEnabled => _touchTonesEnabled;
  TouchToneStyle get touchToneStyle => _touchToneStyle;
  bool get callWaitingEnabled => _callWaitingEnabled;
  bool get callWaitingAnnounce => _callWaitingAnnounce;
  bool get callEndedEnabled => _callEndedEnabled;
  bool get callEndedAnnounce => _callEndedAnnounce;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _touchTonesEnabled = prefs.getBool(_kTouchTonesEnabled) ?? true;
    _touchToneStyle = TouchToneStyleX.fromWire(prefs.getString(_kTouchToneStyle));
    _callWaitingEnabled = prefs.getBool(_kCallWaitingEnabled) ?? true;
    _callWaitingAnnounce = prefs.getBool(_kCallWaitingAnnounce) ?? false;
    _callEndedEnabled = prefs.getBool(_kCallEndedEnabled) ?? true;
    _callEndedAnnounce = prefs.getBool(_kCallEndedAnnounce) ?? false;
    notifyListeners();
  }

  Future<void> setTouchTonesEnabled(bool value) async {
    if (_touchTonesEnabled == value) return;
    _touchTonesEnabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTouchTonesEnabled, value);
    notifyListeners();
  }

  Future<void> setTouchToneStyle(TouchToneStyle style) async {
    if (_touchToneStyle == style) return;
    _touchToneStyle = style;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTouchToneStyle, style.wireValue);
    notifyListeners();
  }

  Future<void> setCallWaitingEnabled(bool value) async {
    if (_callWaitingEnabled == value) return;
    _callWaitingEnabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCallWaitingEnabled, value);
    notifyListeners();
  }

  Future<void> setCallWaitingAnnounce(bool value) async {
    if (_callWaitingAnnounce == value) return;
    _callWaitingAnnounce = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCallWaitingAnnounce, value);
    notifyListeners();
  }

  Future<void> setCallEndedEnabled(bool value) async {
    if (_callEndedEnabled == value) return;
    _callEndedEnabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCallEndedEnabled, value);
    notifyListeners();
  }

  Future<void> setCallEndedAnnounce(bool value) async {
    if (_callEndedAnnounce == value) return;
    _callEndedAnnounce = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCallEndedAnnounce, value);
    notifyListeners();
  }

  // ── Touchtone press / release ───────────────────────────────────────

  /// Start a tone for [key] (a single character: `0-9`, `*`, `#`).
  /// Has no effect when touchtones are disabled.
  Future<void> playDtmfDown(String key) async {
    if (!_touchTonesEnabled) return;
    final String normalized = _normalizeKey(key);
    if (normalized.isEmpty) return;

    _pendingReleases.remove(normalized)?.cancel();
    _pressStarts[normalized] = DateTime.now();

    try {
      await _channel.invokeMethod<void>('playToneStart', <String, Object?>{
        'key': normalized,
        'style': _touchToneStyle.wireValue,
      });
    } catch (e) {
      debugPrint('[ToneService] playToneStart($normalized) failed: $e');
    }
  }

  /// Release the tone for [key]. If the key was pressed for less than
  /// [minTouchToneDuration] the actual stop is deferred so the user
  /// always hears a clean ≥300 ms tone.
  Future<void> playDtmfUp(String key) async {
    if (!_touchTonesEnabled) return;
    final String normalized = _normalizeKey(key);
    if (normalized.isEmpty) return;

    final DateTime? started = _pressStarts.remove(normalized);
    final Duration elapsed = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    final Duration remaining = minTouchToneDuration - elapsed;

    if (remaining > Duration.zero) {
      _pendingReleases[normalized]?.cancel();
      _pendingReleases[normalized] = Timer(remaining, () {
        _pendingReleases.remove(normalized);
        _stopTone(normalized);
      });
      return;
    }

    _stopTone(normalized);
  }

  /// Brief one-shot tap (used for keypad presses outside an active call,
  /// e.g. while typing the number to dial). Plays for the minimum hold.
  Future<void> tapDtmf(String key) async {
    await playDtmfDown(key);
    Timer(minTouchToneDuration, () {
      playDtmfUp(key);
    });
  }

  Future<void> _stopTone(String key) async {
    try {
      await _channel.invokeMethod<void>('playToneStop', <String, Object?>{
        'key': key,
      });
    } catch (e) {
      debugPrint('[ToneService] playToneStop($key) failed: $e');
    }
  }

  // ── Event tones ─────────────────────────────────────────────────────

  /// Play the call-waiting beep pattern (2 short beeps) if enabled.
  Future<void> playCallWaiting() async {
    if (!_callWaitingEnabled) return;
    try {
      await _channel.invokeMethod<void>('playToneEvent', <String, Object?>{
        'event': 'callWaiting',
      });
    } catch (e) {
      debugPrint('[ToneService] playToneEvent(callWaiting) failed: $e');
    }
  }

  /// Play the call-ended pattern (3 short beeps) if enabled.
  Future<void> playCallEnded() async {
    if (!_callEndedEnabled) return;
    try {
      await _channel.invokeMethod<void>('playToneEvent', <String, Object?>{
        'event': 'callEnded',
      });
    } catch (e) {
      debugPrint('[ToneService] playToneEvent(callEnded) failed: $e');
    }
  }

  /// Cancel every pending release timer (e.g. on call teardown) so we
  /// don't fire deferred stops against a ToneGenerator that's already
  /// cleaned up its held-key map.
  void cancelPendingReleases() {
    for (final Timer t in _pendingReleases.values) {
      t.cancel();
    }
    _pendingReleases.clear();
    _pressStarts.clear();
  }

  String _normalizeKey(String key) {
    if (key.isEmpty) return '';
    return key.trim().substring(0, 1);
  }

  @override
  void dispose() {
    cancelPendingReleases();
    super.dispose();
  }
}
