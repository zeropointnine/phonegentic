// Persistent configuration for the conference integration.
//
// Follows the same pattern as [VoiceAgentConfig], [TtsConfig], etc.

enum ConferenceProviderType { none, basic, telnyx }

class ConferenceConfig {
  final ConferenceProviderType provider;
  final String telnyxApiKey;
  final String telnyxConnectionId;

  /// Webhook URL for the Call Control App.  Telnyx sends call-control events
  /// (including B-leg `call.initiated`) to this URL.  The Rust relay server
  /// at this URL broadcasts events over WebSocket so the Flutter app can
  /// discover B-leg call_control_ids for conference joining.
  final String telnyxWebhookUrl;

  /// When true the platform accepts SIP UPDATE for hold/unhold; when false a
  /// re-INVITE is sent instead.  Only relevant for [ConferenceProviderType.basic].
  final bool basicSupportsUpdate;

  /// When true a full SDP renegotiation (re-INVITE) is sent after the
  /// REFER-based merge completes.  Only relevant for [ConferenceProviderType.basic].
  final bool basicRenegotiateMedia;

  const ConferenceConfig({
    this.provider = ConferenceProviderType.none,
    this.telnyxApiKey = '',
    this.telnyxConnectionId = '',
    this.telnyxWebhookUrl = '',
    this.basicSupportsUpdate = false,
    this.basicRenegotiateMedia = false,
  });

  bool get isConfigured {
    switch (provider) {
      case ConferenceProviderType.none:
        return false;
      case ConferenceProviderType.basic:
        return true;
      case ConferenceProviderType.telnyx:
        return telnyxApiKey.isNotEmpty && telnyxConnectionId.isNotEmpty;
    }
  }

  ConferenceConfig copyWith({
    ConferenceProviderType? provider,
    String? telnyxApiKey,
    String? telnyxConnectionId,
    String? telnyxWebhookUrl,
    bool? basicSupportsUpdate,
    bool? basicRenegotiateMedia,
  }) {
    return ConferenceConfig(
      provider: provider ?? this.provider,
      telnyxApiKey: telnyxApiKey ?? this.telnyxApiKey,
      telnyxConnectionId: telnyxConnectionId ?? this.telnyxConnectionId,
      telnyxWebhookUrl: telnyxWebhookUrl ?? this.telnyxWebhookUrl,
      basicSupportsUpdate: basicSupportsUpdate ?? this.basicSupportsUpdate,
      basicRenegotiateMedia:
          basicRenegotiateMedia ?? this.basicRenegotiateMedia,
    );
  }
}
