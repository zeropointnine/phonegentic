# Google Calendar: Multi-calendar support + create new calendars

## Problem

When creating a Google Calendar event, the agent uses whatever default calendar Google Calendar's web UI selects. Users with multiple calendars (e.g. Personal, Work, Family) have no way to choose which calendar the event goes to. Additionally, users couldn't create new calendars through the agent.

## Solution

1. **List calendars**: `list_google_calendars` tool scrapes the sidebar of Google Calendar's day view via `div[data-id][jsname="o2uvtb"]` elements. The `data-id` attribute contains base64-encoded calendar email IDs, and the checkbox `aria-label` has the display name.
2. **Choose calendar for events**: Optional `calendar_id` parameter on `create_google_calendar_event` appends `&src=<calendarId>` to the eventedit URL.
3. **Create new calendars**: `create_new_google_calendar` tool navigates to `calendar.google.com/r/settings/createcalendar`, fills the name input using native setter + input/change events, and clicks the "Create calendar" button.
4. Agent instructions updated: when creating events, first list calendars; if more than one exists, ask which one.

## Files

- `phonegentic/lib/src/chrome/google_calendar_service.dart` — `listCalendars()`, `createCalendar()`, `calendarId` param on `createEvent`, JS scrapers
- `phonegentic/lib/src/agent_service.dart` — tool definitions, dispatch, handlers, updated instructions
- `readmes/bugs/calendar_fix.md` — updated with resolution
