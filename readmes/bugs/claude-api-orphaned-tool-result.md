# Bug: Claude API 400 — Orphaned `tool_result` in Conversation History

## Error

```
Claude API 400: {"type":"error","error":{"type":"invalid_request_error",
"message":"messages.0.content.0: unexpected `tool_use_id` found in `tool_result`
blocks: toolu_01YCJYqcxBKf8B2tuiavof7L. Each `tool_result` block must have a
corresponding `tool_use` block in the previous message."}}
```

## Root Cause

Three interacting issues in `TextAgentService` allowed the conversation history
sent to Claude to contain `tool_result` blocks without a matching `tool_use` in
the preceding assistant message.

### 1. History trimming orphaned tool_result blocks

The history cap (`_maxHistory = 60`) removed messages from the front with
`_history.removeAt(0)` in a blind loop. When an assistant message containing a
`tool_use` block was trimmed away, the corresponding `tool_result` user message
survived — becoming the first message in the array (`messages.0`). Claude
rejected it because there was no prior assistant message with that `tool_use_id`.

### 2. Debounce flush interleaved between tool_use and tool_result

After `_callClaude` completed and emitted tool calls, `_respond` set
`_responding = false` and called `_scheduleFlush()` if pending transcript context
existed. If the 1.5s debounce timer fired before `addToolResult` was called, a
plain-text user message got inserted between the assistant's `tool_use` and the
`tool_result`:

```
assistant: [{tool_use, id: "toolu_xxx"}]
user:      "transcript text"                        ← sandwiched
user:      [{tool_result, tool_use_id: "toolu_xxx"}]
```

### 3. `_mergedHistory` only merged plain-string user messages

The merge logic checked `out.last['content'] is String` before combining
consecutive same-role messages. When one message was a plain string and the next
was a structured list (tool_result), they remained as two separate user messages —
violating Claude's requirement that a `tool_result` user message immediately
follow the assistant message containing the `tool_use`.

## Fix

**`addToolResult`** — Cancel the debounce timer and fold any pending context
directly into the tool_result message as a text block, preventing interleaving:

```dart
void addToolResult(String toolUseId, String result) {
  _debounceTimer?.cancel();
  final blocks = <Map<String, dynamic>>[];
  if (_pendingContext.isNotEmpty) {
    blocks.add({'type': 'text', 'text': _pendingContext.join('\n')});
    _pendingContext.clear();
  }
  blocks.add({
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'content': result,
  });
  _history.add({'role': 'user', 'content': blocks});
  _respond();
}
```

**History trimming** — After the max-length trim, strip leading messages that
would be invalid (assistant-first or orphaned tool_result):

```dart
while (_history.isNotEmpty) {
  final first = _history.first;
  if (first['role'] == 'assistant') { _history.removeAt(0); continue; }
  final content = first['content'];
  if (content is List &&
      content.any((b) => b is Map && b['type'] == 'tool_result')) {
    _history.removeAt(0);
    continue;
  }
  break;
}
```

**`_mergedHistory`** — Handle mixed content types (string + structured list) by
normalizing to content blocks via a `_toBlocks` helper before merging:

```dart
if (out.isNotEmpty && out.last['role'] == role) {
  final prev = out.last['content'];
  if (prev is String && content is String) {
    out.last = {'role': role, 'content': '$prev\n\n$content'};
  } else {
    out.last = {
      'role': role,
      'content': [..._toBlocks(prev), ..._toBlocks(content)],
    };
  }
}
```

## File Changed

- `phonegentic/lib/src/text_agent_service.dart`

---

## Phase 2 — Recurrence During Idle SMS Pile-up

### Problem

Same 400 error returned repeatedly after the agent sat idle with a pile-up of
queued inbound-SMS events. The merged-history dump showed:

```
[0]  user: [tool_result(toolu_012bxR1...), text(235)]   ← orphan result
...
[46] user: [tool_result(...), text(265), text(269), text(242), text(306),
            text(251), text(258), text(259), text(265)]  ← merged pile-up
```

Two gaps in the Phase 1 fix surfaced:

1. **`_repairHistory` only stripped dangling `tool_use`** — it never handled
   the *orphan `tool_result`* case (Phase-1 post-trim cleanup runs only at the
   *end* of `_callLlm`, so when a 400 aborted mid-call the unhealthy state
   persisted into the retry).
2. **`_callWithRetry` rethrew after repair** — the repair succeeded but the
   same bad request got reported to the user; no retry was performed with the
   repaired history.
3. **Post-response trim was not pair-aware** — `removeAt(0)` could drop an
   assistant-`tool_use` while leaving its paired user-`tool_result` in place.
   The cleanup loop dropped the leading orphan but in some interleavings
   (multiple pairs near the front) still produced unbalanced states.
4. **Loop-breaker counter never reset for non-voice input** — SMS and typed
   messages did not reset `_consecutiveAgentResponses`, so after a voice-driven
   loop the agent silently suppressed responses to legitimate host/SMS input.

### Fix

1. `_repairHistory` now strips **both** dangling `tool_use` *and* orphan
   `tool_result` blocks (any `tool_result` whose matching `tool_use` is not
   present in an earlier assistant message).
2. `_callWithRetry` retries the request once after a successful repair on a
   `tool_use` 400, instead of immediately rethrowing.
3. `_trimHistory` drops **pairs atomically**: when an assistant-`tool_use` is
   dropped, the immediately-following user-`tool_result` is dropped with it.
4. `TextAgentService.sendUserMessage` resets the loop-breaker flag the
   `AgentService` owns by exposing a reset hook; `AgentService.sendUserMessage`
   and `_onInboundSms` both reset `_consecutiveAgentResponses` on a genuine
   inbound text.

## Additional Files Changed

- `phonegentic/lib/src/text_agent_service.dart` — pair-aware trim, orphan
  `tool_result` repair, retry-after-repair
- `phonegentic/lib/src/agent_service.dart` — reset consecutive counter on SMS
  and typed host messages
