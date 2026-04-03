import 'package:shared_preferences/shared_preferences.dart';

/// Which SMS backend is active when multiple are configured.
enum MessagingBackend { telnyx, twilio }

class MessagingSettings {
  static const _backendKey = 'user_messaging_backend';

  static Future<MessagingBackend> loadBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_backendKey);
    if (v == MessagingBackend.twilio.name) {
      return MessagingBackend.twilio;
    }
    return MessagingBackend.telnyx;
  }

  static Future<void> saveBackend(MessagingBackend backend) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backendKey, backend.name);
  }
}

class TwilioMessagingConfig {
  final String accountSid;
  final String authToken;
  final String fromNumber;
  final String webhookUrl;
  final int pollingIntervalSeconds;

  const TwilioMessagingConfig({
    this.accountSid = '',
    this.authToken = '',
    this.fromNumber = '',
    this.webhookUrl = '',
    this.pollingIntervalSeconds = 15,
  });

  bool get isConfigured =>
      accountSid.isNotEmpty && authToken.isNotEmpty && fromNumber.isNotEmpty;

  TwilioMessagingConfig copyWith({
    String? accountSid,
    String? authToken,
    String? fromNumber,
    String? webhookUrl,
    int? pollingIntervalSeconds,
  }) {
    return TwilioMessagingConfig(
      accountSid: accountSid ?? this.accountSid,
      authToken: authToken ?? this.authToken,
      fromNumber: fromNumber ?? this.fromNumber,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      pollingIntervalSeconds:
          pollingIntervalSeconds ?? this.pollingIntervalSeconds,
    );
  }

  static const _prefix = 'user_twilio_msg_';

  static Future<TwilioMessagingConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TwilioMessagingConfig(
      accountSid: prefs.getString('${_prefix}account_sid') ?? '',
      authToken: prefs.getString('${_prefix}auth_token') ?? '',
      fromNumber: prefs.getString('${_prefix}from_number') ?? '',
      webhookUrl: prefs.getString('${_prefix}webhook_url') ?? '',
      pollingIntervalSeconds:
          prefs.getInt('${_prefix}polling_interval') ?? 15,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}account_sid', accountSid);
    await prefs.setString('${_prefix}auth_token', authToken);
    await prefs.setString('${_prefix}from_number', fromNumber);
    await prefs.setString('${_prefix}webhook_url', webhookUrl);
    await prefs.setInt('${_prefix}polling_interval', pollingIntervalSeconds);
  }
}

class TelnyxMessagingConfig {
  final String apiKey;
  final String fromNumber;
  final String messagingProfileId;
  final String webhookUrl;
  final int pollingIntervalSeconds;

  const TelnyxMessagingConfig({
    this.apiKey = '',
    this.fromNumber = '',
    this.messagingProfileId = '',
    this.webhookUrl = '',
    this.pollingIntervalSeconds = 15,
  });

  bool get isConfigured => apiKey.isNotEmpty && fromNumber.isNotEmpty;

  TelnyxMessagingConfig copyWith({
    String? apiKey,
    String? fromNumber,
    String? messagingProfileId,
    String? webhookUrl,
    int? pollingIntervalSeconds,
  }) {
    return TelnyxMessagingConfig(
      apiKey: apiKey ?? this.apiKey,
      fromNumber: fromNumber ?? this.fromNumber,
      messagingProfileId: messagingProfileId ?? this.messagingProfileId,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      pollingIntervalSeconds:
          pollingIntervalSeconds ?? this.pollingIntervalSeconds,
    );
  }

  static const _prefix = 'user_telnyx_msg_';

  static Future<TelnyxMessagingConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TelnyxMessagingConfig(
      apiKey: prefs.getString('${_prefix}api_key') ?? '',
      fromNumber: prefs.getString('${_prefix}from_number') ?? '',
      messagingProfileId:
          prefs.getString('${_prefix}messaging_profile_id') ?? '',
      webhookUrl: prefs.getString('${_prefix}webhook_url') ?? '',
      pollingIntervalSeconds:
          prefs.getInt('${_prefix}polling_interval') ?? 15,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}api_key', apiKey);
    await prefs.setString('${_prefix}from_number', fromNumber);
    await prefs.setString('${_prefix}messaging_profile_id', messagingProfileId);
    await prefs.setString('${_prefix}webhook_url', webhookUrl);
    await prefs.setInt('${_prefix}polling_interval', pollingIntervalSeconds);
  }
}
