# Agent announces past meetings as upcoming, no acknowledge/reschedule lifecycle

## Problem

The agent kept telling the manager about "upcoming" meetings whose start time had already passed (sometimes by hours). Two issues converged:

1. **`ManagerPresenceService._fireReminder` had no awareness of the actual event.** It computed `eventTime = remindAt + 15min` and prompted `[UPCOMING MEETING] ... at HH:MM AM/PM — give the manager a brief, friendly heads-up that their meeting is coming up soon`. If firing was late (app offline, late wake-up after sleep, restart of the periodic timer), `eventTime` was already in the past but the prompt still claimed it was upcoming. There was no link from `agent_reminders` rows back to `calendar_events`, so we couldn't validate the underlying meeting.

2. **No real reminder lifecycle for the LLM.** The only tools were `create_reminder`, `list_reminders`, `cancel_reminder`. There was no way to acknowledge ("got it, stop nudging me") without cancelling — which conflated "I'm aware" with "the meeting is no longer happening". There was no way to reschedule a reminder either, so "snooze 15m" or "push it to tomorrow" forced the LLM to cancel + create a new one (and lose the link to the calendar event + contact).

3. **Calendar-panel edits created duplicate reminders** when a meeting time changed — `insertReminder` was called on every edit instead of moving the existing one.

4. **Startup "missed reminders" bubble surfaced stale calendar reminders.** `_checkMissedReminders` listed every overdue pending row without checking whether the underlying meeting had already ended, so on every restart the manager saw a missed bubble for meetings that ended yesterday.

## Solution

Five layered fixes:

1. **Link reminders to their calendar event.** Added `calendar_event_id INTEGER REFERENCES calendar_events(id)` and `contact_phone TEXT` to `agent_reminders` (DB v24). Calendar-panel populates both fields when scheduling the 15-min heads-up.

2. **Validate calendar reminders against the live event at fire time.** `_fireReminder` looks up the linked calendar row first:
   - Event row deleted → mark reminder `expired`, do not surface.
   - Event status `cancelled` / `deleted` → mark `expired`.
   - Event `end_time` already in the past → mark `expired` (this is the main fix for the user-reported bug).
   - Otherwise compute the prompt from the event's actual `start_time` and the current time:
     - More than 1 min away → `[UPCOMING MEETING] ... at HH:MM AM/PM (in N min)`.
     - Within ±2 min → `[MEETING STARTING NOW] ...`.
     - Already started → `[MEETING ALREADY STARTED] ... was at HH:MM AM/PM (N min ago)` and instruct the LLM to acknowledge the lateness instead of pretending it's upcoming.

3. **Stop duplicating reminders on calendar edits.** When the user changes a meeting time in the calendar panel, look up the existing pending reminder for that event id and call `updateReminderRemindAt` instead of `insertReminder`. Falls back to insert for legacy events created before the link existed.

4. **Filter the startup missed-list.** `_checkMissedReminders` runs the same expiry-validation pass as `_fireReminder` and silently marks already-ended-meeting reminders as `expired` instead of surfacing a "Missed (3h ago): Meeting at 2pm" bubble.

5. **New LLM tools for reminder lifecycle.** Three actions, with the existing `cancel_reminder` re-scoped:
   - **`acknowledge_reminder(id)`** — manager indicated awareness ("got it", "I know"); marks status `acknowledged`. The default response after a reminder fires and the manager replies casually. Keeps history intact.
   - **`cancel_reminder(id)`** — the underlying event itself is no longer happening. Removes from pending list.
   - **`reschedule_reminder(id, delay_*/at_time/remind_at, notify_contact)`** — moves the reminder to a new fire time. Same time-arg semantics as `create_reminder`. When `notify_contact=true` and the reminder is calendar-linked with a `contact_phone`, also sends a confirmation SMS to the attendee about the new time.

   System-prompt context spells out the lifecycle so the LLM picks the right action and does not pester the manager about the same reminder repeatedly once it has fired.

## Threat model preserved

- The `cancel_reminder` and `acknowledge_reminder` tools only update local DB state and do not place calls or send SMS — safe for any caller context.
- `reschedule_reminder` only sends SMS when explicitly requested (`notify_contact=true`) and only to the contact already linked on the calendar event row — it cannot be used to text arbitrary numbers.

## Files

- `phonegentic/lib/src/db/call_history_db.dart` — DB v24 migration, schema additions to `agent_reminders`, helpers `updateReminderRemindAt`, `getPendingReminderForCalendarEvent`, `getCalendarEventRowById`.
- `phonegentic/lib/src/manager_presence_service.dart` — calendar-event validation in `_fireReminder` and `_checkMissedReminders`, time-aware prompts (`UPCOMING` vs `STARTING NOW` vs `ALREADY STARTED`).
- `phonegentic/lib/src/widgets/calendar_panel.dart` — populate `calendar_event_id` + `contact_phone` on insert; reschedule existing pending reminder on edit instead of duplicating.
- `phonegentic/lib/src/agent_service.dart` — `acknowledge_reminder` and `reschedule_reminder` tool defs + handlers, dispatcher updates, lifecycle guidance in `_buildReminderAndAwarenessContext`.
