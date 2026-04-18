# Agent Internal Events, Presence Tracking, and Activity Awareness

## Problem

The agent has no concept of timed events or reminders — when the manager asks "remind me to call John at 3pm", there is no mechanism to persist that and fire it later. The manager also has no visibility into what happened while they were away from the app: calls that came in, recordings made, or upcoming obligations. There is no tracking of whether the manager is actively using the app, so the agent can't distinguish between "manager is here and listening" vs "manager stepped away 20 minutes ago". This means:

- Reminders spoken during conversation are lost the moment the conversation moves on
- The manager has to manually check call history every time they return to the app
- The agent can't proactively offer a catch-up briefing
- There's no way to play back call recordings inline from the agent chat
- Calendar events created via voice have no local persistence for reminder purposes

## Solution

### 1. ManagerPresenceService (`manager_presence_service.dart`)

A new `ChangeNotifier + WidgetsBindingObserver` service that tracks app focus state. When the app loses focus for 5+ minutes, the manager is marked as "away". On return, the service builds an activity summary (calls, recordings, fired reminders) and delivers it as either:
- **Quiet badge** (default): A reminder-type chat message with action chips
- **Proactive greeting**: A `sendSystemEvent` with `requireResponse: true` so the agent speaks the summary

Also runs a 5-minute periodic timer to check for due reminders, firing them as chat messages and feeding silent context to the agent about upcoming ones.

### 2. Database Schema (v14)

New `agent_reminders` table with status lifecycle: `pending` -> `fired` -> `dismissed`/`snoozed`. Indexed on `remind_at` and `status` for efficient periodic queries. CRUD methods: `insertReminder`, `getPendingReminders`, `getUpcomingReminders`, `updateReminderStatus`.

### 3. Agent Tools

Four new tools available in both OpenAI Realtime and split-pipeline (Claude) paths:
- **`create_reminder`**: Inserts a timed reminder and optionally creates a Google Calendar event via the existing `_handleCreateGoogleCalendarEvent` handler
- **`list_reminders`**: Queries all pending (or all) reminders so the agent can answer "are there any reminders?". Also, pending reminders are proactively included in the agent's system instructions via `_buildReminderAndAwarenessContext` so lighter models don't even need to tool-call.
- **`get_call_summary`**: Queries call records since a given time, builds a formatted synopsis with caller names, directions, durations, and recording availability
- **`play_call_recording`**: Looks up a call record's recording path and injects an inline audio player into the chat

### 4. Startup Missed-Reminder Triage

On app launch, `ManagerPresenceService.start()` schedules a delayed (2s) `_checkMissedReminders` call. This queries all pending reminders whose `remind_at` is in the past — i.e. they were due while the app was closed. Each missed reminder is surfaced as a special reminder bubble showing how long ago it was due (e.g. "Missed (2h ago): Call John") with two action chips:
- **Still do this**: Marks the reminder as `fired` and sends a system event to the agent with `requireResponse: true`, so the agent acts on it (e.g. offers to make a call).
- **Dismiss**: Marks the reminder as `dismissed` in the database.

This runs only once per service lifecycle (`_startupCheckDone` flag).

### 5. Chat UI

- **`MessageType.reminder`**: New message type with bell icon, accent-tinted background, and action chips (Dismiss, Snooze 15m, Tell me more)
- **Missed reminder variant**: Uses `addMissedReminderMessage` which shows "Still do this" / "Dismiss" instead of the normal Snooze/Tell-me-more actions
- **Inline recording player**: Detects `recording_playback` metadata and renders a `just_audio` player with seek slider, play/pause, and duration display — same pattern as the existing `_RecordingPlayer` in call history

### 5. Google Calendar Timeout Guards

All Puppeteer-based Google Calendar tool handlers (`sync_google_calendar`, `read_google_calendar`, `create_google_calendar_event`, `list_google_calendars`, `create_new_google_calendar`) now have 30-second timeouts. Previously, if the Chrome automation failed to find a browser tab, the future would hang indefinitely — causing the tool to never return a result, the LLM loop to stall, and Chrome to keep retrying (opening browser windows in an endless loop). The timeout returns a graceful failure string so the agent can report the error and move on.

The local calendar context heading was also clarified from "Calendar Schedule" to "Local Calendar (Calendly-synced events stored in the app)" with explicit instructions not to use Google Calendar tools when the manager asks about their local schedule.

### 6. Configuration

`AwayReturnConfig` in `UserConfigService` persists the quiet-badge vs proactive-greeting preference via SharedPreferences.

## Files

| Action | File |
|--------|------|
| New | `phonegentic/lib/src/manager_presence_service.dart` |
| Modify | `phonegentic/lib/src/db/call_history_db.dart` (schema v14, `agent_reminders` table + CRUD) |
| Modify | `phonegentic/lib/src/models/chat_message.dart` (`MessageType.reminder` + constructor) |
| Modify | `phonegentic/lib/src/user_config_service.dart` (`AwayReturnMode`, `AwayReturnConfig`, load/save) |
| Modify | `phonegentic/lib/src/agent_service.dart` (3 tools, handlers, instructions, `addReminderMessage`) |
| Modify | `phonegentic/lib/src/whisper_realtime_service.dart` (3 new tool schemas in session tools) |
| Modify | `phonegentic/lib/src/widgets/agent_panel.dart` (reminder bubble, inline recording player) |
| Modify | `phonegentic/lib/main.dart` (`ManagerPresenceService` provider wiring) |
