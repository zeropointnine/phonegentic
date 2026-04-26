import 'dart:async';
import 'dart:convert';

import 'llm_interfaces.dart';

/// Parses an OpenAI-compatible (chat/completions) SSE response stream into
/// [LlmResponseEvent]s.
///
/// Works with OpenAI, OpenRouter, LM Studio, Ollama, and any provider that
/// follows the OpenAI streaming format: each `data:` line carries a JSON
/// object with `choices[0].delta`.
class OpenAiResponseHandler implements LlmResponseHandler {
  @override
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes) async* {
    String sseBuf = '';
    // Accumulate tool call fragments by their index in the delta array.
    final toolAccum = <int, _ToolAccum>{};

    await for (final chunk in rawBytes.transform(utf8.decoder)) {
      sseBuf += chunk;
      final lines = sseBuf.split('\n');
      sseBuf = lines.removeLast(); // incomplete trailing line held for next chunk

      for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty) continue;

        if (data == '[DONE]') {
          yield* _flushToolCalls(toolAccum);
          yield const LlmDoneEvent();
          return;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;

          // The final SSE chunk emitted under `stream_options.include_usage`
          // has `choices: []` and a top-level `usage` block. Surface it as
          // an LlmUsageEvent so callers can log cache hits.
          final usage = json['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            final promptDetails =
                usage['prompt_tokens_details'] as Map<String, dynamic>?;
            yield LlmUsageEvent(
              promptTokens: usage['prompt_tokens'] as int?,
              cachedPromptTokens: promptDetails?['cached_tokens'] as int?,
              completionTokens: usage['completion_tokens'] as int?,
            );
          }

          final choices = json['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final delta =
              (choices[0] as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;

          // Text delta
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield LlmTextDeltaEvent(content);
          }

          // Tool call deltas — each carries an `index` key
          final toolCalls = delta['tool_calls'] as List<dynamic>?;
          if (toolCalls != null) {
            for (final tc in toolCalls) {
              final tcMap = tc as Map<String, dynamic>;
              final idx = tcMap['index'] as int;
              final id = tcMap['id'] as String?;
              final function = tcMap['function'] as Map<String, dynamic>?;
              final name = function?['name'] as String?;
              final argsFragment = function?['arguments'] as String?;

              final accum = toolAccum.putIfAbsent(idx, () => _ToolAccum());
              if (id != null) accum.id = id;
              if (name != null) accum.name = name;
              if (argsFragment != null) accum.argsBuf.write(argsFragment);
            }
          }
        } catch (_) {}
      }
    }

    // Stream ended without [DONE]
    yield* _flushToolCalls(toolAccum);
    yield const LlmDoneEvent();
  }

  static Stream<LlmResponseEvent> _flushToolCalls(
      Map<int, _ToolAccum> toolAccum) async* {
    final sorted = toolAccum.entries.toList()..sort((a, b) => a.key - b.key);
    for (final entry in sorted) {
      final t = entry.value;
      Map<String, dynamic> args = {};
      try {
        final raw = t.argsBuf.toString();
        if (raw.isNotEmpty) args = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
      yield LlmToolCallEvent(id: t.id, name: t.name, arguments: args);
    }
  }
}

class _ToolAccum {
  String id = '';
  String name = '';
  final argsBuf = StringBuffer();
}
