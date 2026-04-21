# AI announces reminders meta-recursively

## Problem

When a calendar event reminder fires (15 minutes before a meeting), the AI says things like "The reminder for your meeting with Keith Bristol is scheduled for 10:45 AM." This is awkward — the user doesn't want to hear about the *reminder*, they want a heads-up about the *meeting*.

The root cause was in `_fireReminder` in `ManagerPresenceService`: the system event sent to the AI was `[REMINDER FIRED] $text — Please act on this reminder now.` regardless of whether it was a calendar meeting reminder or a user-created reminder. The AI then naturally framed its response around the word "reminder."

## Solution

- **`ManagerPresenceService._fireReminder`**: Now checks `source == 'calendar'`. For calendar-sourced reminders, sends `[UPCOMING MEETING] ... at HH:MM AM/PM` with explicit instructions to give a friendly meeting heads-up and NOT mention the word "reminder." Generic reminders keep the original `[REMINDER FIRED]` prompt.
- **`AgentService._buildReminderAndAwarenessContext`**: Added instructions telling the AI how to handle `[UPCOMING MEETING]` events — just a natural mention of the meeting, no "reminder" framing.

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — modified `_fireReminder`
- `phonegentic/lib/src/agent_service.dart` — updated reminder context instructions
