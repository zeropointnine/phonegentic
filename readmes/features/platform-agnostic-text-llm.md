# Platform-Agnostic Text LLM Subsystem

## Overview

The text LLM subsystem decouples the orchestration logic in `TextAgentService` from any specific LLM provider. All provider-specific code (HTTP transport, serialization, SSE parsing) lives behind two abstract interfaces. Swapping providers — or adding a new one — requires no changes to `TextAgentService` or `AgentService`.

---

## File Layout

```
lib/src/
├── agent_service.dart          # Builds List<LlmTool> extra-tool lists per integration
├── text_agent_service.dart     # Orchestration: history, retries, tool dispatch
└── llm/
    ├── llm_interfaces.dart         # All shared types + two abstract interfaces
    ├── claude_response_handler.dart # Anthropic SSE parsing
    └── claude_caller.dart           # Anthropic HTTP caller
```

---

## Core Types (`llm_interfaces.dart`)

### Content Blocks

```dart
sealed class LlmContentBlock {}
final class LlmTextBlock       extends LlmContentBlock { final String text; }
final class LlmToolUseBlock    extends LlmContentBlock { final String id, name; final Map<String,dynamic> input; }
final class LlmToolResultBlock extends LlmContentBlock { final String toolUseId, content; }
```

### Message

```dart
enum LlmRole { user, assistant }

class LlmMessage {
  final LlmRole role;
  final List<LlmContentBlock> content;
  bool get hasToolUse    => content.any((b) => b is LlmToolUseBlock);
  bool get hasToolResult => content.any((b) => b is LlmToolResultBlock);
}
```

### Tool Definition

`inputSchema` is a plain JSON Schema object. Each caller is responsible for wrapping it in the provider-specific envelope (`input_schema` for Anthropic, `parameters` for OpenAI-compatible).

```dart
class LlmTool {
  final String name, description;
  final Map<String, dynamic> inputSchema;
}
```

### Request

```dart
class LlmRequest {
  final String apiKey, model, systemInstructions;
  final List<LlmMessage> messages;
  final List<LlmTool> tools;
  final int maxTokens;   // default 1024
}
```

### Response Events

```dart
sealed class LlmResponseEvent {}
final class LlmTextDeltaEvent extends LlmResponseEvent { final String text; }
final class LlmToolCallEvent  extends LlmResponseEvent { final String id, name; final Map<String,dynamic> arguments; }
final class LlmDoneEvent      extends LlmResponseEvent {}
```

### Exception Hierarchy

```dart
sealed class LlmException implements Exception { final String message; }
final class LlmTransientException   extends LlmException {}   // retryable
final class LlmRateLimitException   extends LlmTransientException {}
final class LlmBadRequestException  extends LlmException {
  final String responseBody;
  bool get hasToolUseError => responseBody.contains('tool_use');
}
final class LlmAuthException        extends LlmException {}
```

`TextAgentService._callWithRetry()` retries on `LlmTransientException` (covers `LlmRateLimitException` via inheritance). `LlmAuthException` and `LlmBadRequestException` are not retried.

---

## Abstract Interfaces

```dart
abstract interface class LlmResponseHandler {
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes);
}

abstract interface class LlmCaller {
  Stream<LlmResponseEvent> call(LlmRequest request);
}
```

`LlmResponseHandler` parses a raw HTTP response byte stream. `LlmCaller` owns transport and delegates parsing to a handler. Cancellation is the caller's responsibility via `await for` break — neither interface owns the cancel signal.

---

## How `TextAgentService` Uses the Interfaces

`TextAgentService` holds a `late LlmCaller _caller` created by a factory based on the configured provider:

```dart
static LlmCaller _createCaller(TextAgentProvider provider, HttpClient http) {
  return switch (provider) {
    TextAgentProvider.claude => ClaudeCaller(http),
    TextAgentProvider.openai => throw UnimplementedError('OpenAI caller not yet implemented'),
  };
}
```

`updateConfig()` recreates `_caller` when the provider changes. The caller is invoked in `_callLlm()` via a plain `await for` over `_caller.call(req)`. `TextAgentService` never imports any provider-specific file.

---

## Existing Implementation: Anthropic Claude

### `ClaudeResponseHandler`

Statefully parses Anthropic's SSE stream. Accumulates `input_json_delta` chunks per tool block and emits a `LlmToolCallEvent` at `content_block_stop`. Emits `LlmTextDeltaEvent` for `text_delta`. Emits `LlmDoneEvent` at stream end.

### `ClaudeCaller`

Posts to `https://api.anthropic.com/v1/messages` with `x-api-key`, `anthropic-version: 2023-06-01`, and `content-type: application/json`. Serializes messages and tools to Anthropic's wire format:

- `LlmToolUseBlock` → `{type: "tool_use", id, name, input}`
- `LlmToolResultBlock` → `{type: "tool_result", tool_use_id, content}`
- `LlmTool` → `{name, description, input_schema: tool.inputSchema}`

Maps HTTP status codes to typed exceptions before streaming events.

---

## Adding a New Text LLM Provider

Use OpenAI-compatible endpoints as a worked example (OpenAI, OpenRouter, LM Studio, Ollama, etc.).

### Step 1 — Create `openai_response_handler.dart`

```dart
class OpenAiResponseHandler implements LlmResponseHandler {
  @override
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes) async* {
    // Parse SSE lines; each data payload is a JSON object.
    // Text: choices[0].delta.content
    // Tool calls: choices[0].delta.tool_calls[N].{id, function.name, function.arguments}
    //   Arguments arrive as partial JSON strings — accumulate per tool index,
    //   parse at stream end or when a new index appears.
    // Terminate on [DONE] or end of stream.
  }
}
```

Key differences from Anthropic:
- Tool call deltas carry an `index` field, not a `content_block_start` event.
- `function.arguments` is a partial JSON string accumulated across deltas.
- No `content_block_stop` signal — emit the tool call when the stream ends or when index changes.

### Step 2 — Create `openai_caller.dart`

```dart
class OpenAiCaller implements LlmCaller {
  final HttpClient _httpClient;
  final Uri _baseUrl;
  final Map<String, String> _extraHeaders;   // e.g. HTTP-Referer for OpenRouter
  final Map<String, dynamic> _extraBody;     // e.g. provider routing preferences

  OpenAiCaller(this._httpClient, {
    Uri? baseUrl,
    Map<String, String> extraHeaders = const {},
    Map<String, dynamic> extraBody = const {},
  }) : _baseUrl = baseUrl ?? Uri.parse('https://api.openai.com/v1/chat/completions'),
       _extraHeaders = extraHeaders,
       _extraBody = extraBody;

  @override
  Stream<LlmResponseEvent> call(LlmRequest request) async* {
    // 1. Serialize messages:
    //    - Prepend {role: "system", content: request.systemInstructions}
    //    - LlmTextBlock       → {role, content: text}
    //    - LlmToolUseBlock    → stored in assistant message as
    //                           tool_calls: [{id, type:"function", function:{name, arguments: jsonEncode(input)}}]
    //    - LlmToolResultBlock → {role: "tool", tool_call_id: toolUseId, content}
    //
    // 2. Serialize tools:
    //    {type: "function", function: {name, description, parameters: tool.inputSchema}}
    //
    // 3. POST with Authorization: Bearer <apiKey>
    //    Merge _extraHeaders and _extraBody into request.
    //
    // 4. Map errors: 400→LlmBadRequestException, 401→LlmAuthException,
    //               429→LlmRateLimitException, other→LlmTransientException
    //
    // 5. yield* OpenAiResponseHandler().handle(response)
  }
}
```

### Step 3 — Add the provider variant

In `agent_config_service.dart`, add `openai` (or `openRouter`, etc.) to `TextAgentProvider`.

### Step 4 — Wire up the factory

In `text_agent_service.dart`, extend `_createCaller`:

```dart
static LlmCaller _createCaller(TextAgentProvider provider, HttpClient http) {
  return switch (provider) {
    TextAgentProvider.claude   => ClaudeCaller(http),
    TextAgentProvider.openai   => OpenAiCaller(http),
    TextAgentProvider.openRouter => OpenAiCaller(
      http,
      baseUrl: Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
      extraHeaders: {'HTTP-Referer': 'https://your-app.com'},
    ),
  };
}
```

No other files need to change.

---

## What Does NOT Change When Adding a Provider

- `TextAgentService` history types (`List<LlmMessage>`)
- `TextAgentService` tool types (`List<LlmTool>`, `_baseTools`, `_extraTools`)
- `AgentService` extra-tool lists (already `List<LlmTool>`)
- `ToolCallRequest`, `ResponseTextEvent`, all public API surfaces
- Debounce timer, cancel logic, retry logic, history pruning, `_mergedHistory()`, `_stripDanglingToolUse()`, `_repairHistory()`
