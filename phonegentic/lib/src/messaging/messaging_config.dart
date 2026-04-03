import 'package:shared_preferences/shared_preferences.dart';

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
