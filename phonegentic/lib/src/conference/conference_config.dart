// Persistent configuration for the conference integration.
//
// Follows the same pattern as [VoiceAgentConfig], [TtsConfig], etc.

enum ConferenceProviderType { none, basic, onDevice }

class ConferenceConfig {
  final ConferenceProviderType provider;

  /// When true the platform accepts SIP UPDATE for hold/unhold; when false a
  /// re-INVITE is sent instead.  Only relevant for [ConferenceProviderType.basic].
  final bool basicSupportsUpdate;

  /// When true a full SDP renegotiation (re-INVITE) is sent after the
  /// REFER-based merge completes.  Only relevant for [ConferenceProviderType.basic].
  final bool basicRenegotiateMedia;

  const ConferenceConfig({
    this.provider = ConferenceProviderType.none,
    this.basicSupportsUpdate = false,
    this.basicRenegotiateMedia = false,
  });

  bool get isConfigured {
    switch (provider) {
      case ConferenceProviderType.none:
        return false;
      case ConferenceProviderType.basic:
      case ConferenceProviderType.onDevice:
        return true;
    }
  }

  ConferenceConfig copyWith({
    ConferenceProviderType? provider,
    bool? basicSupportsUpdate,
    bool? basicRenegotiateMedia,
  }) {
    return ConferenceConfig(
      provider: provider ?? this.provider,
      basicSupportsUpdate: basicSupportsUpdate ?? this.basicSupportsUpdate,
      basicRenegotiateMedia:
          basicRenegotiateMedia ?? this.basicRenegotiateMedia,
    );
  }
}
