# Upcoming Reminder Countdown Banner

## Problem

Every minute, `_scheduleUpcomingTimers()` in `ManagerPresenceService` sends an `[UPCOMING REMINDERS]` system event into the chat panel. This creates a flood of duplicate messages (one per minute per reminder) that clutter the conversation — e.g. "in 8 min", "in 7 min", "in 6 min" all stacked on top of each other.

## Solution

1. **Remove** the `sendSystemEvent` call from `_scheduleUpcomingTimers()` so upcoming reminders no longer spam the chat.
2. **Add** an `_UpcomingReminderBanner` widget to the agent panel (similar to `_CalendarEventBanner`) that shows a live countdown for the next upcoming reminder. The countdown ticks every second and auto-hides when there are no upcoming reminders.
3. Keep the existing `_fireReminder` flow (which posts a single message when a reminder actually fires).

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — removed `sendSystemEvent` block from `_scheduleUpcomingTimers()`; added `notifyListeners()` so UI updates on cache refresh
- `phonegentic/lib/src/widgets/agent_panel.dart` — added `_UpcomingReminderBanner` widget with live ticker; placed it in the panel layout
