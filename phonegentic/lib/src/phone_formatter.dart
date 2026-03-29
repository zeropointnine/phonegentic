/// Real-time phone number formatter with ISO country-code mask detection.
///
/// Display-only: raw digits in the TextEditingController are never mutated.
/// Call [format] to get a human-readable string; the underlying dial string
/// stays pristine for SIP.
class PhoneFormatter {
  PhoneFormatter._();

  /// Format [raw] for display. Applies country-specific mask once the digit
  /// count exceeds 4. If the number starts with '+' or contains more digits
  /// than the default national length, the country code is auto-detected.
  static String format(String raw, {String defaultCC = '1'}) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length <= 4) return raw;

    final hasPlus = raw.startsWith('+');

    String cc;
    String national;

    if (hasPlus || digits.length > (_formats[defaultCC]?.nationalLen ?? 10)) {
      final match = _detectCC(digits);
      cc = match[0];
      national = match[1];
    } else {
      cc = defaultCC;
      national = digits;
    }

    final fmt = _formats[cc];
    if (fmt == null) return hasPlus ? '+$digits' : raw;

    final showCC = hasPlus || digits.length > fmt.nationalLen;
    return _applyMask(national, fmt.mask, cc, showCC);
  }

  // Longest-prefix match: try 3-digit, 2-digit, then 1-digit codes.
  static List<String> _detectCC(String digits) {
    for (int len = 3; len >= 1; len--) {
      if (digits.length > len) {
        final prefix = digits.substring(0, len);
        if (_formats.containsKey(prefix)) {
          return [prefix, digits.substring(len)];
        }
      }
    }
    return ['1', digits];
  }

  static String _applyMask(
      String digits, String mask, String cc, bool showCC) {
    final buf = StringBuffer();
    if (showCC) buf.write('+$cc ');

    int di = 0;
    for (int i = 0; i < mask.length && di < digits.length; i++) {
      if (mask[i] == '#') {
        buf.write(digits[di++]);
      } else {
        buf.write(mask[i]);
      }
    }
    while (di < digits.length) {
      buf.write(digits[di++]);
    }

    return buf.toString();
  }

  static const Map<String, _Fmt> _formats = {
    // North America
    '1': _Fmt('US/CA', '(###) ###-####', 10),

    // Europe
    '44': _Fmt('GB', '#### ### ####', 10),
    '33': _Fmt('FR', '# ## ## ## ##', 9),
    '49': _Fmt('DE', '#### #######', 11),
    '39': _Fmt('IT', '### ### ####', 10),
    '34': _Fmt('ES', '### ## ## ##', 9),
    '31': _Fmt('NL', '# ## ## ## ##', 9),
    '32': _Fmt('BE', '### ## ## ##', 9),
    '46': _Fmt('SE', '## ### ## ##', 9),
    '47': _Fmt('NO', '### ## ###', 8),
    '45': _Fmt('DK', '## ## ## ##', 8),
    '41': _Fmt('CH', '## ### ## ##', 9),
    '43': _Fmt('AT', '#### ######', 10),
    '48': _Fmt('PL', '### ### ###', 9),
    '351': _Fmt('PT', '### ### ###', 9),
    '353': _Fmt('IE', '## ### ####', 9),
    '30': _Fmt('GR', '### ### ####', 10),
    '36': _Fmt('HU', '## ### ####', 9),
    '420': _Fmt('CZ', '### ### ###', 9),
    '421': _Fmt('SK', '### ### ###', 9),
    '40': _Fmt('RO', '### ### ###', 9),
    '359': _Fmt('BG', '### ### ###', 9),
    '385': _Fmt('HR', '## ### ####', 9),
    '381': _Fmt('RS', '## ### ####', 9),
    '386': _Fmt('SI', '## ### ###', 8),
    '358': _Fmt('FI', '## ### ## ##', 9),
    '370': _Fmt('LT', '### ## ###', 8),
    '371': _Fmt('LV', '## ### ###', 8),
    '372': _Fmt('EE', '#### ####', 8),
    '380': _Fmt('UA', '## ### ## ##', 9),
    '375': _Fmt('BY', '## ### ## ##', 9),
    '7': _Fmt('RU/KZ', '### ###-##-##', 10),

    // Middle East
    '90': _Fmt('TR', '### ### ## ##', 10),
    '972': _Fmt('IL', '##-###-####', 9),
    '971': _Fmt('AE', '## ### ####', 9),
    '966': _Fmt('SA', '## ### ####', 9),
    '974': _Fmt('QA', '#### ####', 8),
    '973': _Fmt('BH', '#### ####', 8),
    '968': _Fmt('OM', '#### ####', 8),
    '962': _Fmt('JO', '# #### ####', 9),
    '961': _Fmt('LB', '## ### ###', 8),

    // Asia-Pacific
    '81': _Fmt('JP', '##-####-####', 10),
    '82': _Fmt('KR', '##-####-####', 10),
    '86': _Fmt('CN', '### #### ####', 11),
    '91': _Fmt('IN', '##### #####', 10),
    '65': _Fmt('SG', '#### ####', 8),
    '852': _Fmt('HK', '#### ####', 8),
    '886': _Fmt('TW', '### ### ###', 9),
    '66': _Fmt('TH', '## ### ####', 9),
    '84': _Fmt('VN', '## ### ## ##', 9),
    '60': _Fmt('MY', '##-### ####', 9),
    '62': _Fmt('ID', '### #### ####', 11),
    '63': _Fmt('PH', '### ### ####', 10),
    '61': _Fmt('AU', '#### ### ###', 9),
    '64': _Fmt('NZ', '## ### ####', 9),
    '977': _Fmt('NP', '### ### ####', 10),
    '94': _Fmt('LK', '## ### ####', 9),
    '92': _Fmt('PK', '### ### ####', 10),
    '880': _Fmt('BD', '#### ### ###', 10),
    '95': _Fmt('MM', '# ### ####', 8),
    '855': _Fmt('KH', '## ### ####', 9),
    '856': _Fmt('LA', '## ## ### ###', 10),

    // Americas
    '55': _Fmt('BR', '## #####-####', 11),
    '52': _Fmt('MX', '## #### ####', 10),
    '57': _Fmt('CO', '### ### ####', 10),
    '56': _Fmt('CL', '# #### ####', 9),
    '54': _Fmt('AR', '## ####-####', 10),
    '51': _Fmt('PE', '### ### ###', 9),
    '58': _Fmt('VE', '### ### ####', 10),
    '593': _Fmt('EC', '## ### ####', 9),
    '591': _Fmt('BO', '#### ####', 8),
    '595': _Fmt('PY', '### ### ###', 9),
    '598': _Fmt('UY', '## ### ###', 8),
    '506': _Fmt('CR', '#### ####', 8),
    '507': _Fmt('PA', '#### ####', 8),
    '503': _Fmt('SV', '#### ####', 8),
    '502': _Fmt('GT', '#### ####', 8),

    // Africa
    '27': _Fmt('ZA', '## ### ####', 9),
    '20': _Fmt('EG', '### ### ####', 10),
    '234': _Fmt('NG', '### ### ####', 10),
    '254': _Fmt('KE', '### ######', 9),
    '255': _Fmt('TZ', '### ### ###', 9),
    '256': _Fmt('UG', '### ### ###', 9),
    '233': _Fmt('GH', '### ### ###', 9),
    '225': _Fmt('CI', '## ## ## ## ##', 10),
    '212': _Fmt('MA', '## #### ####', 9),
    '213': _Fmt('DZ', '### ## ## ##', 9),
    '216': _Fmt('TN', '## ### ###', 8),
    '251': _Fmt('ET', '## ### ####', 9),
  };
}

class _Fmt {
  final String iso;
  final String mask;
  final int nationalLen;
  const _Fmt(this.iso, this.mask, this.nationalLen);
}
