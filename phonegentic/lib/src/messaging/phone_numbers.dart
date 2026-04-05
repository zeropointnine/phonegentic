import 'dart:convert';

/// Normalize a phone number to E.164 for carrier APIs.
String ensureE164(String number) {
  var n = number.replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
  if (n.startsWith('+')) return n;
  if (RegExp(r'^\d{10}$').hasMatch(n)) {
    return '+1$n';
  }
  if (n.length == 11 && n.startsWith('1')) {
    return '+$n';
  }
  if (n.isNotEmpty) {
    return '+$n';
  }
  return n;
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
