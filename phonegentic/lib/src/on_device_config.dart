import 'dart:io';

/// Compile-time feature flag for on-device ML models (Kokoro TTS, WhisperKit STT).
///
/// Controlled via: --dart-define=ENABLE_ON_DEVICE_MODELS=true
/// When false, on-device provider options are hidden from the UI and
/// native MethodChannels return "not available."
class OnDeviceConfig {
  OnDeviceConfig._();

  static const bool enabled = bool.fromEnvironment(
    'ENABLE_ON_DEVICE_MODELS',
    defaultValue: false,
  );

  /// On-device models only work on Apple platforms (MLX / CoreML).
  static bool get isSupported =>
      enabled && (Platform.isMacOS || Platform.isIOS);
}
