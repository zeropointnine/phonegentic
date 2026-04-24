import 'dart:convert';

/// Dialing prefix to assume when a phone number arrives without a country
/// code (bare national digits). Defaults to '1' (US/CA) but should be set
/// at app boot to match the configured locale — see
/// [setDefaultCountryCode]. A single source of truth prevents drift between
/// call-ingress, messaging, contacts, and storage layers (which was the
/// root cause of cross-contact mis-attribution — e.g. the "Ron, hey!"
/// greeting that fired on a bare 10-digit inbound caller-ID).
String _defaultCountryCode = '1';

/// Set the default dialing prefix used by [ensureE164] when a raw number
/// has no country code. Should be invoked once at boot from the active
/// [AgentBootContext.defaultCountryCode]. Ignored if [code] is empty.
void setDefaultCountryCode(String code) {
  final digits = code.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) return;
  _defaultCountryCode = digits;
}

/// Current default dialing prefix (read-only).
String get defaultCountryCode => _defaultCountryCode;

/// Normalize a phone number to E.164 for carrier APIs and storage.
///
/// Rules (in order):
/// 1. Empty → empty.
/// 2. Already E.164 (starts with `+`) → strip formatting and return.
/// 3. National-length digits for the default country → prepend `+<cc>`.
/// 4. Digits starting with the default country code and matching
///    `<cc-digits> + <national-length>` → prepend `+`.
/// 5. Any other non-empty digit string → prepend `+` (best-effort — the
///    caller is responsible for typing a recognizable international form).
String ensureE164(String number) {
  var n = number.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
  if (n.isEmpty) return n;
  if (n.startsWith('+')) {
    final digits = n.substring(1).replaceAll(RegExp(r'[^\d]'), '');
    return digits.isEmpty ? '' : '+$digits';
  }

  final digits = n.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) return '';

  final cc = _defaultCountryCode;
  final info = _localeInfo[cc] ?? _localeInfo['1']!;
  final nationalLen = info.nationalLen;

  if (digits.length == nationalLen) {
    return '+$cc$digits';
  }
  if (digits.length == cc.length + nationalLen && digits.startsWith(cc)) {
    return '+$digits';
  }
  return '+$digits';
}

/// Return a JSON-encoded description of the phone locale for the given
/// [countryCode] (dialing prefix, e.g. "1" for US/CA).  The agent can call
/// check_locale to get this at runtime.
String describeLocale(String countryCode) {
  final info = _localeInfo[countryCode] ?? _localeInfo['1']!;
  final now = DateTime.now();
  return jsonEncode({
    'country_code': countryCode,
    'country': info.iso,
    'national_digit_length': info.nationalLen,
    'format_example': info.example,
    'timezone': now.timeZoneName,
    'sanitization_notes': [
      '${info.nationalLen} bare digits → prepend +$countryCode to get E.164.',
      'Strip spaces, dashes, parentheses, and dots before dialing.',
      'Spoken word-to-digit: zero=0, oh=0, one=1, two/to/too=2, three=3, '
          'four/for=4, five=5, six=6, seven=7, eight=8, nine=9.',
      '"Triple" = repeat next digit 3×, "double" = 2×, "hundred" = 00.',
      '"Area code" and "the number is" are filler — not digits.',
      'If digit count ≠ ${info.nationalLen}, ask the host to repeat.',
    ],
  });
}

const _localeInfo = <String, _Locale>{
  '1':   _Locale('US/CA', 10, '+1 (555) 123-4567'),
  '44':  _Locale('GB',    10, '+44 7911 123456'),
  '33':  _Locale('FR',     9, '+33 6 12 34 56 78'),
  '49':  _Locale('DE',    11, '+49 1512 3456789'),
  '61':  _Locale('AU',     9, '+61 412 345 678'),
  '81':  _Locale('JP',    10, '+81 90-1234-5678'),
  '86':  _Locale('CN',    11, '+86 131 2345 6789'),
  '91':  _Locale('IN',    10, '+91 98765 43210'),
  '52':  _Locale('MX',    10, '+52 55 1234 5678'),
  '55':  _Locale('BR',    11, '+55 11 91234-5678'),
  '82':  _Locale('KR',    10, '+82 10-1234-5678'),
  '7':   _Locale('RU/KZ', 10, '+7 912 345-67-89'),
  '39':  _Locale('IT',    10, '+39 312 345 6789'),
  '34':  _Locale('ES',     9, '+34 612 34 56 78'),
  '65':  _Locale('SG',     8, '+65 9123 4567'),
  '27':  _Locale('ZA',     9, '+27 82 123 4567'),
};

class _Locale {
  final String iso;
  final int nationalLen;
  final String example;
  const _Locale(this.iso, this.nationalLen, this.example);
}
