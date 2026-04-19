import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM + PBKDF2 encryption for settings export/import.
///
/// Envelope format (version 2, encrypted):
/// ```json
/// {
///   "app": "phonegentic",
///   "version": 2,
///   "encrypted": true,
///   "salt": "<base64 16 bytes>",
///   "iv": "<base64 12 bytes>",
///   "ciphertext": "<base64 AES-GCM ciphertext + MAC tag>"
/// }
/// ```
class SettingsCrypto {
  SettingsCrypto._();

  static const int _pbkdf2Iterations = 100000;
  static const int _saltBytes = 16;
  static const int _keyBits = 256;

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _pbkdf2Iterations,
    bits: _keyBits,
  );

  static final _aesGcm = AesGcm.with256bits();

  /// Encrypt plaintext JSON bytes with [password].
  /// Returns the encrypted envelope as a JSON-serialisable map.
  static Future<Map<String, dynamic>> encrypt(
    Uint8List plaintext,
    String password,
  ) async {
    final rng = Random.secure();
    final salt = Uint8List(_saltBytes)..setAll(0, List.generate(_saltBytes, (_) => rng.nextInt(256)));
    final iv = _aesGcm.newNonce();

    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );

    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: iv,
    );

    // Concatenate ciphertext + MAC for a single base64 field
    final combined = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return {
      'app': 'phonegentic',
      'version': 2,
      'encrypted': true,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'ciphertext': base64Encode(combined),
    };
  }

  /// Decrypt an encrypted envelope map using [password].
  /// Returns the original plaintext bytes.
  /// Throws [SecretBoxAuthenticationError] on wrong password / tampered data.
  static Future<Uint8List> decrypt(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    final salt = base64Decode(envelope['salt'] as String);
    final iv = base64Decode(envelope['iv'] as String);
    final combined = base64Decode(envelope['ciphertext'] as String);

    if (combined.length < 16) {
      throw const FormatException('Ciphertext too short');
    }

    final cipherText = combined.sublist(0, combined.length - 16);
    final macBytes = combined.sublist(combined.length - 16);

    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );

    final secretBox = SecretBox(
      cipherText,
      nonce: iv,
      mac: Mac(macBytes),
    );

    final plaintext = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plaintext);
  }

  /// Returns `true` if the envelope map indicates encrypted content.
  static bool isEncrypted(Map<String, dynamic> envelope) {
    return envelope['encrypted'] == true;
  }
}
