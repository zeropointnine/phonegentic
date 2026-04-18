# Agent repeating greeting on inbound calls

## Problem

On inbound calls, the AI agent speaks its greeting twice — nearly identical text
gets generated and played through TTS back-to-back.

**Root cause:** `_tryFireConnectedGreeting()` calls two methods that each invoke
`sendUserMessage` on the text agent:

1. `_whisperPriorTranscriptOnce()` → `sendUserMessage(historyPrompt)` → triggers `_respond()`
2. Greeting prompt → `sendUserMessage(prompt)` → but `_respond()` is already running, so `_pendingRespond = true`

The first LLM call generates a greeting based on the prior-transcript context.
When it finishes, the queued `_pendingRespond` fires a second LLM call which
generates a nearly identical greeting from the explicit greeting prompt. Both
stream text to TTS, so the agent speaks twice.

The existing `_isDuplicateAgentMessage` check catches the second response in the
UI, but by then the TTS has already been fed audio chunks during streaming.

## Solution

**Fix 1 — single LLM call:** Changed `_whisperPriorTranscriptOnce` to use
`addSystemContext` (non-triggering) instead of `sendUserMessage` when in split
pipeline mode. The prior transcript now gets folded into the pending context and
flushed alongside the greeting prompt in a single `_respond()` call.

**Fix 2 — TTS cleanup on duplicate detection:** When `_isDuplicateAgentMessage`
fires during `_appendStreamingResponse`, we now also set `_ttsInterrupted = true`,
call `stopResponseAudio()`, and `clearTTSQueue()` so any already-streamed audio
for the duplicate is discarded.

## Files

- `phonegentic/lib/src/agent_service.dart` — both fixes
