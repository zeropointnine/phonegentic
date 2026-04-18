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

### Phase 2 (current)

5. **Strip UTC suffix in `_handleCreateReminder`**: Before `DateTime.parse`, strip trailing `Z`/`z` so the time is interpreted as local. Ensures `07:58` means 7:58 AM local, not 7:58 AM UTC.
6. **Fire past-due reminders in `onReminderCreatedOrChanged`**: After refreshing the cache, call `getPendingReminders()` and fire any already-due reminders before scheduling upcoming timers.
7. **Add `debugPrint` in `_fireReminder`, `_checkReminders`, and `onReminderCreatedOrChanged`** so the fire path is visible in logs.
8. **Await `_fireReminder` calls** in `_checkReminders` to avoid fire-and-forget races.

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — polling interval, precise timer scheduling, requireResponse, immediate past-due fire, logging
- `phonegentic/lib/src/agent_service.dart` — cancel_reminder tool + handler, notify presence on create, timezone normalization
- `phonegentic/lib/src/whisper_realtime_service.dart` — cancel_reminder tool definition
- `readmes/bugs/reminders-not-firing.md` — this file
