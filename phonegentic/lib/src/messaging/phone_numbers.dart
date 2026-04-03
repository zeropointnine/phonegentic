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
