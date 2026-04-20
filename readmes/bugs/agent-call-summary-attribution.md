# Agent Call Summary Attribution & Host Name

## Problem

Two issues with how the agent describes calls and attributes speakers:

1. **Wrong pronoun in call summaries**: When the agent makes an outbound call on the host's behalf (e.g., host texts "call Dave"), the post-call summary says "Dave answered and **you** spoke for over 4 minutes." The host was never on the call — the agent handled it alone. It should use "we" (agent + remote party), not "you."

2. **Host name not shown in transcripts**: The agent panel transcript bubbles display "Host" instead of the manager's actual name (e.g., "Patrick"), even though the manager name is configured. The `hostSpeaker.name` was never populated from `_agentManagerConfig.name`.

## Solution

### Agent-only call detection (pronoun fix)

- Added `CallHistoryDb.callIdsWithHostTranscripts()` — queries the `call_transcripts` table to find which calls have at least one `role = 'host'` transcript, distinguishing calls where the host was on the line from agent-only calls.
- `getCallActivitySummary()` now annotates each call line with `[agent-handled — host was NOT on this call]` when no host transcripts exist for a completed call.
- Added explicit prompt instructions in `_buildReminderAndAwarenessContext()` explaining the host vs agent distinction and directing the LLM to use "we" for agent-handled calls and "you" only when the host was actually on the line.

### Host speaker name sync

- Added `_syncHostSpeakerName()` method that propagates `_agentManagerConfig.name` to `hostSpeaker.name` when the name is configured but the speaker hasn't been named yet.
- Called from three places: after manager config loads in `_init()`, in `_syncBootContextFromJobFunction()`, and in `updateBootContext()` — ensuring the name is always set regardless of initialization order.

## Files

- `phonegentic/lib/src/db/call_history_db.dart` — added `callIdsWithHostTranscripts()`
- `phonegentic/lib/src/agent_service.dart` — updated `getCallActivitySummary()`, `_buildReminderAndAwarenessContext()`, added `_syncHostSpeakerName()`, called from init/boot context update paths
