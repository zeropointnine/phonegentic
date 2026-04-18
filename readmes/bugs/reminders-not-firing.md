# Reminders Not Firing on Time

## Problem

Reminders set by the agent (e.g. "call me at 7:30") never actually trigger at the right time.

### Phase 1 root causes (fixed previously)

1. **Polling too slow**: `ManagerPresenceService` checks reminders every **5 minutes**, so a reminder can fire up to 5 minutes late (or be entirely missed within a window).
2. **No precise scheduling**: When an upcoming reminder is detected, no `Timer` is scheduled to fire at the exact `remind_at` time — it just waits for the next poll.
3. **Fired reminders don't demand action**: `sendSystemEvent` uses `requireResponse: false`, so the agent sees the reminder but doesn't act on it (e.g. initiate a call).
4. **No cancel/remove tool**: The agent has no `cancel_reminder` tool, so users can't ask to remove a reminder.

### Phase 2 root causes (fixed now)

5. **LLM sends local time as UTC**: The LLM sends `remind_at: 2026-04-18T07:58:00Z` — the `Z` suffix means UTC, but the LLM is thinking in the user's local timezone (e.g. PDT, UTC-7). So `07:58 UTC` becomes `00:58 PDT` — already 7 hours in the past. `DateTime.parse` correctly interprets the `Z` as UTC, causing the reminder to be stored as a past-due time.
6. **Past-due reminders not fired on creation**: `onReminderCreatedOrChanged()` only calls `_scheduleUpcomingTimers()` which queries for future reminders (`remind_at > now`). An already-past-due reminder is never picked up until the next periodic `_checkReminders` cycle — and even then, no logging existed to confirm it ran.
7. **No debug logging in fire path**: `_fireReminder` and `_checkReminders` had no `debugPrint` calls, making it impossible to diagnose whether reminders were found/fired.

## Solution

### Phase 1 (previous)

1. Reduce `_reminderCheckInterval` from 5 min → **1 min**.
2. Track per-reminder `Timer`s in `_scheduledReminderTimers`. Each poll schedules precise timers for any upcoming reminders within the next 15-min window. When a reminder is created, the presence service is notified to schedule immediately.
3. Change `sendSystemEvent` for fired reminders to `requireResponse: true` so the agent actually responds/acts.
4. Add `cancel_reminder` tool in `agent_service.dart` (LLM tools + both dispatch switches) and `whisper_realtime_service.dart`. Uses `updateReminderStatus(id, 'cancelled')` in the DB.

### Phase 2

5. **Strip UTC suffix in `_handleCreateReminder`**: Before `DateTime.parse`, strip trailing `Z`/`z` so the time is interpreted as local. Ensures `07:58` means 7:58 AM local, not 7:58 AM UTC.
6. **Fire past-due reminders in `onReminderCreatedOrChanged`**: After refreshing the cache, call `getPendingReminders()` and fire any already-due reminders before scheduling upcoming timers.
7. **Add `debugPrint` in `_fireReminder`, `_checkReminders`, and `onReminderCreatedOrChanged`** so the fire path is visible in logs.
8. **Await `_fireReminder` calls** in `_checkReminders` to avoid fire-and-forget races.

### Phase 3

9. **`start()` silent failure prevention**: Restructured `start()` so `_reminderCheckTimer` is created *before* any `await` calls, and wrapped async work in try-catch. Even if config/DB loading fails, the periodic check still runs.
10. **try-catch everywhere**: Wrapped `start()`, `_checkReminders()`, `onReminderCreatedOrChanged()`, and `_fireReminder()` in try-catch blocks with `debugPrint` so failures are always logged.

### Phase 4

11. **Provider is lazy — service never created**: `ChangeNotifierProxyProvider<AgentService, ManagerPresenceService>` defaults to `lazy: true`. Since no widget in the tree ever calls `context.watch<ManagerPresenceService>()` or `context.read<ManagerPresenceService>()`, the `create` callback never fires. The service is only referenced as a field on `AgentService` (set in the `update` callback), but `update` also never runs because `create` hasn't run. **The service was literally never instantiated.** This is why zero `[ManagerPresence]` logs appeared across multiple debugging sessions.
12. **Fix: `lazy: false`**: Added `lazy: false` to the provider in `main.dart` so `ManagerPresenceService` is created eagerly at app startup regardless of whether any widget reads it.

### Phase 5 (current)

13. **LLM bad time arithmetic for relative reminders**: When the user says "remind me in 5 minutes", the LLM has the current time in its system prompt but still miscalculates the absolute timestamp. In one case, the current time was 12:11 PM but the LLM computed `17:34` (off by 5+ hours) as the `remind_at` value. The agent told the user "5 minutes" but silently scheduled it for hours later.
14. **Fix: server-side time computation via delay/offset parameters**: Added `delay_minutes`, `delay_hours`, `delay_days`, and `at_time` parameters to `create_reminder` (both voice and text-agent tool definitions). The handler computes the exact `DateTime` server-side so the LLM never does time arithmetic:
    - `delay_days`, `delay_hours`, `delay_minutes` — additive offsets from `DateTime.now()`, can be freely combined (e.g. `delay_hours=1, delay_minutes=30` for "in an hour and a half")
    - `at_time` — `"HH:MM"` 24-hour format, overrides the time-of-day on the computed date. When used alone (no delay_* params), fires today if the time hasn't passed, otherwise tomorrow
    - `remind_at` — kept as a last-resort fallback for fully-specified absolute datetimes
    - System prompt gives explicit examples mapping natural language to parameters so the LLM never needs to compute timestamps

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — polling interval, precise timer scheduling, requireResponse, immediate past-due fire, logging
- `phonegentic/lib/src/agent_service.dart` — cancel_reminder tool + handler, timezone normalization, delay_minutes parameter + handler logic, updated system prompt instructions
- `phonegentic/lib/src/whisper_realtime_service.dart` — cancel_reminder and create_reminder tool definitions with delay_minutes
- `phonegentic/lib/main.dart` — lazy: false for ManagerPresenceService
- `readmes/bugs/reminders-not-firing.md` — this file
