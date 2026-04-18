# Google Calendar: Ask which calendar to use

## Problem

When creating a Google Calendar event, the agent uses whatever default calendar Google Calendar's web UI selects. Users with multiple calendars (e.g. Personal, Work, Family) have no way to choose which calendar the event goes to.

## Solution

1. Add a `list_google_calendars` tool that scrapes the sidebar of Google Calendar's day view to discover available calendars (name + ID).
2. Add an optional `calendar_id` parameter to `create_google_calendar_event`. When provided, appends `&src=<calendarId>` to the eventedit URL so Google Calendar targets the correct calendar.
3. Update agent system instructions to tell the agent: when creating events, first list calendars; if more than one exists, ask the user which one to use before proceeding.

## Files

- `phonegentic/lib/src/chrome/google_calendar_service.dart` — add `listCalendars()` method + JS scraper, add `calendarId` param to `createEvent`
- `phonegentic/lib/src/agent_service.dart` — new tool definition, dispatch, handler, updated instructions
- `readmes/bugs/calendar_fix.md` — updated with resolution
