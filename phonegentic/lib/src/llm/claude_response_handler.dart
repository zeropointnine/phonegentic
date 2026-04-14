import 'dart:async';
import 'dart:convert';

import 'llm_interfaces.dart';

/// Parses Anthropic's SSE response stream into [LlmResponseEvent]s.
class ClaudeResponseHandler implements LlmResponseHandler {
  @override
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes) async* {
    String sseBuf = '';
    String? activeToolId;
    String? activeToolName;
    final activeToolInput = StringBuffer();

    await for (final chunk in rawBytes.transform(utf8.decoder)) {
      sseBuf += chunk;
      final lines = sseBuf.split('\n');
      sseBuf = lines.removeLast();

      for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') {
          yield const LlmDoneEvent();
          continue;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final type = json['type'] as String? ?? '';

          if (type == 'content_block_start') {
            final cb = json['content_block'] as Map<String, dynamic>?;
            if (cb?['type'] == 'tool_use') {
              activeToolId = cb!['id'] as String?;
              activeToolName = cb['name'] as String?;
              activeToolInput.clear();
            }
          } else if (type == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta?['type'] == 'text_delta') {
              final t = delta!['text'] as String? ?? '';
              if (t.isNotEmpty) yield LlmTextDeltaEvent(t);
            } else if (delta?['type'] == 'input_json_delta') {
              activeToolInput.write(delta!['partial_json'] as String? ?? '');
            }
          } else if (type == 'content_block_stop') {
            if (activeToolId != null && activeToolName != null) {
              Map<String, dynamic> parsedInput = {};
              try {
                final raw = activeToolInput.toString();
                if (raw.isNotEmpty) {
                  parsedInput = jsonDecode(raw) as Map<String, dynamic>;
                }
              } catch (_) {}
              yield LlmToolCallEvent(
                id: activeToolId,
                name: activeToolName,
                arguments: parsedInput,
              );
              activeToolId = null;
              activeToolName = null;
              activeToolInput.clear();
            }
          }
        } catch (_) {}
      }
    }

    yield const LlmDoneEvent();
  }
}
