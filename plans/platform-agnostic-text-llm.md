# Plan: Platform-Agnostic Text LLM Subsystem

## Context

`TextAgentService` is tightly coupled to Anthropic's Claude API: raw `List<Map<String,dynamic>>` history in Claude's wire format, `_callClaude()` with hard-coded headers/SSE parsing, tool definitions in Anthropic's `input_schema` format. The goal is to introduce a clean interface layer so an OpenAI-compatible endpoint can be swapped in without touching the orchestration logic in `TextAgentService` or `AgentService`.

---

## New Files

### `lib/src/llm/llm_interfaces.dart`

All shared types plus two abstract interfaces.

**Content block sealed hierarchy:**
```dart
sealed class LlmContentBlock {}
final class LlmTextBlock      extends LlmContentBlock { final String text; ... }
final class LlmToolUseBlock   extends LlmContentBlock { final String id, name; final Map<String,dynamic> input; ... }
final class LlmToolResultBlock extends LlmContentBlock { final String toolUseId, content; ... }
```

**Message:**
```dart
enum LlmRole { user, assistant }

class LlmMessage {
  final LlmRole role;
  final List<LlmContentBlock> content;
  bool get hasToolUse    => content.any((b) => b is LlmToolUseBlock);
  bool get hasToolResult => content.any((b) => b is LlmToolResultBlock);
}
```

**Tool definition** — schema is raw JSON Schema `Map`; callers wrap it in provider-specific key (`input_schema` vs `parameters`):
```dart
class LlmTool {
  final String name, description;
  final Map<String, dynamic> inputSchema;  // provider-neutral JSON Schema object
}
```

**Request:**
```dart
class LlmRequest {
  final String apiKey, model, systemInstructions;
  final List<LlmMessage> messages;
  final List<LlmTool> tools;
  final int maxTokens;   // default 1024
}
```

**Response events (sealed):**
```dart
sealed class LlmResponseEvent {}
final class LlmTextDeltaEvent extends LlmResponseEvent { final String text; }
final class LlmToolCallEvent  extends LlmResponseEvent { final String id, name; final Map<String,dynamic> arguments; }
final class LlmDoneEvent      extends LlmResponseEvent { const LlmDoneEvent(); }
```

**Exception hierarchy:**
```dart
sealed class LlmException implements Exception { final String message; }
final class LlmTransientException   extends LlmException { }
final class LlmBadRequestException  extends LlmException {
  final String responseBody;
  bool get hasToolUseError => responseBody.contains('tool_use');
}
final class LlmAuthException        extends LlmException { }
final class LlmRateLimitException   extends LlmTransientException { }
```

**Abstract interfaces:**
```dart
abstract interface class LlmResponseHandler {
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes);
}

abstract interface class LlmCaller {
  Stream<LlmResponseEvent> call(LlmRequest request);
}
```

---

### `lib/src/llm/claude_response_handler.dart`

`ClaudeResponseHandler implements LlmResponseHandler`

Extracts the SSE parsing loop from `_callClaude()` in `text_agent_service.dart:482–538`. Variables (`sseBuf`, `activeToolId`, `activeToolName`, `activeToolInput`, `toolBlocks`) become local to `handle()`. Emits:
- `LlmTextDeltaEvent` for `text_delta`
- `LlmToolCallEvent` for each completed `tool_use` block at `content_block_stop`
- `LlmDoneEvent` at stream end (or `[DONE]`)

Does **not** own cancellation — that's the caller's responsibility via `await for` break.

---

### `lib/src/llm/claude_caller.dart`

`ClaudeCaller implements LlmCaller`

Constructor takes `HttpClient` (same one from `TextAgentService`). Internally creates `ClaudeResponseHandler`.

**`call(LlmRequest) → Stream<LlmResponseEvent>`:**
1. Serialize `request.messages` → Anthropic JSON (`content` array of blocks; `tool_use`/`tool_result` map to their Anthropic equivalents).
2. Serialize `request.tools` → `[{name, description, input_schema: ...}]` (just rename `inputSchema` → `input_schema`).
3. POST to `https://api.anthropic.com/v1/messages` with headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json; charset=utf-8`.
4. Map HTTP errors: 400 → `LlmBadRequestException(body)`, 401 → `LlmAuthException`, 429 → `LlmRateLimitException`, other → `LlmTransientException`. Wrap `HttpException`/`SocketException` as `LlmTransientException`.
5. `yield* _handler.handle(response)` to stream parsed events.

**Serialization helpers (private static):**
- `_serializeMessage(LlmMessage)` — switch on `LlmRole`, `_serializeBlock` on each content block
- `_serializeBlock(LlmContentBlock)` — switch expression on sealed variants (text/tool_use/tool_result)
- `_serializeTool(LlmTool)` — `{name, description, input_schema: tool.inputSchema}`

---

## Modified Files

### `lib/src/text_agent_service.dart`

**Type changes:**
- `_history: List<Map<String,dynamic>>` → `List<LlmMessage>`
- `_baseTools: static const List<Map>` → `static final List<LlmTool>` (convert all 11 tools; pull `input_schema` value into `LlmTool.inputSchema`)
- `_extraTools: List<Map>` → `List<LlmTool>`
- `setExtraTools(List<Map>)` → `setExtraTools(List<LlmTool>)`

**New field:** `late LlmCaller _caller` — created in constructor and recreated in `updateConfig()` when provider changes.

**Factory (private static):**
```dart
static LlmCaller _createCaller(TextAgentProvider p, HttpClient http) {
  return switch (p) {
    TextAgentProvider.claude => ClaudeCaller(http),
    TextAgentProvider.openai => throw UnimplementedError('OpenAI caller not yet implemented'),
  };
}
```

**`_flushPendingToHistory()`** — creates `LlmMessage(role: LlmRole.user, content: [LlmTextBlock(text)])` instead of a raw map.

**`sendUserMessage()`** — same, creates `LlmMessage` directly.

**`addToolResult()`** — builds `LlmMessage(role: user, content: [...optionalTextBlock, LlmToolResultBlock(toolUseId, content)])`.

**`_respond()`** — remove the `if provider == claude` branch; call `_callWithRetry()` unconditionally.

**`_callWithRetry()` (replaces `_callClaudeWithRetry()`):**
- Same retry loop (up to `_maxRetries`, transient detection by exception type)
- Catches `LlmBadRequestException`: if `hasToolUseError`, calls `_dumpMergedHistory()` + `_repairHistory()` then rethrows (so the error surfaces in `_respond()`'s catch)
- Catches `LlmTransientException` as the retryable category (avoids string-matching `e.toString()`)

**`_callLlm()` (replaces `_callClaude()`):**
```dart
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
  final toolCalls = <LlmToolCallEvent>[];
  bool cancelled = false;
  await for (final event in _caller.call(req).timeout(Duration(seconds: _responseTimeoutSecs))) {
    if (_cancelRequested) { cancelled = true; break; }
    switch (event) {
      case LlmTextDeltaEvent(:final text):
        fullText += text;
        _responseController.add(ResponseTextEvent(text: text, isFinal: false));
      case LlmToolCallEvent():
        toolCalls.add(event);
      case LlmDoneEvent():
        break;
    }
  }
  _cancelRequested = false;
  // write assistant turn to _history, emit final events, add pending tool IDs
  // prune _history (same logic as current, adapted for LlmMessage)
}
```

**`_mergedHistory()` rewrite** — operates on `List<LlmMessage>`, returns `List<LlmMessage>`. Merge same-role consecutive messages by combining their `content` lists. Call `_stripDanglingToolUse()` on result. No more `_toBlocks()` helper needed.

**`_stripDanglingToolUse()` rewrite** — same algorithm, uses pattern matching on `LlmToolUseBlock`/`LlmToolResultBlock` instead of map key checks.

**`_repairHistory()` rewrite** — same algorithm with typed objects.

**`_dumpMergedHistory()` rewrite** — pattern match on sealed content blocks for debug output.

**Remove:** `_callClaude()`, `_callClaudeWithRetry()`, `_toBlocks()`.

**New imports:** `llm/llm_interfaces.dart`, `llm/claude_caller.dart`.

---

### `lib/src/agent_service.dart`

Convert the four `*Claude` static const tool lists to `List<LlmTool>`:
- `_flightToolsClaude` (lines ~1166–1205)
- `_gmailToolsClaude` (lines ~1275–1335)
- `_googleCalendarToolsClaude` (lines ~1404–1464)
- `_googleSearchToolsClaude` (lines ~1497–1513)

Each entry becomes `LlmTool(name: ..., description: ..., inputSchema: {...})` where `inputSchema` is the existing `input_schema` map value.

Update `_applyIntegrationTools()`: `claudeExtra` changes from `List<Map<String,dynamic>>` to `List<LlmTool>`.

**`_whisper.setExtraTools(oaiExtra)` — unchanged** (separate OpenAI realtime pipeline).

---

## Migration Order (atomically compilable)

1. Create `llm_interfaces.dart`
2. Create `claude_response_handler.dart`
3. Create `claude_caller.dart`
4. Migrate `text_agent_service.dart` (history types, tools, caller, call methods, history helpers)
5. Migrate `agent_service.dart` extra tool lists + `_applyIntegrationTools()`

Steps 4 and 5 must be done together before the app compiles (step 4 changes `setExtraTools` signature; step 5 satisfies the new signature).

---

## What Does NOT Change

- `AgentService` stream consumption (`responses`, `toolCalls`) — unchanged public API
- `ToolCallRequest` class — stays as-is, `_callLlm()` maps `LlmToolCallEvent` → `ToolCallRequest` before emitting on `_toolCallController`
- `ResponseTextEvent` — still emitted from `_responseController`
- `TextAgentProvider.openai` guard in `_initTextAgent()` — remains, now enforced by factory throwing `UnimplementedError`
- Debounce timer, `_pendingContext`, `cancelCurrentResponse()`, `reset()`, `dispose()` — no changes needed
- `agent_config_service.dart` — no changes needed

---

## Adding OpenAI / OpenRouter Later

When ready, implement `OpenAiCaller` and `OpenAiResponseHandler`:
- Request: no top-level `system` key; instead prepend `{role: "system", content: systemInstructions}` to messages
- Tools: wrap `LlmTool` as `{type: "function", function: {name, description, parameters: inputSchema}}`
- SSE: parse `choices[0].delta.content` for text, `choices[0].delta.tool_calls` for tool calls
- Message format: tool calls come as `tool_calls` array in assistant message; tool results as `{role: "tool", tool_call_id, content}`
- Update `_createCaller()` factory to return `OpenAiCaller` for `TextAgentProvider.openai`

For OpenRouter: `OpenAiCaller` takes `baseUrl`, `extraHeaders` (HTTP-Referer, X-Title), `extraBodyFields` (provider routing prefs) at construction. Point at `https://openrouter.ai/api/v1`. No changes to `LlmRequest` or history types needed.

---

## Verification

1. `flutter analyze` — zero new warnings/errors
2. Build and run: make a call, observe transcript flowing to LLM, response streaming to TTS
3. Trigger a tool call (e.g., ask agent to search contacts) — verify round-trip: `ToolCallRequest` emitted → handler runs → `addToolResult` called → second LLM turn completes
4. Simulate transient error: temporarily set wrong API key, verify retries fire and error surfaces in UI
5. Cancel an in-flight response: verify `cancelCurrentResponse()` stops streaming and saves partial text to history
