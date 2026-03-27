import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class CallHistoryDb {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<void> initialize() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await database;
  }

  static Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'phonegentic', 'call_history.db');
    await Directory(p.dirname(dbPath)).create(recursive: true);

    return databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        display_name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        email TEXT,
        company TEXT,
        thumbnail_path TEXT,
        macos_contact_id TEXT UNIQUE,
        notes TEXT,
        tags TEXT,
        created_at TEXT
      )
    ''');

    await db.execute(
        'CREATE INDEX idx_contacts_phone ON contacts(phone_number)');

    await db.execute('''
      CREATE TABLE call_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id INTEGER REFERENCES contacts(id),
        remote_identity TEXT,
        remote_display_name TEXT,
        local_identity TEXT,
        direction TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        started_at TEXT NOT NULL,
        ended_at TEXT,
        duration_seconds INTEGER DEFAULT 0,
        recording_path TEXT,
        parent_call_id INTEGER REFERENCES call_records(id),
        notes TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE call_transcripts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        call_record_id INTEGER NOT NULL REFERENCES call_records(id),
        role TEXT NOT NULL,
        speaker_name TEXT,
        text TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE tear_sheets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
      )
    ''');

    await db.execute('''
      CREATE TABLE tear_sheet_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tear_sheet_id INTEGER NOT NULL REFERENCES tear_sheets(id),
        position INTEGER NOT NULL,
        phone_number TEXT NOT NULL,
        contact_name TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        call_record_id INTEGER REFERENCES call_records(id),
        notes TEXT
      )
    ''');

    await db.execute(
        'CREATE INDEX idx_cr_started ON call_records(started_at)');
    await db.execute(
        'CREATE INDEX idx_cr_direction ON call_records(direction)');
    await db.execute('CREATE INDEX idx_cr_status ON call_records(status)');
    await db.execute(
        'CREATE INDEX idx_ct_call ON call_transcripts(call_record_id)');
    await db.execute(
        'CREATE INDEX idx_tsi_sheet ON tear_sheet_items(tear_sheet_id)');
  }

  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE contacts ADD COLUMN notes TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN tags TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN created_at TEXT');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_contacts_phone ON contacts(phone_number)');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS tear_sheets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS tear_sheet_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tear_sheet_id INTEGER NOT NULL REFERENCES tear_sheets(id),
          position INTEGER NOT NULL,
          phone_number TEXT NOT NULL,
          contact_name TEXT,
          status TEXT NOT NULL DEFAULT 'pending',
          call_record_id INTEGER REFERENCES call_records(id),
          notes TEXT
        )
      ''');

      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_tsi_sheet ON tear_sheet_items(tear_sheet_id)');
    }
  }

  // ---------------------------------------------------------------------------
  // Call records
  // ---------------------------------------------------------------------------

  static Future<int> insertCallRecord({
    required String direction,
    String? remoteIdentity,
    String? remoteDisplayName,
    String? localIdentity,
    int? contactId,
  }) async {
    final db = await database;
    return db.insert('call_records', {
      'direction': direction,
      'status': 'active',
      'remote_identity': remoteIdentity,
      'remote_display_name': remoteDisplayName,
      'local_identity': localIdentity,
      'contact_id': contactId,
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> finalizeCallRecord(
    int id, {
    required String status,
  }) async {
    final db = await database;
    final records =
        await db.query('call_records', where: 'id = ?', whereArgs: [id]);
    if (records.isEmpty) return;

    final startedAt = DateTime.parse(records.first['started_at'] as String);
    final now = DateTime.now();
    final duration = now.difference(startedAt).inSeconds;

    await db.update(
      'call_records',
      {
        'status': status,
        'ended_at': now.toIso8601String(),
        'duration_seconds': duration,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateRecordingPath(int id, String path) async {
    final db = await database;
    await db.update(
      'call_records',
      {'recording_path': path},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // Transcripts
  // ---------------------------------------------------------------------------

  static Future<void> insertTranscript({
    required int callRecordId,
    required String role,
    String? speakerName,
    required String text,
  }) async {
    final db = await database;
    await db.insert('call_transcripts', {
      'call_record_id': callRecordId,
      'role': role,
      'speaker_name': speakerName,
      'text': text,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<Map<String, dynamic>>> getTranscripts(
      int callRecordId) async {
    final db = await database;
    return db.query(
      'call_transcripts',
      where: 'call_record_id = ?',
      whereArgs: [callRecordId],
      orderBy: 'timestamp ASC',
    );
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> searchCalls({
    String? contactName,
    int? minDurationSeconds,
    int? maxDurationSeconds,
    DateTime? since,
    DateTime? before,
    String? direction,
    String? status,
    int limit = 50,
  }) async {
    final db = await database;

    final where = <String>[];
    final args = <dynamic>[];

    if (contactName != null && contactName.isNotEmpty) {
      where.add('(remote_display_name LIKE ? OR remote_identity LIKE ?)');
      args.addAll(['%$contactName%', '%$contactName%']);
    }
    if (minDurationSeconds != null) {
      where.add('duration_seconds >= ?');
      args.add(minDurationSeconds);
    }
    if (maxDurationSeconds != null) {
      where.add('duration_seconds <= ?');
      args.add(maxDurationSeconds);
    }
    if (since != null) {
      where.add('started_at >= ?');
      args.add(since.toIso8601String());
    }
    if (before != null) {
      where.add('started_at <= ?');
      args.add(before.toIso8601String());
    }
    if (direction != null) {
      where.add('direction = ?');
      args.add(direction);
    }
    if (status != null && status != 'active') {
      where.add('status = ?');
      args.add(status);
    }

    // Exclude currently-active calls from search results
    if (status == null) {
      where.add("status != 'active'");
    }

    return db.query(
      'call_records',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'started_at DESC',
      limit: limit,
    );
  }

  static Future<List<Map<String, dynamic>>> getRecentCalls({
    int limit = 50,
  }) async {
    final db = await database;
    return db.query(
      'call_records',
      where: "status != 'active'",
      orderBy: 'started_at DESC',
      limit: limit,
    );
  }

  // ---------------------------------------------------------------------------
  // Contacts
  // ---------------------------------------------------------------------------

  static String normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length >= 10) return digits.substring(digits.length - 10);
    return digits;
  }

  static Future<int> insertContact({
    required String displayName,
    String phoneNumber = '',
    String? email,
    String? company,
    String? notes,
    String? tags,
  }) async {
    final db = await database;
    return db.insert('contacts', {
      'display_name': displayName,
      'phone_number': phoneNumber,
      'email': email,
      'company': company,
      'notes': notes,
      'tags': tags,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> updateContact(
      int id, Map<String, dynamic> fields) async {
    final db = await database;
    await db.update('contacts', fields, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteContact(int id) async {
    final db = await database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  static Future<Map<String, dynamic>?> getContactByPhone(
      String phoneNumber) async {
    final db = await database;
    final normalized = normalizePhone(phoneNumber);
    if (normalized.isEmpty) return null;
    final results = await db.query('contacts');
    for (final row in results) {
      final stored = normalizePhone(row['phone_number'] as String? ?? '');
      if (stored.isNotEmpty && stored == normalized) return row;
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> searchContacts(
      String query) async {
    final db = await database;
    return db.query(
      'contacts',
      where:
          'display_name LIKE ? OR phone_number LIKE ? OR email LIKE ?',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'display_name ASC',
    );
  }

  static Future<List<Map<String, dynamic>>> getAllContacts() async {
    final db = await database;
    return db.query('contacts', orderBy: 'display_name ASC');
  }

  /// Insert or update a contact keyed by macOS contact ID.
  /// Returns the local row id.
  static Future<int> upsertByMacosContactId({
    required String macosContactId,
    required String displayName,
    String phoneNumber = '',
    String? email,
    String? company,
  }) async {
    final db = await database;
    final existing = await db.query(
      'contacts',
      where: 'macos_contact_id = ?',
      whereArgs: [macosContactId],
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'contacts',
        {
          'display_name': displayName,
          'phone_number': phoneNumber,
          if (email != null) 'email': email,
          if (company != null) 'company': company,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return db.insert('contacts', {
      'display_name': displayName,
      'phone_number': phoneNumber,
      'email': email,
      'company': company,
      'macos_contact_id': macosContactId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> mergeContacts(int sourceId, int targetId) async {
    final db = await database;
    await db.update(
      'call_records',
      {'contact_id': targetId},
      where: 'contact_id = ?',
      whereArgs: [sourceId],
    );
    await db.delete('contacts', where: 'id = ?', whereArgs: [sourceId]);
  }

  // ---------------------------------------------------------------------------
  // Tear Sheets
  // ---------------------------------------------------------------------------

  static Future<int> insertTearSheet({required String name}) async {
    final db = await database;
    return db.insert('tear_sheets', {
      'name': name,
      'created_at': DateTime.now().toIso8601String(),
      'status': 'pending',
    });
  }

  static Future<void> updateTearSheetStatus(int id, String status) async {
    final db = await database;
    await db.update(
      'tear_sheets',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<Map<String, dynamic>?> getTearSheet(int id) async {
    final db = await database;
    final rows =
        await db.query('tear_sheets', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>?> getActiveTearSheet() async {
    final db = await database;
    final rows = await db.query(
      'tear_sheets',
      where: "status IN ('active', 'paused', 'pending')",
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> insertTearSheetItem({
    required int tearSheetId,
    required int position,
    required String phoneNumber,
    String? contactName,
  }) async {
    final db = await database;
    return db.insert('tear_sheet_items', {
      'tear_sheet_id': tearSheetId,
      'position': position,
      'phone_number': phoneNumber,
      'contact_name': contactName,
      'status': 'pending',
    });
  }

  static Future<void> updateTearSheetItemStatus(
      int id, String status, {int? callRecordId}) async {
    final db = await database;
    final fields = <String, dynamic>{'status': status};
    if (callRecordId != null) fields['call_record_id'] = callRecordId;
    await db.update('tear_sheet_items', fields,
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<Map<String, dynamic>>> getTearSheetItems(
      int tearSheetId) async {
    final db = await database;
    return db.query(
      'tear_sheet_items',
      where: 'tear_sheet_id = ?',
      whereArgs: [tearSheetId],
      orderBy: 'position ASC',
    );
  }

  static Future<void> reorderTearSheetItem(int id, int newPosition) async {
    final db = await database;
    await db.update(
      'tear_sheet_items',
      {'position': newPosition},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteTearSheetItem(int id) async {
    final db = await database;
    await db.delete('tear_sheet_items', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteTearSheet(int id) async {
    final db = await database;
    await db.delete('tear_sheet_items',
        where: 'tear_sheet_id = ?', whereArgs: [id]);
    await db.delete('tear_sheets', where: 'id = ?', whereArgs: [id]);
  }
}
