// Provider-agnostic interface for SIP conference bridging.
//
// Each SIP provider (Telnyx, Twilio, Vonage, etc.) implements this
// interface with its own REST API calls.  The [ConferenceService]
// delegates all server-side operations through this abstraction.

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

/// Minimal info returned when looking up active calls on the provider.
class ActiveCallInfo {
  final String callControlId;
  final String? from;
  final String? to;
  final int? durationSeconds;
  final String? createdAt;
  final String? callSessionId;
  final String? callLegId;

  const ActiveCallInfo({
    required this.callControlId,
    this.from,
    this.to,
    this.durationSeconds,
    this.createdAt,
    this.callSessionId,
    this.callLegId,
  });

  @override
  String toString() =>
      'ActiveCallInfo(ccid: $callControlId, from: $from, to: $to, '
      'session: $callSessionId, leg: $callLegId)';
}

/// Result of creating a conference bridge.
class ConferenceBridge {
  final String conferenceId;
  final String name;

  const ConferenceBridge({required this.conferenceId, required this.name});
}

/// A participant currently in a conference.
class ConferenceParticipant {
  final String callControlId;
  final String? callLegId;
  final String? callSessionId;
  final bool muted;
  final bool onHold;
  final String? status;

  const ConferenceParticipant({
    required this.callControlId,
    this.callLegId,
    this.callSessionId,
    this.muted = false,
    this.onHold = false,
    this.status,
  });

  @override
  String toString() =>
      'ConferenceParticipant(ccid: $callControlId, session: $callSessionId, '
      'leg: $callLegId, status: $status)';
}

// ---------------------------------------------------------------------------
// Abstract provider
// ---------------------------------------------------------------------------

abstract class ConferenceProvider {
  /// Human-readable name shown in settings UI (e.g. "Telnyx").
  String get providerName;

  /// Machine key used for persistence (e.g. "telnyx").
  String get providerId;

  /// Whether the provider has enough credentials to operate.
  bool get isConfigured;

  /// Look up all currently-active call legs on the connection so we can
  /// resolve SIP call IDs to provider-specific control IDs.
  Future<List<ActiveCallInfo>> lookupActiveCalls();

  /// Create a new conference bridge, seeding it with [callControlId]
  /// as the first participant.
  Future<ConferenceBridge> createConference(
    String callControlId, {
    String? name,
  });

  /// Join an existing call leg into an active conference.
  Future<void> joinConference(String conferenceId, String callControlId);

  /// Put a single participant on hold within the conference.
  Future<void> holdParticipant(String conferenceId, String callControlId);

  /// Resume a held participant within the conference.
  Future<void> unholdParticipant(String conferenceId, String callControlId);

  /// Remove a participant from the conference (they stay on their own leg).
  Future<void> removeParticipant(String conferenceId, String callControlId);

  /// List all current participants in the conference.
  Future<List<ConferenceParticipant>> listParticipants(String conferenceId);
}
