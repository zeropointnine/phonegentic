import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'db/call_history_db.dart';

class ContactService extends ChangeNotifier {
  List<Map<String, dynamic>> _contacts = [];
  Map<String, dynamic>? _selectedContact;
  bool _isOpen = false;
  bool _isQuickAddOpen = false;
  bool _isLoading = false;
  bool _isImporting = false;
  String _searchQuery = '';
  String? _importError;
  bool _autoFocusName = false;
  String? _multipleMatchMessage;

  /// Cached phone->contact lookup (normalized phone -> contact map).
  final Map<String, Map<String, dynamic>> _phoneCache = {};

  List<Map<String, dynamic>> get contacts => _contacts;
  Map<String, dynamic>? get selectedContact => _selectedContact;
  bool get isOpen => _isOpen;
  bool get isQuickAddOpen => _isQuickAddOpen;
  bool get isLoading => _isLoading;
  bool get isImporting => _isImporting;
  String get searchQuery => _searchQuery;
  String? get importError => _importError;
  bool get autoFocusName => _autoFocusName;
  String? get multipleMatchMessage => _multipleMatchMessage;

  ContactService() {
    loadAll();
  }

  Future<void> loadAll() async {
    _isLoading = true;
    notifyListeners();
    try {
      _contacts = await CallHistoryDb.getAllContacts();
      _rebuildPhoneCache();
    } catch (e) {
      debugPrint('[ContactService] loadAll failed: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  void _rebuildPhoneCache() {
    _phoneCache.clear();
    for (final c in _contacts) {
      final phone = c['phone_number'] as String? ?? '';
      if (phone.isNotEmpty) {
        final normalized = CallHistoryDb.normalizePhone(phone);
        if (normalized.isNotEmpty) _phoneCache[normalized] = c;
      }
    }
  }

  /// Fast synchronous lookup by phone number. Returns null if no match.
  Map<String, dynamic>? lookupByPhone(String phoneNumber) {
    final normalized = CallHistoryDb.normalizePhone(phoneNumber);
    if (normalized.isEmpty) return null;
    return _phoneCache[normalized];
  }

  /// Fast synchronous autocomplete for the dialpad.
  ///
  /// If [query] is purely digits, matches contacts whose normalized phone
  /// contains the digit sequence. If it contains letters, does a
  /// case-insensitive substring match on display_name, company, and email.
  /// Capped at 8 results for snappy rendering.
  List<Map<String, dynamic>> autocompleteSearch(String query) {
    if (query.length < 2) return [];
    final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(query);

    if (!hasLetters) {
      final stripped = query.replaceAll(RegExp(r'[^\d]'), '');
      if (stripped.length < 3) return [];
      final results = <Map<String, dynamic>>[];
      for (final entry in _phoneCache.entries) {
        if (entry.key.contains(stripped)) {
          results.add(entry.value);
          if (results.length >= 8) break;
        }
      }
      return results;
    }

    final lower = query.toLowerCase();
    final results = <Map<String, dynamic>>[];
    for (final c in _contacts) {
      final name = (c['display_name'] as String? ?? '').toLowerCase();
      final company = (c['company'] as String? ?? '').toLowerCase();
      final email = (c['email'] as String? ?? '').toLowerCase();
      if (name.contains(lower) ||
          company.contains(lower) ||
          email.contains(lower)) {
        results.add(c);
        if (results.length >= 8) break;
      }
    }
    return results;
  }

  /// Returns every contact whose normalized phone matches [phoneNumber].
  List<Map<String, dynamic>> lookupAllByPhone(String phoneNumber) {
    final normalized = CallHistoryDb.normalizePhone(phoneNumber);
    if (normalized.isEmpty) return [];
    return _contacts.where((c) {
      final phone = c['phone_number'] as String? ?? '';
      return phone.isNotEmpty &&
          CallHistoryDb.normalizePhone(phone) == normalized;
    }).toList();
  }

  Future<void> search(String query) async {
    _searchQuery = query;
    _isLoading = true;
    notifyListeners();
    try {
      if (query.trim().isEmpty) {
        _contacts = await CallHistoryDb.getAllContacts();
      } else {
        _contacts = await CallHistoryDb.searchContacts(query);
      }
      _rebuildPhoneCache();
    } catch (e) {
      debugPrint('[ContactService] search failed: $e');
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Infers field type from raw input and creates a minimal contact.
  Future<int> quickAdd(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return -1;

    String displayName = '';
    String phoneNumber = '';
    String? email;

    if (trimmed.contains('@')) {
      email = trimmed;
      displayName = trimmed.split('@').first;
    } else if (_looksLikePhone(trimmed)) {
      phoneNumber = trimmed;
      displayName = trimmed;
    } else {
      displayName = trimmed;
    }

    // Check for duplicate phone
    if (phoneNumber.isNotEmpty) {
      final existing = lookupByPhone(phoneNumber);
      if (existing != null) return existing['id'] as int;
    }

    final id = await CallHistoryDb.insertContact(
      displayName: displayName,
      phoneNumber: phoneNumber,
      email: email,
    );
    await loadAll();
    return id;
  }

  bool _looksLikePhone(String s) {
    final digits = s.replaceAll(RegExp(r'[^\d]'), '');
    return digits.length >= 7 && RegExp(r'^[\d\s\+\-\(\)\.]+$').hasMatch(s);
  }

  Future<void> updateField(int id, String field, String value) async {
    await CallHistoryDb.updateContact(id, {field: value});
    await loadAll();
    if (_selectedContact != null && _selectedContact!['id'] == id) {
      _selectedContact = _contacts.firstWhere(
        (c) => c['id'] == id,
        orElse: () => _selectedContact!,
      );
      notifyListeners();
    }
  }

  Future<void> deleteContact(int id) async {
    await CallHistoryDb.deleteContact(id);
    if (_selectedContact != null && _selectedContact!['id'] == id) {
      _selectedContact = null;
    }
    await loadAll();
  }

  void selectContact(Map<String, dynamic>? contact) {
    _selectedContact = contact;
    _autoFocusName = false;
    _multipleMatchMessage = null;
    notifyListeners();
  }

  /// Opens the contact panel for a phone number.
  /// - No matches: creates a new contact with the phone pre-filled, focuses
  ///   the name field so the user can type a display name and save.
  /// - One match: navigates straight to that contact's detail card.
  /// - Multiple matches: selects the first match and shows a warning banner.
  Future<void> openContactForPhone(String phoneNumber) async {
    debugPrint('[ContactService] openContactForPhone($phoneNumber)');
    _multipleMatchMessage = null;
    _autoFocusName = false;

    final matches = lookupAllByPhone(phoneNumber);
    debugPrint('[ContactService] matches=${matches.length} names=${matches.map((m) => m['display_name']).toList()}');

    if (matches.isEmpty) {
      final id = await CallHistoryDb.insertContact(
        displayName: phoneNumber,
        phoneNumber: phoneNumber,
      );
      await loadAll();
      _selectedContact = _contacts.firstWhere(
        (c) => c['id'] == id,
        orElse: () => {
          'id': id,
          'display_name': phoneNumber,
          'phone_number': phoneNumber,
        },
      );
      _autoFocusName = true;
    } else if (matches.length == 1) {
      _selectedContact = matches.first;
      final name = (matches.first['display_name'] as String? ?? '').trim();
      _autoFocusName = name.isEmpty || _looksLikePhone(name);
    } else {
      _multipleMatchMessage =
          '${matches.length} contacts share this number';
      _selectedContact = matches.first;
      final name = (matches.first['display_name'] as String? ?? '').trim();
      _autoFocusName = name.isEmpty || _looksLikePhone(name);
    }

    _isOpen = true;
    notifyListeners();
  }

  void consumeAutoFocusName() {
    _autoFocusName = false;
  }

  void openContacts() {
    _isOpen = true;
    notifyListeners();
  }

  void closeContacts() {
    _isOpen = false;
    _selectedContact = null;
    _autoFocusName = false;
    _multipleMatchMessage = null;
    notifyListeners();
  }

  void toggleContacts() {
    if (_isOpen) {
      closeContacts();
    } else {
      openContacts();
    }
  }

  /// Import contacts from macOS Contacts.app.
  /// Returns the number of contacts imported/updated, or -1 on error.
  Future<int> importFromMacOS() async {
    _importError = null;
    _isImporting = true;
    notifyListeners();

    try {
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (status != PermissionStatus.granted) {
        _importError = 'Contacts permission denied. '
            'Open System Settings > Privacy & Security > Contacts to grant access.';
        _isImporting = false;
        notifyListeners();
        FlutterContacts.permissions.openSettings();
        return -1;
      }

      final nativeContacts = await FlutterContacts.getAll(
        properties: {
          ContactProperty.name,
          ContactProperty.phone,
          ContactProperty.email,
          ContactProperty.organization,
        },
      );

      int imported = 0;
      for (final c in nativeContacts) {
        final id = c.id;
        if (id == null) continue;
        final displayName = c.displayName ?? '';
        if (displayName.isEmpty) continue;

        final phone =
            c.phones.isNotEmpty ? c.phones.first.number : '';
        final email =
            c.emails.isNotEmpty ? c.emails.first.address : null;
        final company = c.organizations.isNotEmpty
            ? c.organizations.first.name
            : null;

        await CallHistoryDb.upsertByMacosContactId(
          macosContactId: id,
          displayName: displayName,
          phoneNumber: phone,
          email: email,
          company: company,
        );
        imported++;
      }

      await loadAll();
      _isImporting = false;
      notifyListeners();
      return imported;
    } catch (e) {
      debugPrint('[ContactService] importFromMacOS failed: $e');
      _importError = 'Import failed: $e';
      _isImporting = false;
      notifyListeners();
      return -1;
    }
  }

  void clearImportError() {
    _importError = null;
    notifyListeners();
  }

  void openQuickAdd() {
    _isQuickAddOpen = true;
    notifyListeners();
  }

  void closeQuickAdd() {
    _isQuickAddOpen = false;
    notifyListeners();
  }
}
