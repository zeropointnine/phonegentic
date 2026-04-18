# Agent should ask which calendar to add an event to, not just whatever is default

## Status: Fixed

## Solution

Added a `list_google_calendars` tool that scrapes available calendars from Google Calendar's sidebar. The agent's instructions now tell it to call this tool before creating events and, if multiple calendars exist, ask the user which one to use. The chosen calendar ID is passed via the new `calendar_id` parameter on `create_google_calendar_event`, which appends `&src=<id>` to the eventedit URL.

See `readmes/tasks/google-calendar-multi-calendar.md` for full details.
