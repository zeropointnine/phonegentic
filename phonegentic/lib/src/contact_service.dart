import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'db/call_history_db.dart';

class ImportConflict {
  final Map<String, dynamic> localContact;
  final String macosContactId;
  final String macosDisplayName;
  final String macosPhone;
  final String? macosEmail;
  final String? macosCompany;
  final String? macosThumbnailPath;

  const ImportConflict({
    required this.localContact,
    required this.macosContactId,
    required this.macosDisplayName,
    required this.macosPhone,
    this.macosEmail,
    this.macosCompany,
    this.macosThumbnailPath,
  });
}

class ImportResult {
  final int newCount;
  final int updatedCount;
  final int conflictCount;

  const ImportResult({
    required this.newCount,
    required this.updatedCount,
    required this.conflictCount,
  });
}

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

  // Merge review state
  List<ImportConflict> _conflicts = [];
  bool _isReviewMode = false;
  int _selectedConflictIndex = -1;
  int _importedNewCount = 0;
  int _importedUpdatedCount = 0;
  int _resolvedCount = 0;

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

  // Merge review getters
  List<ImportConflict> get conflicts => _conflicts;
  bool get isReviewMode => _isReviewMode;
  int get selectedConflictIndex => _selectedConflictIndex;
  ImportConflict? get selectedConflict =>
      _selectedConflictIndex >= 0 && _selectedConflictIndex < _conflicts.length
          ? _conflicts[_selectedConflictIndex]
          : null;
  int get importedNewCount => _importedNewCount;
  int get importedUpdatedCount => _importedUpdatedCount;
  int get resolvedCount => _resolvedCount;

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
    _isReviewMode = false;
    _conflicts = [];
    _selectedConflictIndex = -1;
    notifyListeners();
  }

  void toggleContacts() {
    if (_isOpen) {
      closeContacts();
    } else {
      openContacts();
    }
  }

  /// Import contacts from macOS Contacts.app with three-tier categorization:
  /// - Linked: already has macos_contact_id → auto-update
  /// - New: no local phone match → auto-import
  /// - Conflict: phone match but no macos_contact_id link → queue for review
  ///
  /// Returns null on error, or an [ImportResult] with counts.
  Future<ImportResult?> importFromMacOS() async {
    _importError = null;
    _isImporting = true;
    _conflicts = [];
    _selectedConflictIndex = -1;
    _isReviewMode = false;
    _importedNewCount = 0;
    _importedUpdatedCount = 0;
    _resolvedCount = 0;
    notifyListeners();

    try {
      late final List<Contact> nativeContacts;
      try {
        nativeContacts = await FlutterContacts.getAll(
          properties: {
            ContactProperty.name,
            ContactProperty.phone,
            ContactProperty.email,
            ContactProperty.organization,
            ContactProperty.photoThumbnail,
          },
        );
      } catch (e) {
        debugPrint('[ContactService] getAll failed (permission?): $e');
        _importError = 'Contacts permission denied. '
            'Open System Settings > Privacy & Security > Contacts to grant access.';
        _isImporting = false;
        notifyListeners();
        FlutterContacts.permissions.openSettings();
        return null;
      }

      final thumbDir = await _thumbnailDir();
      await thumbDir.create(recursive: true);

      await loadAll();
      final localUnlinked = <String, Map<String, dynamic>>{};
      for (final c in _contacts) {
        if (c['macos_contact_id'] != null) continue;
        final phone = c['phone_number'] as String? ?? '';
        if (phone.isEmpty) continue;
        final norm = CallHistoryDb.normalizePhone(phone);
        if (norm.isNotEmpty) localUnlinked[norm] = c;
      }

      int newCount = 0;
      int updatedCount = 0;
      final pendingConflicts = <ImportConflict>[];

      for (final c in nativeContacts) {
        final macId = c.id;
        if (macId == null) continue;
        final displayName = c.displayName ?? '';
        if (displayName.isEmpty) continue;

        final phone = c.phones.isNotEmpty ? c.phones.first.number : '';
        final email = c.emails.isNotEmpty ? c.emails.first.address : null;
        final company =
            c.organizations.isNotEmpty ? c.organizations.first.name : null;

        String? thumbnailPath;
        final thumbBytes = c.photo?.thumbnail;
        if (thumbBytes != null && thumbBytes.isNotEmpty) {
          try {
            final file = File(p.join(thumbDir.path, '$macId.jpg'));
            await file.writeAsBytes(thumbBytes);
            thumbnailPath = file.path;
          } catch (e) {
            debugPrint('[ContactService] thumbnail save failed for $macId: $e');
          }
        }

        // Tier 1: already linked by macos_contact_id → auto-update
        final existingLinked = _contacts.any(
            (lc) => lc['macos_contact_id'] == macId);
        if (existingLinked) {
          await CallHistoryDb.upsertByMacosContactId(
            macosContactId: macId,
            displayName: displayName,
            phoneNumber: phone,
            email: email,
            company: company,
            thumbnailPath: thumbnailPath,
          );
          updatedCount++;
          continue;
        }

        // Tier 2/3: check for phone match among unlinked local contacts
        final normalizedPhone = phone.isNotEmpty
            ? CallHistoryDb.normalizePhone(phone)
            : '';
        final localMatch = normalizedPhone.isNotEmpty
            ? localUnlinked[normalizedPhone]
            : null;

        if (localMatch != null) {
          // Tier 3: conflict — phone match but no macos_contact_id link
          pendingConflicts.add(ImportConflict(
            localContact: localMatch,
            macosContactId: macId,
            macosDisplayName: displayName,
            macosPhone: phone,
            macosEmail: email,
            macosCompany: company,
            macosThumbnailPath: thumbnailPath,
          ));
          // Remove from unlinked so a second macOS contact with the same
          // number doesn't double-conflict against the same local row.
          localUnlinked.remove(normalizedPhone);
        } else {
          // Tier 2: new — no local match, auto-import
          await CallHistoryDb.upsertByMacosContactId(
            macosContactId: macId,
            displayName: displayName,
            phoneNumber: phone,
            email: email,
            company: company,
            thumbnailPath: thumbnailPath,
          );
          newCount++;
        }
      }

      await loadAll();
      _importedNewCount = newCount;
      _importedUpdatedCount = updatedCount;
      _isImporting = false;

      if (pendingConflicts.isNotEmpty) {
        _conflicts = pendingConflicts;
        _isReviewMode = true;
        _resolvedCount = 0;
      }

      notifyListeners();
      return ImportResult(
        newCount: newCount,
        updatedCount: updatedCount,
        conflictCount: pendingConflicts.length,
      );
    } catch (e) {
      debugPrint('[ContactService] importFromMacOS failed: $e');
      _importError = 'Import failed: $e';
      _isImporting = false;
      notifyListeners();
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Merge review: selection
  // ---------------------------------------------------------------------------

  void selectConflict(int index) {
    _selectedConflictIndex = index;
    notifyListeners();
  }

  void deselectConflict() {
    _selectedConflictIndex = -1;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Merge review: resolution actions
  // ---------------------------------------------------------------------------

  /// Keep local data, just link the macOS ID so future imports don't conflict.
  Future<void> resolveKeepLocal(ImportConflict conflict) async {
    final localId = conflict.localContact['id'] as int;
    await CallHistoryDb.linkMacosContactId(localId, conflict.macosContactId);
    // Save the macOS thumbnail if local has none
    if (conflict.macosThumbnailPath != null &&
        (conflict.localContact['thumbnail_path'] as String? ?? '').isEmpty) {
      await CallHistoryDb.updateContact(
          localId, {'thumbnail_path': conflict.macosThumbnailPath});
    }
    _removeConflict(conflict);
  }

  /// Overwrite local with macOS data and link the ID.
  Future<void> resolveUseMacOS(ImportConflict conflict) async {
    final localId = conflict.localContact['id'] as int;
    await CallHistoryDb.updateContact(localId, {
      'display_name': conflict.macosDisplayName,
      'phone_number': conflict.macosPhone,
      if (conflict.macosEmail != null) 'email': conflict.macosEmail,
      if (conflict.macosCompany != null) 'company': conflict.macosCompany,
      if (conflict.macosThumbnailPath != null)
        'thumbnail_path': conflict.macosThumbnailPath,
      'macos_contact_id': conflict.macosContactId,
    });
    _removeConflict(conflict);
  }

  /// Merge with per-field selections and link the ID.
  /// [fields] maps field names to values chosen by the user.
  Future<void> resolveMerge(
      ImportConflict conflict, Map<String, String?> fields) async {
    final localId = conflict.localContact['id'] as int;
    final updates = <String, dynamic>{
      'macos_contact_id': conflict.macosContactId,
    };
    for (final entry in fields.entries) {
      if (entry.value != null) updates[entry.key] = entry.value;
    }
    if (conflict.macosThumbnailPath != null &&
        !updates.containsKey('thumbnail_path')) {
      updates['thumbnail_path'] = conflict.macosThumbnailPath;
    }
    await CallHistoryDb.updateContact(localId, updates);
    _removeConflict(conflict);
  }

  /// Import the macOS contact as a separate entry (no merge).
  Future<void> resolveKeepBoth(ImportConflict conflict) async {
    await CallHistoryDb.upsertByMacosContactId(
      macosContactId: conflict.macosContactId,
      displayName: conflict.macosDisplayName,
      phoneNumber: conflict.macosPhone,
      email: conflict.macosEmail,
      company: conflict.macosCompany,
      thumbnailPath: conflict.macosThumbnailPath,
    );
    _removeConflict(conflict);
  }

  void _removeConflict(ImportConflict conflict) {
    _conflicts.remove(conflict);
    _resolvedCount++;
    _selectedConflictIndex = -1;

    if (_conflicts.isEmpty) {
      _isReviewMode = false;
    }

    loadAll();
    notifyListeners();
  }

  void exitReviewMode() {
    _isReviewMode = false;
    _conflicts = [];
    _selectedConflictIndex = -1;
    notifyListeners();
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

  static Future<Directory> _thumbnailDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(p.join(dir.path, 'phonegentic', 'contact_thumbnails'));
  }
}
