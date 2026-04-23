import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/calendar_event.dart';
import '../models/inbound_call_flow.dart';
import '../models/job_function.dart';
import '../models/transfer_rule.dart';

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

    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 22,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    await db.execute('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA busy_timeout = 5000');
    return db;
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
        notes TEXT,
        job_function_id INTEGER REFERENCES job_functions(id)
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

    await _createJobFunctionsTable(db);
    await _seedDefaultJobFunction(db);
    await _createSpeakerEmbeddingsTable(db);
    await _createCalendarEventsTable(db);
    await _createSmsMessagesTable(db);
    await _createInboundCallFlowsTable(db);
    await _createAgentRemindersTable(db);
    await _createTransferRulesTable(db);
    await _createSessionMessagesTable(db);
    await _createPocketTtsVoicesTable(db);
    await _createSmsThreadDeletesTable(db);
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

    if (oldVersion < 3) {
      await _createJobFunctionsTable(db);
      await _seedDefaultJobFunction(db);
    }

    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN whisper_by_default INTEGER NOT NULL DEFAULT 0',
      );
    }

    if (oldVersion < 5) {
      await _createSpeakerEmbeddingsTable(db);
    }

    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN elevenlabs_voice_id TEXT',
      );
    }

    if (oldVersion < 7) {
      await _createCalendarEventsTable(db);
    }

    if (oldVersion < 8) {
      await _createSmsMessagesTable(db);
    }

    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN mute_policy_override INTEGER',
      );
    }

    if (oldVersion < 10) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN agent_name TEXT',
      );
    }

    if (oldVersion < 11) {
      await db.execute(
        'ALTER TABLE sms_messages ADD COLUMN error_reason TEXT',
      );
    }

    if (oldVersion < 12) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN kokoro_voice_style TEXT',
      );
    }

    if (oldVersion < 13) {
      await _createInboundCallFlowsTable(db);
    }

    if (oldVersion < 14) {
      await _createAgentRemindersTable(db);
    }

    if (oldVersion < 15) {
      await _createTransferRulesTable(db);
    }

    if (oldVersion < 16) {
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN comfort_noise_path TEXT',
      );
    }

    if (oldVersion < 17) {
      await _createSessionMessagesTable(db);
    }
    if (oldVersion < 18) {
      await db.execute(
          "ALTER TABLE calendar_events ADD COLUMN source TEXT DEFAULT 'local'");
      await db.execute(
          'ALTER TABLE calendar_events ADD COLUMN google_calendar_event_id TEXT');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_ce_source ON calendar_events(source)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_ce_gcal_id ON calendar_events(google_calendar_event_id)');
    }

    if (oldVersion < 19) {
      await db.execute(
          'ALTER TABLE calendar_events ADD COLUMN locally_modified INTEGER DEFAULT 0');
    }

    if (oldVersion < 20) {
      await _createPocketTtsVoicesTable(db);
      await db.execute(
        'ALTER TABLE job_functions ADD COLUMN pocket_tts_voice_id INTEGER',
      );
    }

    if (oldVersion < 21) {
      await db.execute(
        'ALTER TABLE call_records ADD COLUMN job_function_id INTEGER '
        'REFERENCES job_functions(id)',
      );
    }

    if (oldVersion < 22) {
      await db
          .execute('ALTER TABLE sms_messages ADD COLUMN reactions_json TEXT');
      await db.execute(
          'ALTER TABLE sms_messages ADD COLUMN reply_to_provider_id TEXT');
      await db.execute(
          'ALTER TABLE sms_messages ADD COLUMN reply_to_local_id INTEGER');
      await _createSmsThreadDeletesTable(db);
    }
  }

  static Future<void> _createJobFunctionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS job_functions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        agent_name TEXT,
        role TEXT NOT NULL,
        job_description TEXT NOT NULL,
        speakers_json TEXT NOT NULL,
        guardrails_json TEXT NOT NULL,
        whisper_by_default INTEGER NOT NULL DEFAULT 0,
        elevenlabs_voice_id TEXT,
        kokoro_voice_style TEXT,
        pocket_tts_voice_id INTEGER,
        mute_policy_override INTEGER,
        comfort_noise_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _seedDefaultJobFunction(Database db) async {
    final existing = await db.query('job_functions', limit: 1);
    if (existing.isEmpty) {
      await db.insert('job_functions', JobFunction.triviaDefault().toMap());
    }
  }

  static Future<void> _createSpeakerEmbeddingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS speaker_embeddings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id INTEGER REFERENCES contacts(id),
        embedding BLOB NOT NULL,
        sample_count INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_se_contact ON speaker_embeddings(contact_id)');
  }

  // ---------------------------------------------------------------------------
  // Speaker Embeddings
  // ---------------------------------------------------------------------------

  /// Upsert a speaker embedding for a contact. If one exists, averages the
  /// stored embedding with the new one (running mean) and increments sample_count.
  static Future<void> upsertSpeakerEmbedding({
    required int contactId,
    required List<double> embedding,
  }) async {
    final db = await database;
    final existing = await db.query(
      'speaker_embeddings',
      where: 'contact_id = ?',
      whereArgs: [contactId],
    );

    final now = DateTime.now().toIso8601String();
    final blob = _embeddingToBlob(embedding);

    if (existing.isEmpty) {
      await db.insert('speaker_embeddings', {
        'contact_id': contactId,
        'embedding': blob,
        'sample_count': 1,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      final row = existing.first;
      final oldBlob = row['embedding'] as List<int>;
      final oldEmbed = blobToEmbedding(oldBlob);
      final oldCount = row['sample_count'] as int? ?? 1;
      final newCount = oldCount + 1;

      // Running mean: new_avg = old_avg + (new - old_avg) / new_count
      final merged = List<double>.generate(embedding.length, (i) {
        return oldEmbed[i] + (embedding[i] - oldEmbed[i]) / newCount;
      });

      await db.update(
        'speaker_embeddings',
        {
          'embedding': _embeddingToBlob(merged),
          'sample_count': newCount,
          'updated_at': now,
        },
        where: 'contact_id = ?',
        whereArgs: [contactId],
      );
    }
  }

  /// Get the speaker embedding for a contact, or null if none stored.
  static Future<List<double>?> getSpeakerEmbedding(int contactId) async {
    final db = await database;
    final rows = await db.query(
      'speaker_embeddings',
      where: 'contact_id = ?',
      whereArgs: [contactId],
    );
    if (rows.isEmpty) return null;
    final blob = rows.first['embedding'] as List<int>;
    return blobToEmbedding(blob);
  }

  /// Upsert the host user's own voiceprint embedding (contact_id = 0).
  static Future<void> upsertHostEmbedding(List<double> embedding) async {
    await upsertSpeakerEmbedding(contactId: 0, embedding: embedding);
  }

  /// Get the host user's voiceprint embedding, or null if not stored.
  static Future<List<double>?> getHostEmbedding() async {
    return getSpeakerEmbedding(0);
  }

  /// Get all stored speaker embeddings with their contact info.
  /// Each result map includes 'contact_id', 'display_name', 'phone_number',
  /// and 'decoded_embedding' (List<double>).
  static Future<List<Map<String, dynamic>>>
      getAllSpeakerEmbeddingsDecoded() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT se.*, c.display_name, c.phone_number
      FROM speaker_embeddings se
      JOIN contacts c ON c.id = se.contact_id
    ''');

    return rows.map((row) {
      final blob = row['embedding'] as List<int>;
      return {
        ...row,
        'decoded_embedding': blobToEmbedding(blob),
      };
    }).toList();
  }

  static Uint8List _embeddingToBlob(List<double> embedding) {
    final byteData = ByteData(embedding.length * 4);
    for (var i = 0; i < embedding.length; i++) {
      byteData.setFloat32(i * 4, embedding[i].toDouble(), Endian.little);
    }
    return byteData.buffer.asUint8List();
  }

  static List<double> blobToEmbedding(List<int> blob) {
    final byteData = ByteData.view(Uint8List.fromList(blob).buffer);
    final count = blob.length ~/ 4;
    return List<double>.generate(count, (i) {
      return byteData.getFloat32(i * 4, Endian.little).toDouble();
    });
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
    int? jobFunctionId,
  }) async {
    final db = await database;
    return db.insert('call_records', {
      'direction': direction,
      'status': 'active',
      'remote_identity': remoteIdentity,
      'remote_display_name': remoteDisplayName,
      'local_identity': localIdentity,
      'contact_id': contactId,
      'job_function_id': jobFunctionId,
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  /// Update the job_function_id on an active call record — used when a
  /// transfer-rule or calendar-rule switches the persona mid-call.
  static Future<void> updateCallJobFunction(int id, int? jobFunctionId) async {
    final db = await database;
    await db.update(
      'call_records',
      {'job_function_id': jobFunctionId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Look up the most recent completed call with [remoteIdentity] that was
  /// handled by a specific job function. Used to provide persona continuity
  /// when the same remote party calls back — the agent answers as the same
  /// persona that spoke with them last.
  ///
  /// Returns a row with all call_records columns plus `jf_agent_name` and
  /// `jf_title` if a match is found within [since], or null otherwise.
  static Future<Map<String, dynamic>?> getMostRecentCallWithPersona(
    String remoteIdentity, {
    DateTime? since,
  }) async {
    final db = await database;
    final where = <String>[
      'cr.remote_identity = ?',
      'cr.job_function_id IS NOT NULL',
      "cr.status != 'active'",
    ];
    final args = <dynamic>[remoteIdentity];
    if (since != null) {
      where.add('cr.started_at >= ?');
      args.add(since.toIso8601String());
    }
    final rows = await db.rawQuery('''
      SELECT cr.*, jf.agent_name AS jf_agent_name, jf.name AS jf_title
      FROM call_records cr
      LEFT JOIN job_functions jf ON jf.id = cr.job_function_id
      WHERE ${where.join(' AND ')}
      ORDER BY cr.started_at DESC
      LIMIT 1
    ''', args);
    return rows.isNotEmpty ? rows.first : null;
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

  /// Insert a transcript row and return the new primary-key id so callers
  /// (e.g. the /note flow) can link session messages back to the specific
  /// transcript row they just wrote.
  static Future<int> insertTranscript({
    required int callRecordId,
    required String role,
    String? speakerName,
    required String text,
  }) async {
    final db = await database;
    return db.insert('call_transcripts', {
      'call_record_id': callRecordId,
      'role': role,
      'speaker_name': speakerName,
      'text': text,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  /// Best-effort lookup of a note transcript's id given its parent call
  /// and the exact note text — used as a fallback for notes that were
  /// created before `attached_call_transcript_id` started being stored
  /// on session-message metadata. Returns the id of the most recent
  /// matching row, or null if nothing matches.
  static Future<int?> resolveNoteTranscriptId(
      int callRecordId, String text) async {
    if (text.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'call_transcripts',
      columns: ['id'],
      where: "call_record_id = ? AND role = 'note' AND text = ?",
      whereArgs: [callRecordId, text],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int?;
  }

  /// Delete a single `role='note'` transcript row. Guarded with
  /// `role = 'note'` in the WHERE clause so this can never remove spoken
  /// transcript content, even if the wrong id is passed in. Returns the
  /// number of rows actually deleted.
  static Future<int> deleteNote(int transcriptId) async {
    final db = await database;
    return db.delete(
      'call_transcripts',
      where: 'id = ? AND role = ?',
      whereArgs: [transcriptId, 'note'],
    );
  }

  /// Walk `session_messages` and unlink any note whose `metadata_json`
  /// points at [transcriptId] — clearing `attached_call_*` fields so the
  /// agent-panel bubble no longer shows "Attached to a call to …" / the
  /// deep-link icon for a transcript row that no longer exists. Returns
  /// the number of session-message rows that were updated.
  static Future<int> clearNoteAttachmentByTranscriptId(int transcriptId) async {
    final db = await database;
    final needle = '"attached_call_transcript_id":$transcriptId';
    final rows = await db.query(
      'session_messages',
      columns: ['message_id', 'metadata_json'],
      where: "role = 'note' AND metadata_json LIKE ?",
      whereArgs: ['%$needle%'],
    );
    var updated = 0;
    for (final row in rows) {
      final raw = row['metadata_json'] as String?;
      if (raw == null || raw.isEmpty) continue;
      Map<String, dynamic>? decoded;
      try {
        decoded = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (decoded['attached_call_transcript_id'] != transcriptId) continue;
      decoded.remove('attached_call_id');
      decoded.remove('attached_call_name');
      decoded.remove('attached_call_phone');
      decoded.remove('attached_call_direction');
      decoded.remove('attached_call_time_label');
      decoded.remove('attached_call_transcript_id');
      final newMeta = decoded.isEmpty ? null : jsonEncode(decoded);
      await db.update(
        'session_messages',
        {'metadata_json': newMeta},
        where: 'message_id = ?',
        whereArgs: [row['message_id']],
      );
      updated++;
    }
    return updated;
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

  /// Notes (`call_transcripts.role = 'note'`) written during calls with any
  /// of the given [contactIds] or [phones].
  ///
  /// Used by the `/search` recap card to surface annotations attached to a
  /// contact's call history. Returns transcript rows joined against their
  /// originating `call_records` so the UI can render a "from call with X
  /// on DATE" footer without a second lookup. Results are sorted
  /// newest-first by transcript timestamp.
  static Future<List<Map<String, dynamic>>> getNotesForContacts({
    List<int> contactIds = const [],
    List<String> phones = const [],
    int limit = 10,
  }) async {
    if (contactIds.isEmpty && phones.isEmpty) return const [];
    final db = await database;

    final where = <String>[];
    final args = <dynamic>[];

    if (contactIds.isNotEmpty) {
      final placeholders = List.filled(contactIds.length, '?').join(', ');
      where.add('cr.contact_id IN ($placeholders)');
      args.addAll(contactIds);
    }
    if (phones.isNotEmpty) {
      final placeholders = List.filled(phones.length, '?').join(', ');
      where.add('cr.remote_identity IN ($placeholders)');
      args.addAll(phones);
    }

    final whereClause = where.join(' OR ');
    return db.rawQuery('''
      SELECT
        ct.id AS transcript_id,
        ct.call_record_id AS call_record_id,
        ct.text AS text,
        ct.timestamp AS timestamp,
        cr.remote_identity AS remote_identity,
        cr.remote_display_name AS remote_display_name,
        cr.direction AS direction,
        cr.started_at AS started_at,
        c.display_name AS contact_name
      FROM call_transcripts ct
      JOIN call_records cr ON cr.id = ct.call_record_id
      LEFT JOIN contacts c ON c.id = cr.contact_id
      WHERE ct.role = 'note' AND ($whereClause)
      ORDER BY ct.timestamp DESC
      LIMIT ?
    ''', [...args, limit]);
  }

  /// Returns the set of call record IDs (from [callIds]) that have at least
  /// one transcript with role = 'host'.  Used to distinguish calls where the
  /// host was actually on the line from agent-only calls.
  static Future<Set<int>> callIdsWithHostTranscripts(
      List<int> callIds) async {
    if (callIds.isEmpty) return {};
    final db = await database;
    final placeholders = callIds.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT DISTINCT call_record_id FROM call_transcripts '
      'WHERE call_record_id IN ($placeholders) AND role = ?',
      [...callIds, 'host'],
    );
    return rows.map((r) => r['call_record_id'] as int).toSet();
  }

  /// Find the most recent completed call with [remotePhone] (suffix match on
  /// the last 10 digits) and return its transcript rows, or empty if none.
  static Future<List<Map<String, dynamic>>> getLastTranscriptForRemote(
      String remotePhone) async {
    final db = await database;
    final normalized = normalizePhone(remotePhone);
    if (normalized.isEmpty) return [];

    final calls = await db.query(
      'call_records',
      where: "status != 'active'",
      orderBy: 'started_at DESC',
      limit: 20,
    );

    for (final call in calls) {
      final stored = normalizePhone(call['remote_identity'] as String? ?? '');
      if (stored.isNotEmpty && stored == normalized) {
        final id = call['id'] as int;
        return getTranscripts(id);
      }
    }
    return [];
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
      where.add(
        '(cr.remote_display_name LIKE ? OR cr.remote_identity LIKE ? '
        'OR c.display_name LIKE ? '
        'OR cr.remote_identity IN '
        '(SELECT phone_number FROM contacts WHERE display_name LIKE ?))');
      args.addAll([
        '%$contactName%', '%$contactName%', '%$contactName%',
        '%$contactName%',
      ]);
    }
    if (minDurationSeconds != null) {
      where.add('cr.duration_seconds >= ?');
      args.add(minDurationSeconds);
    }
    if (maxDurationSeconds != null) {
      where.add('cr.duration_seconds <= ?');
      args.add(maxDurationSeconds);
    }
    if (since != null) {
      where.add('cr.started_at >= ?');
      args.add(since.toIso8601String());
    }
    if (before != null) {
      where.add('cr.started_at <= ?');
      args.add(before.toIso8601String());
    }
    if (direction != null) {
      where.add('cr.direction = ?');
      args.add(direction);
    }
    if (status != null && status != 'active') {
      where.add('cr.status = ?');
      args.add(status);
    }

    if (status == null) {
      where.add("cr.status != 'active'");
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return db.rawQuery('''
      SELECT cr.*, c.display_name AS contact_name,
             c.thumbnail_path AS contact_thumbnail,
             jf.agent_name AS jf_agent_name,
             jf.name AS jf_title
      FROM call_records cr
      LEFT JOIN contacts c ON c.id = cr.contact_id
      LEFT JOIN job_functions jf ON jf.id = cr.job_function_id
      $whereClause
      ORDER BY cr.started_at DESC
      LIMIT ?
    ''', [...args, limit]);
  }

  /// Search for calls whose transcripts contain [query].
  /// All other filters from [searchCalls] are also applied.
  static Future<List<Map<String, dynamic>>> searchCallsByTranscript({
    required String query,
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

    final where = <String>['ct.text LIKE ?'];
    final args = <dynamic>['%$query%'];

    if (contactName != null && contactName.isNotEmpty) {
      where.add(
          '(cr.remote_display_name LIKE ? OR cr.remote_identity LIKE ? '
          'OR c.display_name LIKE ? '
          'OR cr.remote_identity IN '
          '(SELECT phone_number FROM contacts WHERE display_name LIKE ?))');
      args.addAll([
        '%$contactName%', '%$contactName%', '%$contactName%',
        '%$contactName%',
      ]);
    }
    if (minDurationSeconds != null) {
      where.add('cr.duration_seconds >= ?');
      args.add(minDurationSeconds);
    }
    if (maxDurationSeconds != null) {
      where.add('cr.duration_seconds <= ?');
      args.add(maxDurationSeconds);
    }
    if (since != null) {
      where.add('cr.started_at >= ?');
      args.add(since.toIso8601String());
    }
    if (before != null) {
      where.add('cr.started_at <= ?');
      args.add(before.toIso8601String());
    }
    if (direction != null) {
      where.add('cr.direction = ?');
      args.add(direction);
    }
    if (status != null && status != 'active') {
      where.add('cr.status = ?');
      args.add(status);
    }
    if (status == null) {
      where.add("cr.status != 'active'");
    }

    return db.rawQuery('''
      SELECT DISTINCT cr.*, c.display_name AS contact_name,
             c.thumbnail_path AS contact_thumbnail,
             jf.agent_name AS jf_agent_name,
             jf.name AS jf_title
      FROM call_records cr
      INNER JOIN call_transcripts ct ON ct.call_record_id = cr.id
      LEFT JOIN contacts c ON c.id = cr.contact_id
      LEFT JOIN job_functions jf ON jf.id = cr.job_function_id
      WHERE ${where.join(' AND ')}
      ORDER BY cr.started_at DESC
      LIMIT ?
    ''', [...args, limit]);
  }

  static Future<List<Map<String, dynamic>>> getRecentCalls({
    int limit = 50,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT cr.*, c.display_name AS contact_name,
             c.thumbnail_path AS contact_thumbnail
      FROM call_records cr
      LEFT JOIN contacts c ON c.id = cr.contact_id
      WHERE cr.status != 'active'
      ORDER BY cr.started_at DESC
      LIMIT ?
    ''', [limit]);
  }

  /// Distinct caller names and numbers for autocomplete suggestions.
  /// Returns rows with `label` (display name or number) and `phone` fields,
  /// ordered by most recent call first, limited to [limit] entries.
  static Future<List<Map<String, String>>> searchSuggestions(
      String prefix, {int limit = 12}) async {
    final db = await database;
    final like = '%$prefix%';

    final rows = await db.rawQuery('''
      SELECT DISTINCT
        COALESCE(NULLIF(c.display_name, ''), NULLIF(cr.remote_display_name, ''), cr.remote_identity) AS label,
        cr.remote_identity AS phone
      FROM call_records cr
      LEFT JOIN contacts c ON c.id = cr.contact_id
      WHERE cr.status != 'active'
        AND (cr.remote_display_name LIKE ? OR cr.remote_identity LIKE ?
             OR c.display_name LIKE ?
             OR cr.remote_identity IN
               (SELECT phone_number FROM contacts WHERE display_name LIKE ?))
      GROUP BY label
      ORDER BY MAX(cr.started_at) DESC
      LIMIT ?
    ''', [like, like, like, like, limit]);

    // Merge in contacts that haven't called yet
    final contactRows = await db.query(
      'contacts',
      columns: ['display_name', 'phone_number'],
      where: 'display_name LIKE ? OR phone_number LIKE ?',
      whereArgs: [like, like],
      orderBy: 'display_name ASC',
      limit: limit,
    );

    final seen = <String>{};
    final results = <Map<String, String>>[];

    for (final r in rows) {
      final label = r['label'] as String? ?? '';
      if (label.isEmpty || seen.contains(label.toLowerCase())) continue;
      seen.add(label.toLowerCase());
      results.add({
        'label': label,
        'phone': r['phone'] as String? ?? '',
      });
    }
    for (final c in contactRows) {
      final name = c['display_name'] as String? ?? '';
      final phone = c['phone_number'] as String? ?? '';
      final key = name.isNotEmpty ? name.toLowerCase() : phone.toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      results.add({'label': name.isNotEmpty ? name : phone, 'phone': phone});
    }

    return results.take(limit).toList();
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

  /// Same filter as [searchContacts] but returns rows ordered by their
  /// most-recent call (`MAX(call_records.started_at)`) descending, with
  /// never-called contacts placed last (alphabetical among themselves).
  ///
  /// Used by the `/search` guide so the chip row puts the contact the
  /// manager most recently interacted with first — usually the one they
  /// actually care about.
  static Future<List<Map<String, dynamic>>> searchContactsByRecency(
      String query) async {
    final db = await database;
    return db.rawQuery('''
      SELECT c.*,
             MAX(cr.started_at) AS last_call_at
      FROM contacts c
      LEFT JOIN call_records cr
        ON cr.contact_id = c.id
        OR cr.remote_identity = c.phone_number
      WHERE c.display_name LIKE ?
         OR c.phone_number LIKE ?
         OR c.email LIKE ?
      GROUP BY c.id
      ORDER BY CASE WHEN last_call_at IS NULL THEN 1 ELSE 0 END,
               last_call_at DESC,
               c.display_name ASC
    ''', ['%$query%', '%$query%', '%$query%']);
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
    String? thumbnailPath,
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
          if (thumbnailPath != null) 'thumbnail_path': thumbnailPath,
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
      'thumbnail_path': thumbnailPath,
      'macos_contact_id': macosContactId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Link a macOS contact ID to an existing local contact row.
  static Future<void> linkMacosContactId(
      int localId, String macosContactId) async {
    final db = await database;
    await db.update(
      'contacts',
      {'macos_contact_id': macosContactId},
      where: 'id = ?',
      whereArgs: [localId],
    );
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

  /// Propagate a contact's current display name to all related records:
  /// call_records (link + display name), transcripts (speaker label), and
  /// tear sheet items.
  static Future<void> propagateContactName({
    required int contactId,
    required String displayName,
    required String phoneNumber,
  }) async {
    final db = await database;
    final normalized = normalizePhone(phoneNumber);

    // Link unlinked call_records whose remote_identity matches this phone.
    if (normalized.isNotEmpty) {
      final unlinked = await db.query(
        'call_records',
        columns: ['id', 'remote_identity'],
        where: 'contact_id IS NULL AND remote_identity IS NOT NULL',
      );
      final idsToLink = <int>[];
      for (final row in unlinked) {
        final ri = normalizePhone(row['remote_identity'] as String? ?? '');
        if (ri.isNotEmpty && ri == normalized) {
          idsToLink.add(row['id'] as int);
        }
      }
      if (idsToLink.isNotEmpty) {
        final placeholders = List.filled(idsToLink.length, '?').join(',');
        await db.rawUpdate(
          'UPDATE call_records SET contact_id = ? WHERE id IN ($placeholders)',
          [contactId, ...idsToLink],
        );
      }
    }

    // Update remote_display_name on all call_records linked to this contact.
    await db.update(
      'call_records',
      {'remote_display_name': displayName},
      where: 'contact_id = ?',
      whereArgs: [contactId],
    );

    // Update speaker_name on remote transcript lines for linked calls.
    await db.rawUpdate('''
      UPDATE call_transcripts
      SET speaker_name = ?
      WHERE role = 'remote'
        AND call_record_id IN (
          SELECT id FROM call_records WHERE contact_id = ?
        )
    ''', [displayName, contactId]);

    // Update tear_sheet_items whose phone matches.
    if (normalized.isNotEmpty) {
      final items = await db.query(
        'tear_sheet_items',
        columns: ['id', 'phone_number'],
      );
      for (final item in items) {
        final itemPhone =
            normalizePhone(item['phone_number'] as String? ?? '');
        if (itemPhone.isNotEmpty && itemPhone == normalized) {
          await db.update(
            'tear_sheet_items',
            {'contact_name': displayName},
            where: 'id = ?',
            whereArgs: [item['id']],
          );
        }
      }
    }
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

  // ---------------------------------------------------------------------------
  // Job Functions
  // ---------------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> getAllJobFunctions() async {
    final db = await database;
    return db.query('job_functions', orderBy: 'created_at ASC');
  }

  static Future<Map<String, dynamic>?> getJobFunction(int id) async {
    final db = await database;
    final rows =
        await db.query('job_functions', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> insertJobFunction(JobFunction jf) async {
    final db = await database;
    final map = jf.toMap();
    map.remove('id');
    return db.insert('job_functions', map);
  }

  static Future<void> updateJobFunction(JobFunction jf) async {
    if (jf.id == null) return;
    final db = await database;
    await db.update(
      'job_functions',
      jf.toMap(),
      where: 'id = ?',
      whereArgs: [jf.id],
    );
  }

  static Future<void> deleteJobFunction(int id) async {
    final db = await database;
    await db.delete('job_functions', where: 'id = ?', whereArgs: [id]);
  }

  static Future<int> jobFunctionCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as cnt FROM job_functions');
    return result.first['cnt'] as int? ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Calendar Events
  // ---------------------------------------------------------------------------

  static Future<void> _createCalendarEventsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        calendly_event_id TEXT UNIQUE,
        google_calendar_event_id TEXT,
        source TEXT DEFAULT 'local',
        title TEXT NOT NULL,
        description TEXT,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        invitee_name TEXT,
        invitee_email TEXT,
        event_type TEXT,
        job_function_id INTEGER REFERENCES job_functions(id),
        location TEXT,
        status TEXT DEFAULT 'active',
        synced_at TEXT,
        created_at TEXT,
        locally_modified INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ce_start ON calendar_events(start_time)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ce_source ON calendar_events(source)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ce_gcal_id ON calendar_events(google_calendar_event_id)');
  }

  static Future<int> insertCalendarEvent(CalendarEvent event) async {
    final db = await database;
    final map = event.toMap();
    map.remove('id');
    return db.insert('calendar_events', map);
  }

  static Future<void> upsertCalendarEvent(CalendarEvent event) async {
    final db = await database;

    // Dedup by Calendly event ID
    if (event.calendlyEventId != null) {
      final existing = await db.query(
        'calendar_events',
        where: 'calendly_event_id = ?',
        whereArgs: [event.calendlyEventId],
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        final locallyMod = existing.first['locally_modified'] as int? ?? 0;
        if (locallyMod == 1) {
          debugPrint('[CalendarSync] SKIP upsert id=$id — locally_modified');
          return;
        }
        final existingStart = existing.first['start_time'] as String?;
        final existingEnd = existing.first['end_time'] as String?;
        final incomingStart = event.startTime.toIso8601String();
        final incomingEnd = event.endTime.toIso8601String();
        if (existingStart != null &&
            existingEnd != null &&
            (existingStart != incomingStart || existingEnd != incomingEnd)) {
          debugPrint(
              '[CalendarSync] SKIP upsert id=$id — local times differ '
              '(local=$existingStart, remote=$incomingStart)');
          return;
        }
        final map = event.toMap();
        map.remove('id');
        map.remove('locally_modified');
        final existingJfId = existing.first['job_function_id'];
        if (existingJfId != null && map['job_function_id'] == null) {
          map['job_function_id'] = existingJfId;
        }
        debugPrint('[CalendarSync] UPSERT id=$id — updating from remote');
        await db.update('calendar_events', map,
            where: 'id = ?', whereArgs: [id]);
        return;
      }
    }

    // Dedup by Google Calendar composite ID
    if (event.googleCalendarEventId != null) {
      final existing = await db.query(
        'calendar_events',
        where: 'google_calendar_event_id = ?',
        whereArgs: [event.googleCalendarEventId],
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        final locallyMod = existing.first['locally_modified'] as int? ?? 0;
        if (locallyMod == 1) {
          debugPrint('[CalendarSync] SKIP upsert id=$id — locally_modified');
          return;
        }
        final existingStart = existing.first['start_time'] as String?;
        final existingEnd = existing.first['end_time'] as String?;
        final incomingStart = event.startTime.toIso8601String();
        final incomingEnd = event.endTime.toIso8601String();
        if (existingStart != null &&
            existingEnd != null &&
            (existingStart != incomingStart || existingEnd != incomingEnd)) {
          debugPrint(
              '[CalendarSync] SKIP upsert id=$id — local times differ '
              '(local=$existingStart, remote=$incomingStart)');
          return;
        }
        final map = event.toMap();
        map.remove('id');
        map.remove('locally_modified');
        final existingJfId = existing.first['job_function_id'];
        if (existingJfId != null && map['job_function_id'] == null) {
          map['job_function_id'] = existingJfId;
        }
        debugPrint('[CalendarSync] UPSERT id=$id — updating from remote');
        await db.update('calendar_events', map,
            where: 'id = ?', whereArgs: [id]);
        return;
      }
    }

    debugPrint('[CalendarSync] INSERT new event: "${event.title}"');
    final map = event.toMap();
    map.remove('id');
    await db.insert('calendar_events', map);
  }

  static Future<List<CalendarEvent>> getUpcomingEvents({int limit = 20}) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await db.query(
      'calendar_events',
      where: "end_time >= ? AND status = 'active'",
      whereArgs: [now],
      orderBy: 'start_time ASC',
      limit: limit,
    );
    return rows.map((r) => CalendarEvent.fromMap(r)).toList();
  }

  static Future<List<CalendarEvent>> getEventsBetween(
      DateTime start, DateTime end) async {
    final db = await database;
    final rows = await db.query(
      'calendar_events',
      where: "start_time < ? AND end_time > ? AND status = 'active'",
      whereArgs: [
        end.toUtc().toIso8601String(),
        start.toUtc().toIso8601String(),
      ],
      orderBy: 'start_time ASC',
    );
    return rows.map((r) => CalendarEvent.fromMap(r)).toList();
  }

  static Future<void> updateCalendarEventJobFunction(
      int id, int? jobFunctionId) async {
    final db = await database;
    await db.update(
      'calendar_events',
      {'job_function_id': jobFunctionId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateCalendarEvent(CalendarEvent event,
      {bool markLocallyModified = false}) async {
    final db = await database;
    final map = event.toMap();
    map.remove('id');
    if (markLocallyModified) {
      map['locally_modified'] = 1;
      debugPrint(
          '[CalendarSync] updateCalendarEvent id=${event.id} '
          'markLocallyModified=true start=${event.startTime}');
    }
    await db.update('calendar_events', map,
        where: 'id = ?', whereArgs: [event.id]);
  }

  static Future<void> deleteCalendarEvent(int id) async {
    final db = await database;
    await db.delete('calendar_events', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<CalendarEvent>> getAllCalendarEvents() async {
    final db = await database;
    final rows = await db.query('calendar_events', orderBy: 'start_time ASC');
    return rows.map((r) => CalendarEvent.fromMap(r)).toList();
  }

  // ---------------------------------------------------------------------------
  // SMS Messages
  // ---------------------------------------------------------------------------

  static Future<void> _createSmsMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sms_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider_id TEXT,
        provider_type TEXT NOT NULL DEFAULT 'telnyx',
        remote_phone TEXT NOT NULL,
        local_phone TEXT NOT NULL,
        direction TEXT NOT NULL,
        body TEXT,
        media_urls TEXT,
        status TEXT NOT NULL DEFAULT 'queued',
        is_read INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        error_reason TEXT,
        reactions_json TEXT,
        reply_to_provider_id TEXT,
        reply_to_local_id INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sms_remote ON sms_messages(remote_phone)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sms_created ON sms_messages(created_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sms_read ON sms_messages(is_read)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_provider ON sms_messages(provider_id, provider_type)');
  }

  static Future<void> _createSmsThreadDeletesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sms_thread_deletes (
        remote_phone TEXT PRIMARY KEY,
        deleted_at TEXT NOT NULL
      )
    ''');
  }

  static Future<int> insertSmsMessage(Map<String, dynamic> map) async {
    final db = await database;
    return db.insert('sms_messages', map,
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> updateSmsMessage(int id, Map<String, dynamic> fields) async {
    final db = await database;
    await db.update('sms_messages', fields, where: 'id = ?', whereArgs: [id]);
  }

  static Future<Map<String, dynamic>?> getSmsMessageByProviderId(
      String providerId, String providerType) async {
    final db = await database;
    final rows = await db.query('sms_messages',
        where: 'provider_id = ? AND provider_type = ?',
        whereArgs: [providerId, providerType],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>?> getSmsMessageById(int localId) async {
    final db = await database;
    final rows = await db.query('sms_messages',
        where: 'id = ?', whereArgs: [localId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<List<Map<String, dynamic>>> getSmsMessagesForConversation(
      String remotePhone,
      {int limit = 100,
      int offset = 0}) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT m.*
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE m.remote_phone = ?
        AND m.is_deleted = 0
        AND m.created_at > COALESCE(d.deleted_at, '')
      ORDER BY m.created_at DESC
      LIMIT ? OFFSET ?
      ''',
      [remotePhone, limit, offset],
    );
  }

  /// Returns one row per unique remote_phone with aggregated fields.
  static Future<List<Map<String, dynamic>>> getSmsConversations() async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        m.remote_phone AS remote_phone,
        m.local_phone AS local_phone,
        MAX(m.created_at) AS last_message_at,
        SUM(CASE WHEN m.is_read = 0 AND m.direction = 'inbound' THEN 1 ELSE 0 END) AS unread_count,
        COUNT(*) AS total_messages
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE m.is_deleted = 0
        AND m.created_at > COALESCE(d.deleted_at, '')
      GROUP BY m.remote_phone
      ORDER BY last_message_at DESC
    ''');
  }

  static Future<Map<String, dynamic>?> getLastSmsForConversation(
      String remotePhone) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT m.*
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE m.remote_phone = ?
        AND m.is_deleted = 0
        AND m.created_at > COALESCE(d.deleted_at, '')
      ORDER BY m.created_at DESC
      LIMIT 1
      ''',
      [remotePhone],
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> markSmsRead(String remotePhone) async {
    final db = await database;
    await db.update(
      'sms_messages',
      {'is_read': 1},
      where: 'remote_phone = ? AND is_read = 0',
      whereArgs: [remotePhone],
    );
  }

  static Future<void> softDeleteSmsMessage(int id) async {
    final db = await database;
    await db.update(
      'sms_messages',
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<int> getUnreadSmsCount() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) AS cnt
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE m.is_read = 0
        AND m.direction = 'inbound'
        AND m.is_deleted = 0
        AND m.created_at > COALESCE(d.deleted_at, '')
    ''');
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// Inbound SMS rows that have no outbound reply in the same thread.
  ///
  /// Used by startup reconciliation to surface messages the agent/manager
  /// never responded to. Windowed by [since] (inclusive) so each startup
  /// considers only messages that arrived after the previous reconciliation.
  ///
  /// The thread-deletion table is respected: a message from a deleted thread
  /// is skipped unless it arrived after the deletion timestamp.
  ///
  /// Returns one row per inbound message (not per thread). Order: newest
  /// first. Caller typically wants to collapse by `remote_phone`.
  static Future<List<Map<String, dynamic>>> getUnansweredInboundSms({
    DateTime? since,
    int limit = 50,
  }) async {
    final db = await database;
    final sinceIso = (since ?? DateTime.fromMillisecondsSinceEpoch(0))
        .toUtc()
        .toIso8601String();
    return db.rawQuery(
      '''
      SELECT m.*
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE m.direction = 'inbound'
        AND m.is_deleted = 0
        AND m.created_at >= ?
        AND m.created_at > COALESCE(d.deleted_at, '')
        AND NOT EXISTS (
          SELECT 1 FROM sms_messages o
          WHERE o.remote_phone = m.remote_phone
            AND o.direction = 'outbound'
            AND o.is_deleted = 0
            AND o.created_at > m.created_at
        )
      ORDER BY m.created_at DESC
      LIMIT ?
      ''',
      [sinceIso, limit],
    );
  }

  static Future<List<Map<String, dynamic>>> searchSmsMessages(
      String query,
      {int limit = 50}) async {
    final db = await database;
    final pattern = '%$query%';
    return db.rawQuery(
      '''
      SELECT m.*
      FROM sms_messages m
      LEFT JOIN sms_thread_deletes d ON d.remote_phone = m.remote_phone
      WHERE (m.body LIKE ? OR m.remote_phone LIKE ?)
        AND m.is_deleted = 0
        AND m.created_at > COALESCE(d.deleted_at, '')
      ORDER BY m.created_at DESC
      LIMIT ?
      ''',
      [pattern, pattern, limit],
    );
  }

  static Future<void> updateSmsReactions(int id, String? jsonStr) async {
    final db = await database;
    await db.update(
      'sms_messages',
      {
        'reactions_json': jsonStr,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateSmsReplyTo(
    int id, {
    String? providerId,
    int? localId,
  }) async {
    final db = await database;
    await db.update(
      'sms_messages',
      {
        'reply_to_provider_id': providerId,
        'reply_to_local_id': localId,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> bulkSoftDeleteSms(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'sms_messages',
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  static Future<void> upsertThreadTombstone(String remotePhone,
      {DateTime? at}) async {
    final db = await database;
    final ts = (at ?? DateTime.now()).toIso8601String();
    await db.insert(
      'sms_thread_deletes',
      {'remote_phone': remotePhone, 'deleted_at': ts},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> clearThreadTombstone(String remotePhone) async {
    final db = await database;
    await db.delete(
      'sms_thread_deletes',
      where: 'remote_phone = ?',
      whereArgs: [remotePhone],
    );
  }

  static Future<DateTime?> getThreadTombstone(String remotePhone) async {
    final db = await database;
    final rows = await db.query(
      'sms_thread_deletes',
      where: 'remote_phone = ?',
      whereArgs: [remotePhone],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final at = rows.first['deleted_at'] as String?;
    return at == null ? null : DateTime.tryParse(at);
  }

  // ---------------------------------------------------------------------------
  // Inbound Call Flows
  // ---------------------------------------------------------------------------

  static Future<void> _createInboundCallFlowsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inbound_call_flows (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        rules_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<List<Map<String, dynamic>>> getAllInboundCallFlows() async {
    final db = await database;
    return db.query('inbound_call_flows', orderBy: 'created_at ASC');
  }

  static Future<Map<String, dynamic>?> getInboundCallFlow(int id) async {
    final db = await database;
    final rows = await db.query('inbound_call_flows',
        where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> insertInboundCallFlow(InboundCallFlow flow) async {
    final db = await database;
    final map = flow.toMap();
    map.remove('id');
    return db.insert('inbound_call_flows', map);
  }

  static Future<void> updateInboundCallFlow(InboundCallFlow flow) async {
    if (flow.id == null) return;
    final db = await database;
    await db.update(
      'inbound_call_flows',
      flow.toMap(),
      where: 'id = ?',
      whereArgs: [flow.id],
    );
  }

  static Future<void> deleteInboundCallFlow(int id) async {
    final db = await database;
    await db.delete('inbound_call_flows', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------------------
  // Agent Reminders
  // ---------------------------------------------------------------------------

  static Future<void> _createAgentRemindersTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        description TEXT,
        remind_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        google_calendar_event_id TEXT,
        source TEXT NOT NULL DEFAULT 'agent'
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ar_remind_at ON agent_reminders(remind_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ar_status ON agent_reminders(status)');
  }

  static Future<int> insertReminder({
    required String title,
    String? description,
    required DateTime remindAt,
    String? googleCalendarEventId,
    String source = 'agent',
  }) async {
    final db = await database;
    return db.insert('agent_reminders', {
      'title': title,
      'description': description,
      'remind_at': remindAt.toUtc().toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'status': 'pending',
      'google_calendar_event_id': googleCalendarEventId,
      'source': source,
    });
  }

  static Future<List<Map<String, dynamic>>> getPendingReminders() async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    return db.query(
      'agent_reminders',
      where: "status = 'pending' AND remind_at <= ?",
      whereArgs: [now],
      orderBy: 'remind_at ASC',
    );
  }

  static Future<List<Map<String, dynamic>>> getUpcomingReminders({
    Duration window = const Duration(minutes: 15),
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc();
    final cutoff = now.add(window);
    return db.query(
      'agent_reminders',
      where: "status = 'pending' AND remind_at > ? AND remind_at <= ?",
      whereArgs: [
        now.toIso8601String(),
        cutoff.toIso8601String(),
      ],
      orderBy: 'remind_at ASC',
    );
  }

  /// Pending reminders due anywhere in `[now − lookback, now + window]`.
  /// Used by the `/recap` skill so the agent can mention both overdue
  /// reminders the manager hasn't seen yet and the next few things
  /// coming up. Ordered by `remind_at ASC` so overdue items come first,
  /// then the next upcoming ones.
  static Future<List<Map<String, dynamic>>> getRecentAndUpcomingReminders({
    Duration lookback = const Duration(hours: 6),
    Duration window = const Duration(hours: 24),
    int limit = 5,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc();
    final from = now.subtract(lookback);
    final to = now.add(window);
    return db.query(
      'agent_reminders',
      where: "status = 'pending' AND remind_at >= ? AND remind_at <= ?",
      whereArgs: [from.toIso8601String(), to.toIso8601String()],
      orderBy: 'remind_at ASC',
      limit: limit,
    );
  }

  /// Most recent SMS messages across every conversation, newest first.
  /// Returns the raw `sms_messages` rows joined with the remote
  /// contact's display name when one exists — so the `/recap` skill
  /// doesn't need a second query to label each line.
  static Future<List<Map<String, dynamic>>> getRecentSmsMessages({
    int limit = 10,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT sm.*, c.display_name AS contact_name
      FROM sms_messages sm
      LEFT JOIN contacts c ON c.phone_number = sm.remote_phone
      WHERE sm.is_deleted = 0
      ORDER BY sm.created_at DESC
      LIMIT ?
    ''', [limit]);
  }

  /// Most recent notes (`call_transcripts.role = 'note'`) across every
  /// call. Joined with the originating call record + contact so the
  /// recap UI / agent brief can cite "note from call with X".
  static Future<List<Map<String, dynamic>>> getRecentNotes({
    int limit = 5,
  }) async {
    final db = await database;
    return db.rawQuery('''
      SELECT
        ct.id AS transcript_id,
        ct.call_record_id AS call_record_id,
        ct.text AS text,
        ct.timestamp AS timestamp,
        cr.remote_identity AS remote_identity,
        cr.remote_display_name AS remote_display_name,
        cr.started_at AS started_at,
        c.display_name AS contact_name
      FROM call_transcripts ct
      JOIN call_records cr ON cr.id = ct.call_record_id
      LEFT JOIN contacts c ON c.id = cr.contact_id
      WHERE ct.role = 'note'
      ORDER BY ct.timestamp DESC
      LIMIT ?
    ''', [limit]);
  }

  static Future<Map<String, dynamic>?> getReminderById(int id) async {
    final db = await database;
    final rows = await db.query(
      'agent_reminders',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> updateReminderStatus(int id, String status) async {
    final db = await database;
    await db.update(
      'agent_reminders',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Map<String, dynamic>>> getAllReminders({
    int limit = 50,
  }) async {
    final db = await database;
    return db.query(
      'agent_reminders',
      orderBy: 'remind_at DESC',
      limit: limit,
    );
  }

  // ---------------------------------------------------------------------------
  // Transfer Rules
  // ---------------------------------------------------------------------------

  static Future<void> _createTransferRulesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transfer_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        caller_patterns TEXT NOT NULL DEFAULT '["*"]',
        transfer_target TEXT NOT NULL,
        silent INTEGER NOT NULL DEFAULT 0,
        job_function_id INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<List<Map<String, dynamic>>> getAllTransferRules() async {
    final db = await database;
    return db.query('transfer_rules', orderBy: 'created_at ASC');
  }

  static Future<Map<String, dynamic>?> getTransferRule(int id) async {
    final db = await database;
    final rows =
        await db.query('transfer_rules', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> insertTransferRule(TransferRule rule) async {
    final db = await database;
    final map = rule.toMap();
    map.remove('id');
    return db.insert('transfer_rules', map);
  }

  static Future<void> updateTransferRule(TransferRule rule) async {
    if (rule.id == null) return;
    final db = await database;
    await db.update(
      'transfer_rules',
      rule.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [rule.id],
    );
  }

  static Future<void> deleteTransferRule(int id) async {
    final db = await database;
    await db.delete('transfer_rules', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------------------
  // Session Messages (agent panel transcript persistence)
  // ---------------------------------------------------------------------------

  static const int _sessionMessageMaxRows = 50000;
  static const int _sessionMessagePageSize = 200;

  static Future<void> _createSessionMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT NOT NULL,
        role TEXT NOT NULL,
        type TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        speaker_name TEXT,
        actions_json TEXT,
        metadata_json TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sm_ts ON session_messages(timestamp)');
  }

  static Future<void> _createPocketTtsVoicesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pocket_tts_voices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        accent TEXT,
        gender TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        audio_path TEXT,
        embedding BLOB,
        created_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> insertSessionMessage(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert('session_messages', row);

    // Prune oldest rows if over the cap. Uses a subquery on rowid which is
    // extremely fast (B-tree seek, no full scan).
    final countResult =
        await db.rawQuery('SELECT COUNT(*) AS cnt FROM session_messages');
    final count = countResult.first['cnt'] as int? ?? 0;
    if (count > _sessionMessageMaxRows) {
      final excess = count - _sessionMessageMaxRows;
      await db.rawDelete('''
        DELETE FROM session_messages WHERE id IN (
          SELECT id FROM session_messages ORDER BY id ASC LIMIT ?
        )
      ''', [excess]);
    }
  }

  /// Load the most recent [limit] messages. Returns rows in chronological
  /// order (oldest first) so they can be appended directly to the message list.
  static Future<List<Map<String, dynamic>>> loadRecentSessionMessages({
    int limit = _sessionMessagePageSize,
  }) async {
    final db = await database;
    // Grab newest N by descending id, then reverse for chronological order.
    final rows = await db.query(
      'session_messages',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.toList();
  }

  /// Load a page of older messages whose rowid is less than [beforeId].
  /// Returns rows in chronological order (oldest first).
  static Future<List<Map<String, dynamic>>> loadSessionMessagesBefore({
    required int beforeId,
    int limit = _sessionMessagePageSize,
  }) async {
    final db = await database;
    final rows = await db.query(
      'session_messages',
      where: 'id < ?',
      whereArgs: [beforeId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.toList();
  }

  static Future<void> clearSessionMessages() async {
    final db = await database;
    await db.delete('session_messages');
  }

  static Future<int> sessionMessageCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) AS cnt FROM session_messages');
    return result.first['cnt'] as int? ?? 0;
  }

  static Future<void> deleteSessionMessageByMsgId(String messageId) async {
    final db = await database;
    await db.delete('session_messages',
        where: 'message_id = ?', whereArgs: [messageId]);
  }

  static Future<void> updateSessionMessageText(
      String messageId, String text) async {
    final db = await database;
    await db.update(
      'session_messages',
      {'text': text},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  /// Overwrite a session message's stored metadata. Used by the `/note`
  /// pending-attachment flow to transition from pending → finalized without
  /// rewriting the whole row.
  static Future<void> updateSessionMessageMetadata(
      String messageId, Map<String, dynamic>? metadata) async {
    final db = await database;
    await db.update(
      'session_messages',
      {
        'metadata_json': (metadata != null && metadata.isNotEmpty)
            ? jsonEncode(metadata)
            : null,
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  static int get sessionPageSize => _sessionMessagePageSize;
}
