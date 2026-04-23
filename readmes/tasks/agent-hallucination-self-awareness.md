# Agent self-awareness of Whisper hallucinations

## Problem

When the manager asks the agent "why are you responding to nothing?" or "are you hallucinating?" or "what does 'Thank God' mean in your log?", Alice has no concept of:

- What a Whisper hallucination is (religious loops, YouTube outros, "you you you")
- That her STT layer produces them on silence/noise
- That a filter drops them before they reach her, but the drop events are logged
- That she can inspect those log lines herself via `read_logs`

Without this context, she either makes up an answer or asks a confused clarifying question. She already has the `read_logs` tool — she just doesn't know it applies here.

Additionally: raw logs contain phone numbers, message bodies, SIP IDs, and other details that should **not** be read verbatim to an arbitrary caller. Only the manager (host, or inbound caller identified as manager) should get raw log content.

## Solution

Add a new `_buildHallucinationAwarenessContext()` section to the agent's system prompt, wired in alongside the existing `_buildReminderAndAwarenessContext()`. The section:

1. Briefly explains Whisper, the common hallucination classes Alice will see in her logs (religious loops, YouTube outros, "you/thank you" micro-loops), and that a filter drops them.
2. Tells her to use `read_logs` with `query="hallucination"` when asked about hallucinations, silent-mic responses, or weird transcripts.
3. **Privacy rule**: raw log content is manager-only. For non-manager callers, summarize at most ("my system filtered a few audio artifacts") and refuse to read lines out loud.
4. Encourages her to paraphrase what she finds rather than reading log lines verbatim, even to the manager, unless they explicitly ask for the raw text.

No new tools are added — `read_logs` already exists. This is pure prompt engineering to wire the existing capability to the existing question.

## Files

- `phonegentic/lib/src/agent_service.dart` — new `_buildHallucinationAwarenessContext()` method; called from `_buildTextAgentInstructions()`
