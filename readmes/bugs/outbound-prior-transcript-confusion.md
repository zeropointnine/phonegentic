# Outbound Calls: Prior Transcript Causes Agent Confusion

## Problem

The agent injects the prior-call transcript for **all** calls — inbound and outbound. For outbound calls this is counterproductive: the user already knows why they're calling, and the injected transcript may be from a completely different conversation context (e.g., a previous call or SMS thread with a different person sharing the same number, or stale context from weeks ago). The agent then references or confuses this irrelevant history, leading to awkward or incorrect behavior.

## Solution

Gate the prior-transcript fetch so it only runs for **inbound** calls. For outbound calls the user initiated the call and has their own context — the agent doesn't need historical transcript injected.

The `_whisperPriorTranscriptOnce()` call sites don't need changes because they're already no-ops when `_priorCallTranscript` is null.

## Files

- `phonegentic/lib/src/agent_service.dart` — gate `_fetchPriorCallTranscript` on `!_isOutbound`
- `readmes/tasks/last-call-transcript-whisper.md` — updated design note
