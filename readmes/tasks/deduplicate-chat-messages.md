# Deduplicate Chat Messages

## Problem

Every app restart adds a new "Ready as [Job Function]" message to the chat. These are persisted to the session DB, so previous startup messages are restored alongside the new one. After several restarts, the chat panel fills with identical repeated messages.

## Solution

Added consecutive-duplicate detection at three points in `AgentService`:

1. **`_addMsg`** — before appending a new message, check if the last message in `_messages` has the same `text`, `role`, and `type`. If so, skip the add entirely (no persistence either).
2. **`_restoreSession`** — while loading messages from DB, skip any row that matches the previous message loaded (eliminates historical duplicates).
3. **`loadMoreHistory`** — same dedup within the older page, plus a boundary check against the first message already in memory to prevent duplicates at the page seam.

This approach is lightweight (no regex, no timers) and handles all message types generically — not just "Ready" messages.

## Files

- **Modified:** `phonegentic/lib/src/agent_service.dart` — dedup guards in `_addMsg`, `_restoreSession`, `loadMoreHistory`
