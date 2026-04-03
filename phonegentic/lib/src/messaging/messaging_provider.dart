import 'models/sms_message.dart';

/// Provider-agnostic contract for SMS/MMS messaging integrations.
///
/// Implementations wrap a specific carrier API (Telnyx, Twilio, Vonage, etc.)
/// while exposing a uniform interface consumed by [MessagingService].
abstract class MessagingProvider {
  String get providerType;

  /// Default outbound sender (E.164 or as stored in settings).
  String get fromNumber;

  /// Send an SMS (or MMS when [mediaUrls] is non-empty).
  Future<SmsMessage> sendMessage({
    required String to,
    required String from,
    required String text,
    List<String>? mediaUrls,
  });

  /// Retrieve a single message by its provider-side ID.
  Future<SmsMessage?> getMessage(String providerId);

  /// Fetch message history, newest first.
  ///
  /// Providers that lack a true "list" endpoint should return records from
  /// their detail-record / reporting APIs.
  Future<List<SmsMessage>> listMessages({
    String? remotePhone,
    DateTime? since,
    DateTime? until,
    SmsDirection? direction,
    int pageSize = 50,
    int page = 1,
  });

  /// Stream of real-time inbound messages (webhook or polling-driven).
  Stream<SmsMessage> get incomingMessages;

  /// Verify that the stored credentials are valid.
  Future<bool> testConnection();

  /// Start listening for inbound messages (webhook server / poll loop).
  Future<void> connect();

  /// Tear down listeners.
  Future<void> disconnect();
}
