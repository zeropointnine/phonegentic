import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'llm_interfaces.dart';
import 'openai_response_handler.dart';

/// Calls any OpenAI-compatible chat/completions endpoint and streams back
/// [LlmResponseEvent]s.
///
/// Compatible with OpenAI, OpenRouter, LM Studio, Ollama, and others that
/// implement the OpenAI chat completions API.
///
/// [baseUrl] must be the full endpoint URL, e.g.:
///   - `https://api.openai.com/v1/chat/completions`
///   - `https://openrouter.ai/api/v1/chat/completions`
///   - `http://localhost:11434/v1/chat/completions`  (Ollama)
class OpenAiCaller implements LlmCaller {
  final HttpClient _httpClient;
  final Uri _baseUrl;
  final LlmResponseHandler _handler;

  OpenAiCaller(this._httpClient, {required Uri baseUrl})
      : _baseUrl = baseUrl,
        _handler = OpenAiResponseHandler();

  @override
  Stream<LlmResponseEvent> call(LlmRequest request) async* {
    final httpRequest = await _httpClient.postUrl(_baseUrl);

    final apiKey = request.apiKey.trim();
    if (apiKey.isNotEmpty) {
      httpRequest.headers.set('Authorization', 'Bearer $apiKey');
    } else {
      debugPrint('[OpenAiCaller] WARNING: apiKey is empty — Authorization header not set. '
          'Check that the API Key field is filled in under Settings > Agents > Custom.');
    }
    httpRequest.headers.set('content-type', 'application/json; charset=utf-8');

    final body = jsonEncode({
      'model': request.model,
      'max_tokens': request.maxTokens,
      'messages': _serializeMessages(request),
      if (request.tools.isNotEmpty)
        'tools': request.tools.map(_serializeTool).toList(),
      'stream': true,
    });
    httpRequest.add(utf8.encode(body));

    final response = await httpRequest.close();

    if (response.statusCode != 200) {
      final respBody = await response.transform(utf8.decoder).join();
      final msg = 'OpenAI-compatible API ${response.statusCode}: $respBody';
      switch (response.statusCode) {
        case 400:
          throw LlmBadRequestException(msg, responseBody: respBody);
        case 401:
        case 403:
          throw LlmAuthException(msg);
        case 429:
          throw LlmRateLimitException(msg);
        default:
          throw LlmTransientException(msg);
      }
    }

    yield* _handler.handle(response);
  }

  // ─────────────────────────── Serialization ───────────────────────────────

  /// Converts the provider-neutral [LlmRequest] into the OpenAI messages array.
  ///
  /// Key differences from Anthropic format:
  /// - System instructions become the first `{role: "system"}` message.
  /// - `LlmToolResultBlock`s must be emitted as separate `{role: "tool"}`
  ///   messages (not embedded in a user content array).
  /// - `LlmToolUseBlock`s in assistant turns become a `tool_calls` array,
  ///   with `input` re-encoded as a JSON string in `function.arguments`.
  static List<Map<String, dynamic>> _serializeMessages(LlmRequest request) {
    final out = <Map<String, dynamic>>[];

    // System instructions are a top-level message in OpenAI's format.
    if (request.systemInstructions.isNotEmpty) {
      out.add({'role': 'system', 'content': request.systemInstructions});
    }

    for (final msg in request.messages) {
      if (msg.role == LlmRole.assistant) {
        final textBlocks = msg.content.whereType<LlmTextBlock>().toList();
        final toolUseBlocks = msg.content.whereType<LlmToolUseBlock>().toList();

        final m = <String, dynamic>{'role': 'assistant'};
        final textContent =
            textBlocks.map((b) => b.text).join('');
        if (textContent.isNotEmpty) m['content'] = textContent;
        if (toolUseBlocks.isNotEmpty) {
          m['tool_calls'] = toolUseBlocks
              .map((b) => {
                    'id': b.id,
                    'type': 'function',
                    'function': {
                      'name': b.name,
                      'arguments': jsonEncode(b.input),
                    },
                  })
              .toList();
        }
        out.add(m);
      } else {
        // user role: tool results must be separate {role:"tool"} messages.
        // Emit tool results first (they follow the assistant's tool_calls),
        // then any accompanying user text.
        final toolResults =
            msg.content.whereType<LlmToolResultBlock>().toList();
        final textBlocks = msg.content.whereType<LlmTextBlock>().toList();

        for (final tr in toolResults) {
          out.add({
            'role': 'tool',
            'tool_call_id': tr.toolUseId,
            'content': tr.content,
          });
        }
        if (textBlocks.isNotEmpty) {
          out.add({
            'role': 'user',
            'content': textBlocks.map((b) => b.text).join('\n'),
          });
        }
      }
    }

    return out;
  }

  static Map<String, dynamic> _serializeTool(LlmTool tool) => {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.inputSchema,
        },
      };
}
