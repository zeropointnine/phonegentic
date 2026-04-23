# Feature: Startup Reconciliation (Missed SMS + Overdue Reminders)

## Problem

When the agent was offline (app closed, laptop asleep, STT model not loaded,
Claude not configured at the time of the inbound), two classes of events
silently piled up:

1. **Inbound SMS** — persisted by `MessagingService` but never surfaced to the
   agent because `AgentService._onInboundSms` short-circuits on `!_active`.
2. **Reminders past their `remind_at`** — left in `status = 'pending'`. The UI
   surfaces them as bubbles (`ManagerPresenceService._checkMissedReminders`)
   but the LLM has no awareness, so the agent can't proactively mention them
   or fold them into a greeting when the manager reopens the app.

The manager's expectation is: "when the app comes back, the agent should tell
me what I missed."

## Solution

Add a single `_reconcileOnStartup()` entry point on `AgentService`, run at the
end of successful initialization (both the Realtime path in `_init` and the
local-STT path in `_initLocalSttPath`). It:

1. Loads a persisted `agent_reconcile_last_at_ms` timestamp from
   `shared_preferences`. On first run the window defaults to *now − 24h*.
2. Queries **unanswered inbound SMS** via a new
   `CallHistoryDb.getUnansweredInboundSms(since:)` — threads where the latest
   non-deleted message is inbound and newer than `since`.
3. Queries **overdue reminders** via the existing
   `CallHistoryDb.getPendingReminders()` (`status = 'pending'` and
   `remind_at <= now`).
4. If either set is non-empty, builds one compact `[SYSTEM CATCH-UP]` message
   and sends it through `sendSystemEvent(..., requireResponse: true)`. This
   both:
   - Adds a chat-UI system bubble.
   - Sends to the LLM as a user turn so the agent greets the manager with the
     catch-up.
5. Updates `agent_reconcile_last_at_ms` to the moment reconciliation runs, so
   next startup only considers items that arrived after this run.

### Division of responsibility

`ManagerPresenceService._checkMissedReminders` is untouched — it continues to
surface individual reminder bubbles (so the manager can dismiss / snooze each
one inline). `_reconcileOnStartup` is strictly the **LLM-facing** channel: it
gives the agent the semantic state of "here's what you missed" so the agent
can proactively discuss it. The two surfaces are complementary.

### SMS "responded-to" heuristic

There is no `agent_responded` column in `sms_messages`. The heuristic is:
"an inbound SMS whose thread has no outbound message after it is unanswered."
This is implemented as a correlated `NOT EXISTS` subquery on `remote_phone`.
If the manager replied via the native Messages app *or* the agent fired
`send_sms` / `reply_sms` inside the thread, that outbound row is present and
the inbound is considered answered.

### Windowing

Only inbound SMS received `>= last_reconcile_time` are considered, so:

- First launch → 24h window.
- Subsequent launches → strictly since the previous reconciliation.
- A message that is surfaced once but remains unanswered is **not** re-flagged
  on the next startup unless a new inbound arrived in the same thread (thread
  tip moves forward). This trades off "nag until acknowledged" for "don't
  spam the manager with the same item every launch." The manager still sees
  unanswered threads in the SMS UI.

### Caps

- Up to **8** unanswered SMS threads and **8** overdue reminders are included
  verbatim. Overflow is reported as "… and N more" so the system event stays
  small.

## Architecture

```
┌────────────────────┐       startup
│  AgentService._init│ ─────┐
└────────────────────┘      ▼
           │         _reconcileOnStartup()
           │                │
           │                ├── CallHistoryDb.getUnansweredInboundSms(since)
           │                ├── CallHistoryDb.getPendingReminders()
           │                └── SharedPreferences.setInt(last_at)
           │                │
           │                ▼
           │       sendSystemEvent('[SYSTEM CATCH-UP] …',
           │                        requireResponse: true)
           ▼                │
    chat UI bubble          ▼
                    _textAgent.sendUserMessage(...)
                            │
                            ▼
                       Claude greets
                    with catch-up summary
```

## Files

- `phonegentic/lib/src/db/call_history_db.dart` — new
  `getUnansweredInboundSms({DateTime? since, int limit})`.
- `phonegentic/lib/src/agent_service.dart` — new `_reconcileOnStartup()`,
  plus calls from `_init()` and `_initLocalSttPath()`; adds
  `shared_preferences` import.
- `readmes/features/startup-reconciliation.md` — this file.
