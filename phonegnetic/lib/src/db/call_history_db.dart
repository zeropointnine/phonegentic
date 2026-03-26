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
    final dbPath = p.join(dir.path, 'phonegnetic', 'call_history.db');
    await Directory(p.dirname(dbPath)).create(recursive: true);

    return databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: 1, onCreate: _onCreate),
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
        macos_contact_id TEXT UNIQUE
      )
    ''');

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

    await db.execute(
        'CREATE INDEX idx_cr_started ON call_records(started_at)');
    await db.execute(
        'CREATE INDEX idx_cr_direction ON call_records(direction)');
    await db.execute('CREATE INDEX idx_cr_status ON call_records(status)');
    await db.execute(
        'CREATE INDEX idx_ct_call ON call_transcripts(call_record_id)');
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
}
