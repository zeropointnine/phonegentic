# SMS Conversation Context for Agent

## Problem

When someone sends an inbound SMS, the agent only sees the current message — it has no awareness of the prior conversation with that person. This means the agent can't understand context, follow up on previous threads, or give coherent replies that reference earlier messages.

## Solution

When an inbound SMS arrives, fetch the last 20 messages from that conversation (from the SQLite DB via `CallHistoryDb.getSmsMessagesForConversation`) and include them as context in the message sent to the agent. The history is formatted chronologically with timestamps and sender labels (contact name or "Manager (you)").

Key design decisions:
- **One-shot per session**: Track which phone numbers have already had their history injected via `_smsHistoryLoadedPhones`. On the first inbound message from a given number, prepend the conversation history. Subsequent messages from the same number in the same session skip the history since the agent already has it in context.
- **Dedup current message**: The just-received message is excluded from the history block since it appears in the main `SYSTEM EVENT` line.
- **Prefix convention**: Uses `SYSTEM CONTEXT —` prefix (distinct from `SYSTEM EVENT —`) so the agent can distinguish historical context from live events.
- **Session reset**: The tracking set is cleared on agent disconnect/reconnect and on fresh init, so a new session always re-loads history.
- **Graceful failure**: If the DB query fails, the error is logged and the agent still receives the current message normally.

## Files

- `phonegentic/lib/src/agent_service.dart` — modified `_onInboundSms` to async, added `_smsHistoryLoadedPhones` tracking, fetches and formats last 20 messages as context; clears tracking on reset/init
