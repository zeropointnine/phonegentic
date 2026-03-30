import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_config_service.dart';
import 'whisper_realtime_service.dart';

/// Streams call transcripts to an external LLM (Claude, etc.) and
/// returns streaming text responses via [responses].
class TextAgentService {
  TextAgentConfig _config;
  String _systemInstructions;

  final List<Map<String, String>> _history = [];
  final List<String> _pendingContext = [];
  Timer? _debounceTimer;

  HttpClient? _httpClient;
  bool _responding = false;

  final _responseController = StreamController<ResponseTextEvent>.broadcast();
  Stream<ResponseTextEvent> get responses => _responseController.stream;

  static const _debounceMs = 2500;
  static const _maxHistory = 60;

  TextAgentService({
    required TextAgentConfig config,
    required String systemInstructions,
  })  : _config = config,
        _systemInstructions = systemInstructions {
    _httpClient = HttpClient();
  }

  void updateConfig(TextAgentConfig config) => _config = config;

  void updateInstructions(String instructions) =>
      _systemInstructions = instructions;

  /// Buffer a transcript line; triggers a debounced flush → LLM call.
  void addTranscript(String speakerLabel, String text) {
    _pendingContext.add('[$speakerLabel]: $text');
    _scheduleFlush();
  }

  /// Add informational context (call state, whisper) without triggering a
  /// response on its own — it will be included in the next flush.
  void addSystemContext(String text) {
    _pendingContext.add(text);
  }

  /// Host typed a direct message — flush any pending context and respond
  /// immediately.
  void sendUserMessage(String text) {
    _debounceTimer?.cancel();
    _flushPendingToHistory();
    _history.add({'role': 'user', 'content': '[Host Message]: $text'});
    _respond();
  }

  // ─────────────────────────────── internal ───────────────────────────────

  void _flushPendingToHistory() {
    if (_pendingContext.isEmpty) return;
    _history.add({'role': 'user', 'content': _pendingContext.join('\n')});
    _pendingContext.clear();
  }

  void _scheduleFlush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: _debounceMs),
      _flushAndRespond,
    );
  }

  void _flushAndRespond() {
    if (_pendingContext.isEmpty) return;
    _flushPendingToHistory();
    _respond();
  }

  Future<void> _respond() async {
    if (_responding) return;
    _responding = true;

    try {
      if (_config.provider == TextAgentProvider.claude) {
        await _callClaude();
      }
    } catch (e) {
      debugPrint('[TextAgentService] Error: $e');
      _responseController
          .add(ResponseTextEvent(text: 'Error: $e', isFinal: true));
    } finally {
      _responding = false;
      if (_pendingContext.isNotEmpty) _scheduleFlush();
    }
  }

  Future<void> _callClaude() async {
    final uri = Uri.parse('https://api.anthropic.com/v1/messages');
    final request = await _httpClient!.postUrl(uri);

    request.headers.set('x-api-key', _config.activeApiKey);
    request.headers.set('anthropic-version', '2023-06-01');
    request.headers.set('content-type', 'application/json; charset=utf-8');

    final body = jsonEncode({
      'model': _config.activeModel,
      'max_tokens': 1024,
      'system': _systemInstructions,
      'messages': _mergedHistory(),
      'stream': true,
    });
    request.add(utf8.encode(body));

    final response = await request.close();
    if (response.statusCode != 200) {
      final body = await response.transform(utf8.decoder).join();
      throw Exception('Claude API ${response.statusCode}: $body');
    }

    final fullText = StringBuffer();
    String sseBuf = '';

    await for (final chunk in response.transform(utf8.decoder)) {
      sseBuf += chunk;
      final lines = sseBuf.split('\n');
      sseBuf = lines.removeLast(); // keep incomplete trailing line

      for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          if (json['type'] == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta?['type'] == 'text_delta') {
              final t = delta!['text'] as String? ?? '';
              if (t.isNotEmpty) {
                fullText.write(t);
                _responseController
                    .add(ResponseTextEvent(text: t, isFinal: false));
              }
            }
          }
        } catch (_) {}
      }
    }

    final result = fullText.toString();
    if (result.isNotEmpty) {
      _history.add({'role': 'assistant', 'content': result});
      _responseController
          .add(ResponseTextEvent(text: result, isFinal: true));
    }

    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }

  /// Claude requires strictly alternating user / assistant roles.
  List<Map<String, String>> _mergedHistory() {
    if (_history.isEmpty) return [];
    final out = <Map<String, String>>[];
    for (final m in _history) {
      if (out.isNotEmpty && out.last['role'] == m['role']) {
        out.last = {
          'role': m['role']!,
          'content': '${out.last['content']}\n\n${m['content']}',
        };
      } else {
        out.add(Map.of(m));
      }
    }
    return out;
  }

  void reset() {
    _debounceTimer?.cancel();
    _pendingContext.clear();
    _history.clear();
    _responding = false;
  }

  void dispose() {
    _debounceTimer?.cancel();
    _responseController.close();
    _httpClient?.close();
  }
}
