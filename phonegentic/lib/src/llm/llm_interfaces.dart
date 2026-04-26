// Platform-agnostic types and interfaces for the text LLM subsystem.
// Concrete implementations (ClaudeCaller, OpenAiCaller, etc.) live in
// sub-files alongside this one.

// ─────────────────────────────── Content Blocks ─────────────────────────────

sealed class LlmContentBlock {}

final class LlmTextBlock extends LlmContentBlock {
  final String text;
  LlmTextBlock(this.text);
}

final class LlmToolUseBlock extends LlmContentBlock {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  LlmToolUseBlock({required this.id, required this.name, required this.input});
}

final class LlmToolResultBlock extends LlmContentBlock {
  final String toolUseId;
  final String content;
  LlmToolResultBlock({required this.toolUseId, required this.content});
}

// ──────────────────────────────────── Message ────────────────────────────────

enum LlmRole { user, assistant }

class LlmMessage {
  final LlmRole role;
  final List<LlmContentBlock> content;

  LlmMessage({required this.role, required this.content});

  bool get hasToolUse => content.any((b) => b is LlmToolUseBlock);
  bool get hasToolResult => content.any((b) => b is LlmToolResultBlock);
}

// ─────────────────────────────────── Tool ────────────────────────────────────

/// Provider-neutral tool definition.
/// [inputSchema] is a plain JSON Schema object.
/// Callers are responsible for wrapping it in the provider-specific key
/// (`input_schema` for Anthropic, `parameters` for OpenAI-compatible APIs).
class LlmTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const LlmTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

// ──────────────────────────────────── Request ────────────────────────────────

class LlmRequest {
  final String apiKey;
  final String model;
  final String systemInstructions;
  final List<LlmMessage> messages;
  final List<LlmTool> tools;
  final int maxTokens;

  const LlmRequest({
    required this.apiKey,
    required this.model,
    required this.systemInstructions,
    required this.messages,
    required this.tools,
    this.maxTokens = 2048,
  });
}

// ──────────────────────────────── Response Events ────────────────────────────

sealed class LlmResponseEvent {
  const LlmResponseEvent();
}

final class LlmTextDeltaEvent extends LlmResponseEvent {
  final String text;
  LlmTextDeltaEvent(this.text);
}

final class LlmToolCallEvent extends LlmResponseEvent {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  LlmToolCallEvent(
      {required this.id, required this.name, required this.arguments});
}

final class LlmDoneEvent extends LlmResponseEvent {
  const LlmDoneEvent();
}

/// Token-usage stats reported by the provider at the end of a stream.
/// Surfacing these lets us see whether prompt caching is hitting (the
/// difference between a hot and cold cache is roughly 50% of input cost
/// and a comparable drop in TTFT).
///
/// Fields are nullable because not every provider/model reports them
/// (e.g. older OpenAI-compatible third parties may omit the usage chunk
/// entirely even when `stream_options.include_usage=true` is requested).
final class LlmUsageEvent extends LlmResponseEvent {
  /// Total tokens in the input prompt (system + messages + tools).
  final int? promptTokens;

  /// Of [promptTokens], how many were served from OpenAI's prompt cache.
  /// `cached_tokens == promptTokens` is a perfect cache hit; `0` is a
  /// full cold call.
  final int? cachedPromptTokens;

  /// Tokens generated in the response.
  final int? completionTokens;

  const LlmUsageEvent({
    this.promptTokens,
    this.cachedPromptTokens,
    this.completionTokens,
  });
}

// ───────────────────────────────── Exceptions ────────────────────────────────

sealed class LlmException implements Exception {
  final String message;
  const LlmException(this.message);
  @override
  String toString() => message;
}

final class LlmTransientException extends LlmException {
  const LlmTransientException(super.message);
}

final class LlmBadRequestException extends LlmException {
  final String responseBody;
  LlmBadRequestException(super.message, {required this.responseBody});
  bool get hasToolUseError => responseBody.contains('tool_use');
}

final class LlmAuthException extends LlmException {
  const LlmAuthException(super.message);
}

final class LlmRateLimitException extends LlmTransientException {
  const LlmRateLimitException(super.message);
}

// ───────────────────────────────── Interfaces ────────────────────────────────

abstract interface class LlmResponseHandler {
  /// Parse a raw HTTP response byte stream into platform-agnostic events.
  Stream<LlmResponseEvent> handle(Stream<List<int>> rawBytes);
}

abstract interface class LlmCaller {
  /// Send [request] to the LLM and stream back response events.
  /// Throws an [LlmException] subtype on HTTP/network errors.
  /// Cancellation is the caller's responsibility: break the `await for` loop.
  Stream<LlmResponseEvent> call(LlmRequest request);
}
