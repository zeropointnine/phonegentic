import 'dart:io';

/// Compile-time feature flags read from `--dart-define` or
/// `--dart-define-from-file=build.env`.
///
/// All fields are `const` so the compiler tree-shakes unreachable code paths.
/// See `build.env.example` for the full flag inventory and defaults.
class BuildConfig {
  BuildConfig._();

  /// On-device ML models (Kokoro TTS, WhisperKit STT).
  static const bool enableOnDeviceModels = bool.fromEnvironment(
    'ENABLE_ON_DEVICE_MODELS',
    defaultValue: false,
  );

  /// Whether on-device models are both enabled and running on a supported OS.
  static bool get onDeviceModelsSupported =>
      enableOnDeviceModels &&
      (Platform.isMacOS || Platform.isIOS || Platform.isLinux);

  /// Direct GitHub issue filing via PAT (requires repo scope token in settings).
  static const bool enableGitHubIssues = bool.fromEnvironment(
    'ENABLE_GITHUB_ISSUES',
    defaultValue: false,
  );

  /// Mac App Store build — disables features incompatible with sandboxing.
  static const bool macAppStoreBuild = bool.fromEnvironment(
    'MAC_APP_STORE_BUILD',
    defaultValue: false,
  );
}
