# Session Transcript Persistence

## Problem

When the app restarts, the agent panel transcript is completely lost. Users lose all context from their previous session — chat messages, system events, transcripts, SMS bubbles, etc. The in-memory `_messages` list in `AgentService` is ephemeral and gets cleared on every `_init()` call.

Additionally, if a transcript grows very large (potentially gigabytes over extended use), loading the entire history into memory at startup would be catastrophic for performance and memory usage.

## Solution

### Storage: SQLite `session_messages` table

Reuse the existing `CallHistoryDb` SQLite database (already initialized at startup). A new `session_messages` table stores every `ChatMessage` that appears in the agent panel, serialized with all fields needed for faithful reconstruction (role, type, text, speaker, metadata as JSON).

### Write path: fire-and-forget inserts

Each time a message is added to `_messages`, it's also inserted into `session_messages` via a non-blocking call. When messages are cleared (reconnect, reset), the table is truncated. This keeps the DB in sync with the in-memory list without blocking the UI thread.

### Read path: infinite scroll with windowed loading

On startup, only the **most recent N messages** (default 200) are loaded into memory. The agent panel's `_MessageList` already uses a reversed `ListView.builder`, which is perfect for infinite scroll — when the user scrolls near the top of the loaded window, older messages are fetched in batches from SQLite using cursor-based `WHERE rowid < ?` queries (O(1) seek via B-tree, no OFFSET scan).

This means even a 10 GB transcript database is fine — we never load more than one batch at a time, and SQLite's rowid index makes fetching the next page instant regardless of how deep we are in the history.

### Garbage collection

A configurable max row count (default 50,000) is enforced: after each insert, if the count exceeds the cap, the oldest rows are pruned. This prevents unbounded growth.

### Persistence lifecycle

1. `_persistEnabled = false` during init — transient "Connecting..." / "Loading..." messages are never written to DB
2. After init completes (or fails/early-returns), `_restoreSession()` loads the last 200 messages from `session_messages` into `_messages`
3. `_persistEnabled = true` — all subsequent `_addMsg()` calls fire-and-forget insert to DB
4. Streaming messages are persisted on creation; their text is updated in DB when finalized (`_updatePersistedText`)
5. Reconnect does NOT clear history — it logs a "Reconnecting…" system message and re-inits. The transcript is one continuous record across reconnects. Job function switches are already recorded as "Switched to ..." system messages.

### Infinite scroll

`_MessageList` is now a `StatefulWidget` with a `NotificationListener<ScrollNotification>`. When `extentAfter < 300px` (user scrolled near the visual top), `loadMoreHistory()` is called on `AgentService`, which fetches the next page via cursor-based `WHERE id < ?` query and `insertAll(0, ...)` prepends them. A loading spinner appears at the top while fetching. `hasMoreSessionHistory` tracks whether more pages exist.

## Files

| File | Changes |
|------|---------|
| `lib/src/models/chat_message.dart` | Added `toDbMap()` / `fromDbMap()` serialization; `MessageAction.toMap()` / `fromMap()` |
| `lib/src/db/call_history_db.dart` | DB version 16→17; `session_messages` table; insert/load/clear/delete/update/count methods |
| `lib/src/agent_service.dart` | `_addMsg()` / `_removeMsgAt()` / `_updatePersistedText()` helpers; `_restoreSession()` / `loadMoreHistory()`; init flow wiring; reconnect clears DB |
| `lib/src/widgets/agent_panel.dart` | `_MessageList` → `StatefulWidget` with `NotificationListener` for infinite scroll; loading spinner |
