# Calendar Sync Consistency & UI Overhaul

## Problem

The three-way calendar sync between Calendly, Google Calendar, and the local SQLite database has several consistency issues:

1. **No event source tracking** -- `CalendarEvent` has `calendlyEventId` but no general `source` field and no `googleCalendarEventId`. Events imported from Google Calendar get inserted as new rows on every sync cycle because there's no dedup key.
2. **Bidirectional sync creates duplicates** -- `syncBidirectional()` pulls events from Google then pushes ALL local events back (including freshly-pulled ones), duplicating events in both directions.
3. **Circular sync** -- A Calendly event syncs into the app, gets pushed to Google Calendar, then re-imports from GCal as a separate duplicate on the next cycle.
4. **No visual source distinction** -- All events render with `AppColors.accent` regardless of origin. Users can't tell whether an event came from Calendly, Google Calendar, or was created locally.
5. **Title inconsistency** -- Calendly returns generic titles like "30 Minute Meeting" without invitee context; GCal scrapes aria-labels that may include embedded time ranges.
6. **No setup guidance** -- When a user opens the calendar panel without any integrations configured, they see an empty grid with no indication of how to connect Calendly or Google Calendar.

## Solution

### Event Source Tracking (Model + DB)

Added `EventSource` enum (`local`, `calendly`, `google`) and `googleCalendarEventId` field to `CalendarEvent`. DB schema bumped to v18 with migration adding `source` and `google_calendar_event_id` columns plus indexes.

### Deduplication Fix

- `upsertCalendarEvent` now has three dedup paths: by `calendly_event_id`, by `google_calendar_event_id`, or plain insert for local events. All paths preserve user-assigned `job_function_id` when updating.
- Google Calendar events get a stable composite ID (`gcal:date:startTime:title`) so they don't create new rows on each sync cycle.
- `syncToGoogle` skips events with `source == google` or `source == calendly` (Calendly's own GCal integration handles that), breaking the circular sync loop.

### Source Color Scheme + Legend

Three distinct colors per theme for event sources:
- **Calendly**: `burntAmber` (warm brown / purple depending on theme)
- **Google Calendar**: `green`
- **Local**: `accent` (amber / cyan)

Applied to:
- Week view event blocks (background tint + bold left border)
- Month view day dots (each dot colored by its event's source)
- Agent panel banner (small colored dot next to the calendar icon)
- Compact legend row in the calendar panel header (dot + label for each source)

### Title Enrichment

Calendly events now include the invitee name when available: "30 Minute Meeting" becomes "30 Minute Meeting — John Smith". Extracts invitee name/email from `event_guests` and `event_memberships` in the Calendly API response.

### Setup Guidance Card

When no integrations are configured and no events exist, the calendar panel shows a centered card with instructions for connecting Calendly (API key) and Google Calendar (Chrome debug), each styled with their source color.

### Simplified Main Nav Menu

The hamburger/overflow menu now only contains **Settings**. Messages and Calendar have been promoted to dedicated icon buttons in the wide nav bar (matching the existing pattern for Contacts, Call History, etc.). When the screen is narrow (collapsed), all items still appear in the menu for accessibility.

### 15-Minute Reminders

Creating or rescheduling an event now inserts an `agent_reminders` row 15 minutes before the start time (source=`calendar`). `ManagerPresenceService.onReminderCreatedOrChanged()` is called so the timer infrastructure picks it up immediately.

### Calendly Cancel + Re-Invite

Added `CalendlyService.cancelEvent(uri)` which calls `POST /scheduled_events/{uuid}/cancellation`. When editing an event that has an existing `calendlyEventId`, the old booking is canceled first, then a new invitee is created at the updated time so the recipient gets notified of the change.

### Google Calendar — Auto-Create 'Calendly' Calendar

Both the dialog save methods and the background `syncToGoogle` now check for a 'Calendly' calendar in Google Calendar. If none exists, `createCalendar(name: 'Calendly')` is called before creating events, ensuring events always land in the correct calendar rather than the default.

### Sync Overwrite Protection (`locally_modified` flag)

Background sync was overwriting user-edited event times. The 2-minute Calendly poll would fetch the original event time and `upsertCalendarEvent` would blindly update the local row, reverting the user's changes. Fixed by adding a `locally_modified` INTEGER column (DB v19). `updateCalendarEvent` sets this flag when `markLocallyModified: true` (used by the Edit dialog's save). `upsertCalendarEvent` now checks the flag and skips overwriting any row that has `locally_modified = 1`.

### Unified Contact Field

Replaced the two-mode contact field (search field → mini fields + Clear button) with a single unified layout: the Name field doubles as the search input (shows autocomplete results as you type 2+ characters), with Phone and Email always visible below. No "Clear" button — just click into any field and edit directly. Matches the dialpad's search-as-you-type pattern.

### SMS Notification

The "SMS Contact" checkbox now calls `MessagingService.sendMessage` with a contextual message. For new events: appointment confirmation. For edits: includes the old → new time if changed, or a generic "has been updated" if only other fields changed.

## Files

| Action | File |
|--------|------|
| Modify | `phonegentic/lib/src/models/calendar_event.dart` |
| Modify | `phonegentic/lib/src/db/call_history_db.dart` |
| Modify | `phonegentic/lib/src/calendly_service.dart` |
| Modify | `phonegentic/lib/src/chrome/google_calendar_service.dart` |
| Modify | `phonegentic/lib/src/theme_provider.dart` |
| Modify | `phonegentic/lib/src/widgets/calendar_panel.dart` |
| Modify | `phonegentic/lib/src/widgets/agent_panel.dart` |
| Modify | `phonegentic/lib/src/dialpad.dart` |
| New    | `readmes/features/calendar-sync-consistency.md` |
