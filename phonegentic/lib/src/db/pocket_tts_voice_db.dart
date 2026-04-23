import 'dart:io';
// ignore: unnecessary_import
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'call_history_db.dart';

class PocketTtsVoice {
  final int? id;
  final String name;
  final String? accent;
  final String? gender;
  final bool isDefault;
  final String? audioPath;
  final Uint8List? embedding;
  final DateTime createdAt;

  const PocketTtsVoice({
    this.id,
    required this.name,
    this.accent,
    this.gender,
    this.isDefault = false,
    this.audioPath,
    this.embedding,
    required this.createdAt,
  });

  String get subtitle {
    final parts = <String>[];
    if (accent != null && accent!.isNotEmpty) parts.add(accent!);
    if (gender != null && gender!.isNotEmpty) parts.add(gender!);
    return parts.join(' · ');
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'accent': accent,
        'gender': gender,
        'is_default': isDefault ? 1 : 0,
        'audio_path': audioPath,
        'embedding': embedding,
        'created_at': createdAt.toIso8601String(),
      };

  factory PocketTtsVoice.fromMap(Map<String, dynamic> map) => PocketTtsVoice(
        id: map['id'] as int?,
        name: map['name'] as String? ?? '',
        accent: map['accent'] as String?,
        gender: map['gender'] as String?,
        isDefault: (map['is_default'] as int? ?? 0) == 1,
        audioPath: map['audio_path'] as String?,
        embedding: map['embedding'] as Uint8List?,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

class PocketTtsVoiceDb {
  PocketTtsVoiceDb._();

  static const _defaultVoices = <Map<String, String>>[
    {
      'name': 'Reassuring Raj',
      'accent': 'Indian',
      'gender': 'Male',
      'asset': 'assets/voices/reassuring_raj_indian_male.wav',
    },
    {
      'name': 'Super Scott',
      'accent': 'American',
      'gender': 'Male',
      'asset': 'assets/voices/super_scott_american_male.wav',
    },
    {
      'name': 'Happy Jose',
      'accent': 'Spanish',
      'gender': 'Male',
      'asset': 'assets/voices/Happy_Jose_spanish_male.wav',
    },
    {
      'name': 'Likable Lacy',
      'accent': 'American',
      'gender': 'Female',
      'asset': 'assets/voices/Likable_Lacy_american_female.wav',
    },
    {
      'name': 'Queen Anne',
      'accent': 'British',
      'gender': 'Female',
      'asset': 'assets/voices/queen_anne_british_female.wav',
    },
    {
      'name': 'Handly Harold',
      'accent': 'American',
      'gender': 'Male',
      'asset': 'assets/voices/handly_harold.wav',
    },
  ];

  static Future<List<PocketTtsVoice>> listVoices() async {
    final db = await CallHistoryDb.database;
    final rows =
        await db.query('pocket_tts_voices', orderBy: 'is_default DESC, name');
    return rows.map((r) => PocketTtsVoice.fromMap(r)).toList();
  }

  static Future<PocketTtsVoice?> getVoice(int id) async {
    final db = await CallHistoryDb.database;
    final rows =
        await db.query('pocket_tts_voices', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return PocketTtsVoice.fromMap(rows.first);
  }

  static Future<int> insertVoice(PocketTtsVoice voice) async {
    final db = await CallHistoryDb.database;
    return db.insert('pocket_tts_voices', voice.toMap());
  }

  static Future<void> updateVoiceEmbedding(int id, Uint8List embedding) async {
    final db = await CallHistoryDb.database;
    await db.update(
      'pocket_tts_voices',
      {'embedding': embedding},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteVoice(int id) async {
    final db = await CallHistoryDb.database;
    await db.delete('pocket_tts_voices', where: 'id = ?', whereArgs: [id]);
  }

  /// Extract a bundled asset to a writable file in the documents directory.
  static Future<String> _extractAssetToFile(String assetKey) async {
    final dir = await getApplicationDocumentsDirectory();
    final voiceDir =
        Directory(p.join(dir.path, 'phonegentic', 'pocket_tts_voices'));
    await voiceDir.create(recursive: true);

    final fileName = p.basename(assetKey);
    final outPath = p.join(voiceDir.path, fileName);

    if (await File(outPath).exists()) return outPath;

    final data = await rootBundle.load(assetKey);
    await File(outPath).writeAsBytes(data.buffer.asUint8List());
    return outPath;
  }

  /// Seed default voices from bundled assets.
  /// Replaces stale defaults when the built-in voice set changes.
  static Future<void> seedDefaultVoices() async {
    final db = await CallHistoryDb.database;
    final existing =
        await db.query('pocket_tts_voices', where: 'is_default = 1');

    final expectedNames = _defaultVoices.map((v) => v['name']!).toSet();
    final existingNames =
        existing.map((r) => r['name'] as String? ?? '').toSet();

    if (existingNames.isNotEmpty &&
        existingNames.length == expectedNames.length &&
        existingNames.containsAll(expectedNames)) {
      return;
    }

    // Defaults changed — remove old defaults and reseed.
    if (existing.isNotEmpty) {
      debugPrint('[PocketTtsVoiceDb] Default voices changed, reseeding');
      await db.delete('pocket_tts_voices', where: 'is_default = 1');
    }

    debugPrint(
        '[PocketTtsVoiceDb] Seeding ${_defaultVoices.length} default voices');

    for (final v in _defaultVoices) {
      try {
        final audioPath = await _extractAssetToFile(v['asset']!);
        final voice = PocketTtsVoice(
          name: v['name']!,
          accent: v['accent'],
          gender: v['gender'],
          isDefault: true,
          audioPath: audioPath,
          createdAt: DateTime.now(),
        );
        await db.insert('pocket_tts_voices', voice.toMap());
        debugPrint('[PocketTtsVoiceDb] Seeded: ${v['name']}');
      } catch (e) {
        debugPrint('[PocketTtsVoiceDb] Failed to seed ${v['name']}: $e');
      }
    }
  }

  /// Save a user-uploaded voice. [audioPath] is the picked file path.
  static Future<int> addUserVoice({
    required String name,
    required String audioPath,
    String? accent,
    String? gender,
    Uint8List? embedding,
  }) async {
    final voice = PocketTtsVoice(
      name: name,
      accent: accent,
      gender: gender,
      isDefault: false,
      audioPath: audioPath,
      embedding: embedding,
      createdAt: DateTime.now(),
    );
    return insertVoice(voice);
  }
}
