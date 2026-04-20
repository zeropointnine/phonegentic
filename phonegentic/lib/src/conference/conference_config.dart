// Persistent configuration for the conference integration.
//
// Follows the same pattern as [VoiceAgentConfig], [TtsConfig], etc.

enum ConferenceProviderType { none, basic, onDevice }

class ConferenceConfig {
  final ConferenceProviderType provider;

  /// Maximum number of remote call legs allowed in a conference.
  /// Basic (SIP REFER) is inherently limited to 2 regardless of this value.
  final int maxParticipants;

  /// When true the platform accepts SIP UPDATE for hold/unhold; when false a
  /// re-INVITE is sent instead.  Only relevant for [ConferenceProviderType.basic].
  final bool basicSupportsUpdate;

  /// When true a full SDP renegotiation (re-INVITE) is sent after the
  /// REFER-based merge completes.  Only relevant for [ConferenceProviderType.basic].
  final bool basicRenegotiateMedia;

  const ConferenceConfig({
    this.provider = ConferenceProviderType.none,
    this.maxParticipants = 5,
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

  /// Effective max participants, clamped to 2 for basic (SIP REFER).
  int get effectiveMaxParticipants =>
      provider == ConferenceProviderType.basic
          ? maxParticipants.clamp(2, 2)
          : maxParticipants.clamp(2, 10);

  ConferenceConfig copyWith({
    ConferenceProviderType? provider,
    int? maxParticipants,
    bool? basicSupportsUpdate,
    bool? basicRenegotiateMedia,
  }) {
    return ConferenceConfig(
      provider: provider ?? this.provider,
      maxParticipants: maxParticipants ?? this.maxParticipants,
      basicSupportsUpdate: basicSupportsUpdate ?? this.basicSupportsUpdate,
      basicRenegotiateMedia:
          basicRenegotiateMedia ?? this.basicRenegotiateMedia,
    );
  }
}
