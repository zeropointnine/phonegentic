#!/usr/bin/env dart
/// Creates a stub test_credentials_local.dart if one doesn't exist.
/// Run this before your first build:
///   dart tool/ensure_credentials.dart
///
/// The generated file has empty credentials so the app compiles but
/// won't auto-register to any SIP provider until you fill them in.
import 'dart:io';

const _target = 'lib/src/test_credentials_local.dart';

const _stub = r"""import 'package:phonegentic/src/user_state/sip_user.dart';
import 'package:sip_ua/sip_ua.dart';

class TestCredentials {
  static SipUser get sipUser => _sipUser;
  static String username = '';
  static String password = '';
  static String hostname = '';

  static SipUser get _sipUser => SipUser(
        host: hostname,
        wsUrl: 'wss://$hostname:19306/ws',
        selectedTransport: TransportType.WS,
        wsExtraHeaders: {},
        sipUri: '$username@$hostname',
        port: '15066',
        displayName: '',
        password: password,
        authUser: username,
      );
}
""";

void main() {
  final file = File(_target);
  if (file.existsSync()) {
    print('✓ $_target already exists — skipping.');
    return;
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(_stub);
  print('✓ Created $_target with empty credentials.');
  print('  Fill in your SIP username/password/hostname to enable auto-register.');
}
