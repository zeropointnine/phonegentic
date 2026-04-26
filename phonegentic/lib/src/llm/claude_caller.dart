import 'dart:convert';
import 'dart:io';

import 'claude_response_handler.dart';
import 'llm_interfaces.dart';

/// Calls the Anthropic Messages API and streams back [LlmResponseEvent]s.
class ClaudeCaller implements LlmCaller {
  final HttpClient _httpClient;
  final LlmResponseHandler _handler;

  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicVersion = '2023-06-01';

  ClaudeCaller(this._httpClient) : _handler = ClaudeResponseHandler();

  @override
  Stream<LlmResponseEvent> call(LlmRequest request) async* {
    final HttpClientResponse response;
    try {
      final uri = Uri.parse(_endpoint);
      final httpRequest = await _httpClient.postUrl(uri);

      httpRequest.headers.set('x-api-key', request.apiKey);
      httpRequest.headers.set('anthropic-version', _anthropicVersion);
      httpRequest.headers.set('content-type', 'application/json; charset=utf-8');

      final body = jsonEncode({
        'model': request.model,
        'max_tokens': request.maxTokens,
        'system': request.systemInstructions,
        'messages': request.messages.map(_serializeMessage).toList(),
        'tools': request.tools.map(_serializeTool).toList(),
        'stream': true,
      });
      httpRequest.add(utf8.encode(body));

      response = await httpRequest.close();
    } on HttpException catch (e) {
      throw LlmTransientException('Claude HTTP error: $e');
    } on SocketException catch (e) {
      throw LlmTransientException('Claude socket error: $e');
    } on HandshakeException catch (e) {
      throw LlmTransientException('Claude TLS handshake error: $e');
    } on TlsException catch (e) {
      throw LlmTransientException('Claude TLS error: $e');
    }

    if (response.statusCode != 200) {
      final respBody = await response.transform(utf8.decoder).join();
      final msg = 'Claude API ${response.statusCode}: $respBody';
      switch (response.statusCode) {
        case 400:
          throw LlmBadRequestException(msg, responseBody: respBody);
        case 401:
          throw LlmAuthException(msg);
        case 429:
          throw LlmRateLimitException(msg);
        default:
          throw LlmTransientException(msg);
      }
    }

    try {
      yield* _handler.handle(response);
    } on HttpException catch (e) {
      throw LlmTransientException('Claude stream HTTP error: $e');
    } on SocketException catch (e) {
      throw LlmTransientException('Claude stream socket error: $e');
    }
  }

  // ─────────────────────────── Serialization ───────────────────────────────

  static Map<String, dynamic> _serializeMessage(LlmMessage msg) {
    return {
      'role': msg.role == LlmRole.user ? 'user' : 'assistant',
      'content': msg.content.map(_serializeBlock).toList(),
    };
  }

  static Map<String, dynamic> _serializeBlock(LlmContentBlock block) {
    return switch (block) {
      LlmTextBlock(:final text) => {'type': 'text', 'text': text},
      LlmToolUseBlock(:final id, :final name, :final input) => {
          'type': 'tool_use',
          'id': id,
          'name': name,
          'input': input,
        },
      LlmToolResultBlock(:final toolUseId, :final content) => {
          'type': 'tool_result',
          'tool_use_id': toolUseId,
          'content': content,
        },
    };
  }

  static Map<String, dynamic> _serializeTool(LlmTool tool) {
    return {
      'name': tool.name,
      'description': tool.description,
      'input_schema': tool.inputSchema,
    };
  }
}
