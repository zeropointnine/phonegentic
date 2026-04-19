# Encrypted Settings Export/Import

## Problem

Settings exports contain API keys, SIP passwords, and tokens as plaintext JSON. Sharing a backup or storing it in the cloud leaks every credential in the file.

## Solution

Added optional password-based encryption to the export/import flow using **AES-256-GCM** (authenticated encryption) with **PBKDF2** key derivation (HMAC-SHA256, 100k iterations, 16-byte salt → 256-bit key). Fully backward-compatible: unencrypted (version 1) files are imported without any password prompt.

**Export flow:** After building the JSON payload, a dialog asks for an optional encryption password (with confirmation). If provided, the plaintext is encrypted and wrapped in a version-2 envelope containing base64-encoded salt, IV, and ciphertext+MAC. If skipped, the original plaintext JSON is written.

**Import flow:** On file open, the envelope is checked for `"encrypted": true`. If encrypted, a password prompt appears. Decryption failures (wrong password / tampered data) surface a snackbar and abort the import. For `importAll` archives, the password is prompted once and reused across all section files.

**Envelope format (encrypted):**
```json
{
  "app": "phonegentic",
  "version": 2,
  "encrypted": true,
  "salt": "<base64 16 bytes>",
  "iv": "<base64 12 bytes>",
  "ciphertext": "<base64 AES-GCM ciphertext + MAC tag>"
}
```

## Files

- **New:** `phonegentic/lib/src/settings_crypto.dart` — `SettingsCrypto` utility with `encrypt`, `decrypt`, and `isEncrypted`
- **Modified:** `phonegentic/pubspec.yaml` — added `cryptography` dependency
- **Modified:** `phonegentic/lib/src/settings_port_service.dart` — password dialogs, `_maybeEncrypt`/`_maybeDecrypt` helpers, and encryption/decryption hooks in `exportSection`, `exportAll`, `importSection`, and `importAll`
