import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_config_service.dart';
import 'llm/claude_caller.dart';
import 'llm/llm_interfaces.dart';
import 'llm/openai_caller.dart';
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
  late LlmCaller _caller;

  final List<LlmMessage> _history = [];
  final List<String> _pendingContext = [];
  Timer? _debounceTimer;

  HttpClient? _httpClient;
  bool _responding = false;
  bool _pendingRespond = false;
  bool _cancelRequested = false;
  final Set<String> _pendingToolUseIds = {};

  static const _responseTimeoutSecs = 45;

  final _responseController = StreamController<ResponseTextEvent>.broadcast();
  Stream<ResponseTextEvent> get responses => _responseController.stream;

  final _toolCallController = StreamController<ToolCallRequest>.broadcast();
  Stream<ToolCallRequest> get toolCalls => _toolCallController.stream;

  bool _disposed = false;

  static const _debounceMs = 1500;
  static const _maxHistory = 60;

  /// Matches fabricated transcript lines the LLM may hallucinate, e.g.
  /// `[Remote Party 1]: Hello?` or `[Host]: Sure`.  Only the SYSTEM
  /// delivers these — the agent must never produce them.
  static final _fabricatedTranscriptRe = RegExp(
    r'(?:^|\n)\s*\[[\w\s]+\d*\]\s*:',
  );

  TextAgentService({
    required TextAgentConfig config,
    required String systemInstructions,
  })  : _config = config,
        _systemInstructions = systemInstructions {
    _httpClient = HttpClient();
    _caller = _createCaller(config, _httpClient!);
  }

  void updateConfig(TextAgentConfig config) {
    final callerNeedsUpdate = config.provider != _config.provider ||
        (config.provider == TextAgentProvider.custom &&
            config.customEndpointUrl != _config.customEndpointUrl);
    _config = config;
    if (callerNeedsUpdate) {
      _caller = _createCaller(config, _httpClient!);
    }
  }

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

  /// Discard any accumulated pending context without triggering an LLM
  /// response. Used after pre-greeting flush so phase-transition context
  /// (settling / connected) doesn't auto-fire a duplicate greeting.
  void clearPendingContext() {
    _debounceTimer?.cancel();
    _pendingContext.clear();
  }

  /// Cancel the in-flight LLM response (if any). The streaming loop in
  /// _callLlm checks this flag after each event and breaks early,
  /// emitting a final event with the partial text accumulated so far.
  void cancelCurrentResponse() {
    if (!_responding) return;
    _cancelRequested = true;
    _pendingRespond = false;
    _debounceTimer?.cancel();
    debugPrint('[TextAgentService] cancelCurrentResponse requested');
  }

  /// Host typed a direct message — flush any pending context and respond
  /// immediately.
  void sendUserMessage(String text) {
    _debounceTimer?.cancel();
    _flushPendingToHistory();
    _history.add(LlmMessage(
      role: LlmRole.user,
      content: [LlmTextBlock('[Host Message]: $text')],
    ));
    _respond();
  }

  // ─────────────────────────────── internal ───────────────────────────────

  /// Submit the result of a tool call so the model can continue.
  ///
  /// Claude requires that `tool_result` blocks appear before any text in the
  /// user message immediately following an assistant `tool_use`.
  void addToolResult(String toolUseId, String result) {
    _debounceTimer?.cancel();
    _pendingToolUseIds.remove(toolUseId);

    // If history was reset (e.g. call ended while tool was in-flight), there
    // is no assistant tool_use to pair with — drop the orphaned result.
    final hasMatchingToolUse = _history.any((m) =>
        m.role == LlmRole.assistant &&
        m.content.any((b) => b is LlmToolUseBlock && b.id == toolUseId));
    if (!hasMatchingToolUse) {
      debugPrint(
          '[TextAgentService] addToolResult: no matching tool_use for $toolUseId — dropped');
      return;
    }

    final blocks = <LlmContentBlock>[
      LlmToolResultBlock(toolUseId: toolUseId, content: result),
    ];
    if (_pendingContext.isNotEmpty) {
      blocks.add(LlmTextBlock(_pendingContext.join('\n')));
      _pendingContext.clear();
    }
    _history.add(LlmMessage(role: LlmRole.user, content: blocks));
    _respond();
  }

  void _flushPendingToHistory() {
    if (_pendingContext.isEmpty) return;
    _history.add(LlmMessage(
      role: LlmRole.user,
      content: [LlmTextBlock(_pendingContext.join('\n'))],
    ));
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
    if (_pendingToolUseIds.isNotEmpty) return;
    _flushPendingToHistory();
    _respond();
  }

  static const _maxRetries = 2;

  Future<void> _respond() async {
    if (_responding) {
      _pendingRespond = true;
      debugPrint('[TextAgentService] _respond: already responding, will retry after');
      return;
    }
    if (_pendingToolUseIds.isNotEmpty) {
      debugPrint('[TextAgentService] _respond: waiting for ${_pendingToolUseIds.length} tool result(s)');
      return;
    }
    _responding = true;
    _pendingRespond = false;

    try {
      await _callWithRetry();
    } catch (e) {
      debugPrint('[TextAgentService] Error: $e');
      if (_history.isNotEmpty) {
        _responseController
            .add(ResponseTextEvent(text: 'Error: $e', isFinal: true));
      }
    } finally {
      _responding = false;
      if (_pendingRespond && _pendingToolUseIds.isEmpty) {
        _pendingRespond = false;
        debugPrint('[TextAgentService] _respond: processing queued request');
        unawaited(_respond());
      } else if (_pendingContext.isNotEmpty) {
        _scheduleFlush();
      }
    }
  }

  Future<void> _callWithRetry() async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        await _callLlm().timeout(
          const Duration(seconds: _responseTimeoutSecs),
          onTimeout: () {
            throw TimeoutException(
                'LLM timed out after ${_responseTimeoutSecs}s — '
                'check network or API key');
          },
        );
        return;
      } on LlmBadRequestException catch (e) {
        if (e.hasToolUseError) {
          _dumpMergedHistory(_mergedHistory());
          _repairHistory();
        }
        rethrow;
      } on LlmAuthException {
        rethrow;
      } catch (e) {
        final isTransient = e is LlmTransientException || e is TimeoutException;
        if (!isTransient || attempt >= _maxRetries) rethrow;
        final delayMs = 500 * (attempt + 1);
        debugPrint('[TextAgentService] Transient error (attempt ${attempt + 1}/$_maxRetries), retrying in ${delayMs}ms: $e');
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  List<LlmTool> _extraTools = [];

  /// Register additional tools from 3rd-party integrations.
  void setExtraTools(List<LlmTool> tools) {
    _extraTools = tools;
  }

  List<LlmTool> get _allTools => [..._baseTools, ..._extraTools];

  static final _baseTools = <LlmTool>[
    LlmTool(
      name: 'make_call',
      description: 'Initiate an outbound phone call to a number.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'check_locale',
      description: 'Get the host\'s phone-number locale: country code, expected digit '
          'length, format example, and sanitization rules. Call this when you '
          'need to validate or interpret a spoken phone number.',
      inputSchema: {
        'type': 'object',
        'properties': {},
      },
    ),
    LlmTool(
      name: 'end_call',
      description: 'Hang up the current active call.',
      inputSchema: {
        'type': 'object',
        'properties': {},
      },
    ),
    LlmTool(
      name: 'search_contacts',
      description: 'Search the local contacts database by name, phone, or tags. '
          'Use not_called_since_days to find contacts with no outbound calls in N days.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'save_contact',
      description: 'Save or update a contact in the local contacts database. '
          'Use when a caller provides their name, email, or company and you want '
          'to remember it. If a contact already exists for the phone number, the '
          'existing record is updated; otherwise a new contact is created.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'phone_number': {
            'type': 'string',
            'description':
                'Phone number (E.164 preferred). Uses the current caller\'s '
                'number if omitted during an active call.',
          },
          'display_name': {
            'type': 'string',
            'description': 'Contact display name (e.g. "John Smith").',
          },
          'email': {
            'type': 'string',
            'description': 'Email address (optional).',
          },
          'company': {
            'type': 'string',
            'description': 'Company or organization (optional).',
          },
          'notes': {
            'type': 'string',
            'description': 'Free-form notes about the contact (optional).',
          },
        },
      },
    ),
    LlmTool(
      name: 'create_tear_sheet',
      description: 'Create a tear sheet (sequential outbound call queue) from contacts. '
          'Search contacts first, then pass each chosen row as an entry with '
          'phone_number and optional name.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'send_sms',
      description: 'Send an SMS or MMS to a phone number. Use when the job or host '
          'asks you to text someone, send a message, or follow up via SMS.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'reply_sms',
      description: 'Reply in the currently selected SMS conversation. Use when the host '
          'asks to respond or reply to the open text thread.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'Reply message body',
          },
        },
        'required': ['text'],
      },
    ),
    LlmTool(
      name: 'search_messages',
      description: 'Search SMS history by message text or number. Use when the job or '
          'host asks about past texts or needs to find a message.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'start_voice_sample',
      description: 'Start capturing a voice sample from the specified call party for '
          'voice cloning. Use this to record audio that will be sent to '
          'ElevenLabs to create a cloned voice. Let them speak for at '
          'least 10-15 seconds before stopping.',
      inputSchema: {
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
    ),
    LlmTool(
      name: 'stop_and_clone_voice',
      description: 'Stop the active voice sample and upload it to ElevenLabs to '
          'create a cloned voice. Returns the new voice_id on success. '
          'Must call start_voice_sample first.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'voice_name': {
            'type': 'string',
            'description':
                'A friendly name for the cloned voice (e.g. "Sarah\'s Voice").',
          },
        },
      },
    ),
    LlmTool(
      name: 'set_agent_voice',
      description: 'Change the agent\'s speaking voice mid-call. Use a voice_id '
          'returned by stop_and_clone_voice or any ElevenLabs voice ID. '
          'All subsequent agent speech will use this voice.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'voice_id': {
            'type': 'string',
            'description': 'The ElevenLabs voice ID to switch to.',
          },
        },
        'required': ['voice_id'],
      },
    ),
  ];

  Future<void> _callLlm() async {
    if (_history.isEmpty) return;

    final merged = _mergedHistory();
    final req = LlmRequest(
      apiKey: _config.activeApiKey,
      model: _config.activeModel,
      systemInstructions: _systemInstructions,
      messages: merged,
      tools: _allTools,
    );

    String fullText = '';
    final toolCallEvents = <LlmToolCallEvent>[];
    bool cancelled = false;

    bool fabricationDetected = false;

    final stopwatch = Stopwatch()..start();
    await for (final event in _caller.call(req)) {
      if (_cancelRequested || _disposed) {
        cancelled = true;
        break;
      }
      if (event is LlmTextDeltaEvent) {
        fullText += event.text;

        // Detect fabricated transcript lines mid-stream and truncate.
        final match = _fabricatedTranscriptRe.firstMatch(fullText);
        if (match != null) {
          final cleanEnd = match.start;
          final fabricated = fullText.substring(match.start).split('\n').first;
          debugPrint(
              '[TextAgent] Fabricated transcript detected — truncating: '
              '"$fabricated"');
          fullText = fullText.substring(0, cleanEnd).trimRight();
          fabricationDetected = true;
          break;
        }

        if (!_disposed) {
          _responseController.add(ResponseTextEvent(text: event.text, isFinal: false));
        }
      } else if (event is LlmToolCallEvent) {
        toolCallEvents.add(event);
      }
    }

    stopwatch.stop();
    debugPrint('[TextAgent] LLM response time: ${stopwatch.elapsedMilliseconds}ms (model: ${req.model})');

    if (_disposed) return;
    _cancelRequested = false;

    if (cancelled || fabricationDetected) {
      if (fabricationDetected) {
        debugPrint('[TextAgentService] Response truncated (fabrication) — '
            '${fullText.length} clean chars');
      } else {
        debugPrint('[TextAgentService] Response cancelled — ${fullText.length} chars emitted');
      }
      if (fullText.isNotEmpty) {
        _history.add(LlmMessage(
          role: LlmRole.assistant,
          content: [LlmTextBlock(fullText)],
        ));
        if (!_disposed) {
          _responseController.add(ResponseTextEvent(text: fullText, isFinal: true));
        }
      }
      return;
    }

    final assistantContent = <LlmContentBlock>[];
    if (fullText.isNotEmpty) {
      assistantContent.add(LlmTextBlock(fullText));
    }
    for (final tc in toolCallEvents) {
      assistantContent.add(LlmToolUseBlock(
        id: tc.id,
        name: tc.name,
        input: tc.arguments,
      ));
    }

    if (assistantContent.isNotEmpty) {
      _history.add(LlmMessage(role: LlmRole.assistant, content: assistantContent));
    }

    if (fullText.isNotEmpty && !_disposed) {
      _responseController.add(ResponseTextEvent(text: fullText, isFinal: true));
    }

    for (final tc in toolCallEvents) {
      _pendingToolUseIds.add(tc.id);
      debugPrint('[TextAgent] Tool call: ${tc.name} id=${tc.id} input=${tc.arguments}');
      if (!_disposed) {
        _toolCallController.add(ToolCallRequest(
          id: tc.id,
          name: tc.name,
          arguments: tc.arguments,
        ));
      }
    }

    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    while (_history.isNotEmpty) {
      final first = _history.first;
      if (first.role == LlmRole.assistant) {
        _history.removeAt(0);
        continue;
      }
      if (first.hasToolResult) {
        _history.removeAt(0);
        continue;
      }
      break;
    }
  }

  /// LLMs require strictly alternating user/assistant roles.
  /// Merges consecutive same-role messages by combining their content lists.
  /// For user messages, ensures `tool_result` blocks precede text blocks so
  /// the Claude API sees them immediately after the preceding `tool_use`.
  List<LlmMessage> _mergedHistory() {
    if (_history.isEmpty) return [];
    final out = <LlmMessage>[];
    for (final m in _history) {
      if (out.isNotEmpty && out.last.role == m.role) {
        final prev = out.last;
        out.last = LlmMessage(
          role: prev.role,
          content: [...prev.content, ...m.content],
        );
      } else {
        out.add(m);
      }
    }
    _reorderUserToolResults(out);
    _stripDanglingToolUse(out);
    return out;
  }

  /// Ensure tool_result blocks come before text blocks in every user message.
  /// Claude requires tool_result immediately after the preceding tool_use; if
  /// merging placed text first this reorders them.
  static void _reorderUserToolResults(List<LlmMessage> messages) {
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role != LlmRole.user) continue;
      final hasToolResult = m.content.any((b) => b is LlmToolResultBlock);
      if (!hasToolResult) continue;

      final results = <LlmContentBlock>[];
      final rest = <LlmContentBlock>[];
      for (final b in m.content) {
        if (b is LlmToolResultBlock) {
          results.add(b);
        } else {
          rest.add(b);
        }
      }
      messages[i] = LlmMessage(role: m.role, content: [...results, ...rest]);
    }
  }

  /// Remove tool_use blocks from assistant messages when the next message
  /// doesn't contain the matching tool_result. Prevents a permanently stuck
  /// history if a tool_result was never delivered.
  static void _stripDanglingToolUse(List<LlmMessage> messages) {
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role != LlmRole.assistant) continue;

      final toolUseIds = {
        for (final b in m.content)
          if (b is LlmToolUseBlock) b.id,
      };
      if (toolUseIds.isEmpty) continue;

      final resultIds = <String>{};
      if (i + 1 < messages.length && messages[i + 1].role == LlmRole.user) {
        for (final b in messages[i + 1].content) {
          if (b is LlmToolResultBlock) resultIds.add(b.toolUseId);
        }
      }

      final dangling = toolUseIds.difference(resultIds);
      if (dangling.isEmpty) continue;

      final cleaned = m.content
          .where((b) => b is! LlmToolUseBlock || !dangling.contains(b.id))
          .toList();

      if (cleaned.isEmpty) {
        messages.removeAt(i);
        i--;
      } else {
        messages[i] = LlmMessage(role: m.role, content: cleaned);
      }
    }
  }

  /// Dump merged history structure for debugging 400 errors.
  static void _dumpMergedHistory(List<LlmMessage> merged) {
    debugPrint('[TextAgent] === MERGED HISTORY DUMP (${merged.length} msgs) ===');
    for (var i = 0; i < merged.length; i++) {
      final m = merged[i];
      final role = m.role.name;
      final types = m.content.map((b) {
        if (b is LlmTextBlock) return 'text(${b.text.length} chars)';
        if (b is LlmToolUseBlock) return 'tool_use(${b.name}/${b.id})';
        if (b is LlmToolResultBlock) return 'tool_result(${b.toolUseId})';
        return 'unknown';
      }).join(', ');
      debugPrint('  [$i] $role: [$types]');
    }
    debugPrint('[TextAgent] === END DUMP ===');
  }

  /// Repair _history directly by stripping tool_use blocks that have no
  /// matching tool_result anywhere after them. Called on 400 errors to
  /// break the stuck-error loop.
  void _repairHistory() {
    final allResultIds = <String>{};
    for (final m in _history) {
      for (final b in m.content) {
        if (b is LlmToolResultBlock) allResultIds.add(b.toolUseId);
      }
    }

    for (var i = _history.length - 1; i >= 0; i--) {
      final m = _history[i];
      if (m.role != LlmRole.assistant || !m.hasToolUse) continue;

      final cleaned = m.content
          .where((b) => b is! LlmToolUseBlock || allResultIds.contains(b.id))
          .toList();

      if (cleaned.isEmpty) {
        _history.removeAt(i);
        debugPrint('[TextAgent] _repairHistory: removed empty assistant msg at $i');
      } else if (cleaned.length != m.content.length) {
        _history[i] = LlmMessage(role: m.role, content: cleaned);
        debugPrint('[TextAgent] _repairHistory: stripped dangling tool_use at $i');
      }
    }
    _pendingToolUseIds.clear();
  }

  void reset() {
    _debounceTimer?.cancel();
    _pendingContext.clear();
    _history.clear();
    _pendingToolUseIds.clear();
    _responding = false;
    _pendingRespond = false;
    _cancelRequested = false;
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _responseController.close();
    _toolCallController.close();
    _httpClient?.close();
  }

  static LlmCaller _createCaller(TextAgentConfig config, HttpClient http) {

    switch (config.provider) {
      case TextAgentProvider.claude:
        return ClaudeCaller(http);
      case TextAgentProvider.openai:
        throw UnimplementedError('OpenAI realtime handles text in-band');
      case TextAgentProvider.custom:
        return OpenAiCaller(

          http,
          baseUrl: Uri.parse(config.customEndpointUrl),
        );
    }
  }
}
