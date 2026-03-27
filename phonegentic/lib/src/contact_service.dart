import 'package:flutter/foundation.dart';

import 'db/call_history_db.dart';

class ContactService extends ChangeNotifier {
  List<Map<String, dynamic>> _contacts = [];
  Map<String, dynamic>? _selectedContact;
  bool _isOpen = false;
  bool _isQuickAddOpen = false;
  bool _isLoading = false;
  String _searchQuery = '';

  /// Cached phone->contact lookup (normalized phone -> contact map).
  final Map<String, Map<String, dynamic>> _phoneCache = {};

  List<Map<String, dynamic>> get contacts => _contacts;
  Map<String, dynamic>? get selectedContact => _selectedContact;
  bool get isOpen => _isOpen;
  bool get isQuickAddOpen => _isQuickAddOpen;
  bool get isLoading => _isLoading;
  String get searchQuery => _searchQuery;

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
    notifyListeners();
  }

  void openContacts() {
    _isOpen = true;
    notifyListeners();
  }

  void closeContacts() {
    _isOpen = false;
    _selectedContact = null;
    notifyListeners();
  }

  void toggleContacts() {
    if (_isOpen) {
      closeContacts();
    } else {
      openContacts();
    }
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
