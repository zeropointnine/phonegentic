import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_config_service.dart';
import 'whisper_realtime_service.dart';

class ToolCallRequest {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  const ToolCallRequest({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// Streams call transcripts to an external LLM (Claude, etc.) and
/// returns streaming text responses via [responses].
class TextAgentService {
  TextAgentConfig _config;
  String _systemInstructions;

  final List<Map<String, dynamic>> _history = [];
  final List<String> _pendingContext = [];
  Timer? _debounceTimer;

  HttpClient? _httpClient;
  bool _responding = false;

  final _responseController = StreamController<ResponseTextEvent>.broadcast();
  Stream<ResponseTextEvent> get responses => _responseController.stream;

  final _toolCallController = StreamController<ToolCallRequest>.broadcast();
  Stream<ToolCallRequest> get toolCalls => _toolCallController.stream;

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
    _history.add({
      'role': 'user',
      'content': '[Host Message]: $text',
    });
    _respond();
  }

  // ─────────────────────────────── internal ───────────────────────────────

  /// Submit the result of a tool call so the model can continue.
  void addToolResult(String toolUseId, String result) {
    _history.add({
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': toolUseId,
          'content': result,
        }
      ],
    });
    _respond();
  }

  void _flushPendingToHistory() {
    if (_pendingContext.isEmpty) return;
    _history.add({
      'role': 'user',
      'content': _pendingContext.join('\n'),
    });
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
      if (_history.isNotEmpty) {
        _responseController
            .add(ResponseTextEvent(text: 'Error: $e', isFinal: true));
      }
    } finally {
      _responding = false;
      if (_pendingContext.isNotEmpty) _scheduleFlush();
    }
  }

  static const _tools = [
    {
      'name': 'make_call',
      'description': 'Initiate an outbound phone call to a number.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'number': {
            'type': 'string',
            'description':
                'Phone number to dial (E.164 or digits). Use "last" to redial.',
          },
        },
        'required': ['number'],
      },
    },
    {
      'name': 'end_call',
      'description': 'Hang up the current active call.',
      'input_schema': {
        'type': 'object',
        'properties': {},
      },
    },
    {
      'name': 'search_contacts',
      'description':
          'Search the local contacts database by name, phone, or tags. '
          'Use not_called_since_days to find contacts with no outbound calls in N days.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Name or phone to match. Leave empty to consider all contacts '
                '(useful with not_called_since_days).',
          },
          'not_called_since_days': {
            'type': 'integer',
            'description':
                'Only contacts with no calls in the last N days (e.g. 14 = two weeks).',
          },
        },
      },
    },
    {
      'name': 'create_tear_sheet',
      'description':
          'Create a tear sheet (sequential outbound call queue) from contacts. '
          'Search contacts first, then pass each chosen row as an entry with '
          'phone_number and optional name.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Label for this tear sheet (e.g. "Follow-up calls").',
          },
          'entries': {
            'type': 'array',
            'description': 'Contacts to call in order.',
            'items': {
              'type': 'object',
              'properties': {
                'phone_number': {
                  'type': 'string',
                  'description': 'Number to dial (E.164 or stored format).',
                },
                'name': {
                  'type': 'string',
                  'description': 'Contact display name (optional).',
                },
              },
              'required': ['phone_number'],
            },
          },
        },
        'required': ['entries'],
      },
    },
    {
      'name': 'send_sms',
      'description':
          'Send an SMS or MMS to a phone number. Use when the job or host '
          'asks you to text someone, send a message, or follow up via SMS.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'to': {
            'type': 'string',
            'description':
                'Destination phone number (E.164, e.g. +18005551234)',
          },
          'text': {
            'type': 'string',
            'description': 'Message body to send',
          },
          'media_url': {
            'type': 'string',
            'description': 'Optional image URL for MMS',
          },
        },
        'required': ['to', 'text'],
      },
    },
    {
      'name': 'reply_sms',
      'description':
          'Reply in the currently selected SMS conversation. Use when the host '
          'asks to respond or reply to the open text thread.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'Reply message body',
          },
        },
        'required': ['text'],
      },
    },
    {
      'name': 'search_messages',
      'description':
          'Search SMS history by message text or number. Use when the job or '
          'host asks about past texts or needs to find a message.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description':
                'Text to match against message body or phone number',
          },
          'contact_name': {
            'type': 'string',
            'description': 'Optional contact name filter',
          },
        },
      },
    },
    {
      'name': 'start_voice_sample',
      'description':
          'Start capturing a voice sample from the specified call party for '
          'voice cloning. Use this to record audio that will be sent to '
          'ElevenLabs to create a cloned voice. Let them speak for at '
          'least 10-15 seconds before stopping.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'party': {
            'type': 'string',
            'enum': ['remote', 'host'],
            'description':
                'Which call party to sample: "remote" for the other caller, '
                '"host" for the app user.',
          },
        },
        'required': ['party'],
      },
    },
    {
      'name': 'stop_and_clone_voice',
      'description':
          'Stop the active voice sample and upload it to ElevenLabs to '
          'create a cloned voice. Returns the new voice_id on success. '
          'Must call start_voice_sample first.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'voice_name': {
            'type': 'string',
            'description':
                'A friendly name for the cloned voice (e.g. "Sarah\'s Voice").',
          },
        },
      },
    },
    {
      'name': 'set_agent_voice',
      'description':
          'Change the agent\'s speaking voice mid-call. Use a voice_id '
          'returned by stop_and_clone_voice or any ElevenLabs voice ID. '
          'All subsequent agent speech will use this voice.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'voice_id': {
            'type': 'string',
            'description': 'The ElevenLabs voice ID to switch to.',
          },
        },
        'required': ['voice_id'],
      },
    },
  ];

  Future<void> _callClaude() async {
    if (_history.isEmpty) return;

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
      'tools': _tools,
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

    final toolBlocks = <Map<String, dynamic>>[];
    String? _activeToolId;
    String? _activeToolName;
    final _activeToolInput = StringBuffer();

    await for (final chunk in response.transform(utf8.decoder)) {
      sseBuf += chunk;
      final lines = sseBuf.split('\n');
      sseBuf = lines.removeLast();

      for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final type = json['type'] as String? ?? '';

          if (type == 'content_block_start') {
            final cb = json['content_block'] as Map<String, dynamic>?;
            if (cb?['type'] == 'tool_use') {
              _activeToolId = cb!['id'] as String?;
              _activeToolName = cb['name'] as String?;
              _activeToolInput.clear();
            }
          } else if (type == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta?['type'] == 'text_delta') {
              final t = delta!['text'] as String? ?? '';
              if (t.isNotEmpty) {
                fullText.write(t);
                _responseController
                    .add(ResponseTextEvent(text: t, isFinal: false));
              }
            } else if (delta?['type'] == 'input_json_delta') {
              _activeToolInput
                  .write(delta!['partial_json'] as String? ?? '');
            }
          } else if (type == 'content_block_stop') {
            if (_activeToolId != null && _activeToolName != null) {
              Map<String, dynamic> parsedInput = {};
              try {
                final raw = _activeToolInput.toString();
                if (raw.isNotEmpty) {
                  parsedInput =
                      jsonDecode(raw) as Map<String, dynamic>;
                }
              } catch (_) {}
              toolBlocks.add({
                'type': 'tool_use',
                'id': _activeToolId,
                'name': _activeToolName,
                'input': parsedInput,
              });
              _activeToolId = null;
              _activeToolName = null;
              _activeToolInput.clear();
            }
          }
        } catch (_) {}
      }
    }

    final contentBlocks = <Map<String, dynamic>>[];
    final textResult = fullText.toString();
    if (textResult.isNotEmpty) {
      contentBlocks.add({'type': 'text', 'text': textResult});
    }
    contentBlocks.addAll(toolBlocks);

    if (contentBlocks.isNotEmpty) {
      _history.add({'role': 'assistant', 'content': contentBlocks});
    }

    if (textResult.isNotEmpty) {
      _responseController
          .add(ResponseTextEvent(text: textResult, isFinal: true));
    }

    for (final tool in toolBlocks) {
      debugPrint('[TextAgent] Tool call: ${tool['name']} '
          'id=${tool['id']} input=${tool['input']}');
      _toolCallController.add(ToolCallRequest(
        id: tool['id'] as String,
        name: tool['name'] as String,
        arguments: tool['input'] as Map<String, dynamic>,
      ));
    }

    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }

  /// Claude requires strictly alternating user / assistant roles.
  /// Content can be a plain String or a List of content blocks.
  List<Map<String, dynamic>> _mergedHistory() {
    if (_history.isEmpty) return [];
    final out = <Map<String, dynamic>>[];
    for (final m in _history) {
      final role = m['role'] as String;
      final content = m['content'];
      final isStructured = content is List;

      if (!isStructured &&
          out.isNotEmpty &&
          out.last['role'] == role &&
          out.last['content'] is String) {
        out.last = {
          'role': role,
          'content': '${out.last['content']}\n\n$content',
        };
      } else {
        out.add(Map<String, dynamic>.of(m));
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
    _toolCallController.close();
    _httpClient?.close();
  }
}
