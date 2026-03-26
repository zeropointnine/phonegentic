import 'package:phonegentic/src/user_state/sip_user.dart';
import 'package:sip_ua/sip_ua.dart';

class TestCredentials {
  static SipUser get sipUser => _telnyx;

  static String telnyxUsername = '';
  static String telnyxPassword = '';

  /// Telnyx (WebSocket)
  static SipUser get _telnyx => SipUser(
        host: '',
        wsUrl: '',
        selectedTransport: TransportType.WS,
        wsExtraHeaders: {},
        sipUri: '$telnyxUsername@sip.telnyx.com',
        port: '7443',
        displayName: '',
        password: telnyxPassword,
        authUser: telnyxUsername,
      );
}
