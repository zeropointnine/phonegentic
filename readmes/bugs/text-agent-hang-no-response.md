# Text Agent Hang / No Response

## Problem

The agent appeared to start correctly (SIP registered, TTS ready, OpenAI Realtime connected) but never responded to user messages typed in the chat. The log showed:

```
flutter: [AgentService] User message → Claude: "Can you tell me the flights ..."
```

…followed by silence — no Claude response, no error, no tool-call log. This happened consistently after ~70 seconds of idle time.

Two root causes were found in `TextAgentService`:

### 1. No HTTP timeout on the Claude API call

`_callClaude()` uses `dart:io`'s `HttpClient` with no timeout. If the TCP connection to `api.anthropic.com` stalls (slow DNS, flaky network, server issue), `await request.close()` waits forever. This leaves `_responding = true` indefinitely with no log output.

### 2. Silent message drop when `_responding = true`

`_respond()` checks `if (_responding) return` at the top with no logging and no retry. When `sendUserMessage()` is called while a Claude call is already in-flight, the user message is added to `_history` but `_respond()` returns immediately. After the in-flight call finishes, the `finally` block only reschedules via `_scheduleFlush()` if `_pendingContext` is non-empty — it does NOT check for unprocessed user history. Result: the user message is lost forever.

## Solution

### Timeout

Wrapped `_callClaude()` in a 45-second `.timeout()` inside `_callClaudeWithRetry()`. `TimeoutException` is classified as transient so it triggers the existing retry logic (up to 2 retries). The user sees an error message in the chat if all retries fail.

### `_pendingRespond` flag

Added a `bool _pendingRespond` field. When `_respond()` is called while `_responding == true`, it sets `_pendingRespond = true` (and logs a debug message). In the `finally` block, if `_pendingRespond` is true and no tool calls are outstanding, `_respond()` is called again immediately via `unawaited()`. This ensures queued user messages are always processed after the current call completes.

### Debug logging

Both early-return paths in `_respond()` now `debugPrint`, making future hangs immediately visible in the log:

```
[TextAgentService] _respond: already responding, will retry after
[TextAgentService] _respond: waiting for N tool result(s)
[TextAgentService] _respond: processing queued request
```

## Files

- `phonegentic/lib/src/text_agent_service.dart` — all three fixes
