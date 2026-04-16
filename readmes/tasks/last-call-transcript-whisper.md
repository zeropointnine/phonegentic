# Last-Call Transcript Whisper

## Problem

When a call connects, the agent has no memory of previous conversations with the same caller/callee. This means the agent can't reference prior topics, follow up naturally, or maintain continuity across calls — making interactions feel disconnected and stateless.

## Solution

When a call begins (initiating/ringing phase), asynchronously look up the most recent completed call with the same remote phone number and fetch its transcript. When the connected greeting fires, inject a condensed summary of the prior transcript as system context so the agent can reference it naturally.

Key design decisions:
- **Async pre-fetch**: The DB lookup happens at call start so it's ready by the time the call connects — no latency added to the greeting.
- **Suffix-match on last 10 digits**: Reuses existing `normalizePhone` logic for reliable matching across formatting variants.
- **Truncation**: Prior transcripts are capped at ~2000 characters to avoid bloating the context window. Older turns are trimmed first, keeping the end of the conversation (most relevant for follow-up).
- **Both directions**: Works for inbound and outbound calls.

## Files

- `phonegentic/lib/src/db/call_history_db.dart` — added `getLastTranscriptForRemote()` query
- `phonegentic/lib/src/agent_service.dart` — added `_priorCallTranscript` field, async fetch on call start, injection into connected greeting, cleanup on call end
