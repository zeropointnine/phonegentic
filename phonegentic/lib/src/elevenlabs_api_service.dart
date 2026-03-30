import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class ElevenLabsVoice {
  final String voiceId;
  final String name;
  final String category;

  const ElevenLabsVoice({
    required this.voiceId,
    required this.name,
    required this.category,
  });

  factory ElevenLabsVoice.fromJson(Map<String, dynamic> json) {
    return ElevenLabsVoice(
      voiceId: json['voice_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {
        'voice_id': voiceId,
        'name': name,
        'category': category,
      };
}

/// REST client for ElevenLabs voice management APIs.
class ElevenLabsApiService {
  static const _baseUrl = 'https://api.elevenlabs.io/v1';

  ElevenLabsApiService._();

  /// Fetch all voices available on the account.
  static Future<List<ElevenLabsVoice>> listVoices(String apiKey) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl/voices'));
      request.headers.set('xi-api-key', apiKey);

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        debugPrint('[ElevenLabsAPI] listVoices failed '
            '(${response.statusCode}): $body');
        throw Exception(
            'ElevenLabs API ${response.statusCode}: ${_truncate(body, 200)}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final voices = (json['voices'] as List<dynamic>? ?? [])
          .map((v) => ElevenLabsVoice.fromJson(v as Map<String, dynamic>))
          .toList();

      debugPrint('[ElevenLabsAPI] listVoices: ${voices.length} voices');
      return voices;
    } finally {
      client.close();
    }
  }

  /// Clone a voice by uploading one or more audio files.
  /// Returns the new voice ID on success.
  static Future<String> addVoice(
    String apiKey, {
    required String name,
    required List<String> filePaths,
    String? description,
  }) async {
    final uri = Uri.parse('$_baseUrl/voices/add');
    final boundary =
        '----DartFormBoundary${DateTime.now().millisecondsSinceEpoch}';

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set('xi-api-key', apiKey);
      request.headers.set(
          'content-type', 'multipart/form-data; boundary=$boundary');

      final bodyParts = <List<int>>[];

      void addField(String fieldName, String value) {
        bodyParts.add(utf8.encode(
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="$fieldName"\r\n\r\n'
            '$value\r\n'));
      }

      addField('name', name);
      if (description != null && description.isNotEmpty) {
        addField('description', description);
      }

      for (final path in filePaths) {
        final file = File(path);
        if (!await file.exists()) {
          throw Exception('Audio file not found: $path');
        }
        final fileName = path.split('/').last;
        final fileBytes = await file.readAsBytes();

        bodyParts.add(utf8.encode(
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="files"; filename="$fileName"\r\n'
            'Content-Type: audio/wav\r\n\r\n'));
        bodyParts.add(fileBytes);
        bodyParts.add(utf8.encode('\r\n'));
      }

      bodyParts.add(utf8.encode('--$boundary--\r\n'));

      for (final part in bodyParts) {
        request.add(part);
      }

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        debugPrint('[ElevenLabsAPI] addVoice failed '
            '(${response.statusCode}): $body');
        throw Exception(
            'ElevenLabs API ${response.statusCode}: ${_truncate(body, 200)}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final voiceId = json['voice_id'] as String? ?? '';
      debugPrint('[ElevenLabsAPI] addVoice success: $voiceId');
      return voiceId;
    } finally {
      client.close();
    }
  }

  /// Delete a cloned voice.
  static Future<void> deleteVoice(String apiKey, String voiceId) async {
    final client = HttpClient();
    try {
      final request =
          await client.deleteUrl(Uri.parse('$_baseUrl/voices/$voiceId'));
      request.headers.set('xi-api-key', apiKey);

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        debugPrint('[ElevenLabsAPI] deleteVoice failed '
            '(${response.statusCode}): $body');
        throw Exception(
            'ElevenLabs API ${response.statusCode}: ${_truncate(body, 200)}');
      }
      debugPrint('[ElevenLabsAPI] deleteVoice success: $voiceId');
    } finally {
      client.close();
    }
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}
