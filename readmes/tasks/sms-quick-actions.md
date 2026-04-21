# SMS Quick Actions & Defaults

## Problem

1. The SMS checkbox in the Edit Event dialog defaulted to checked — users don't want to auto-send an SMS every time they save an edit.
2. No way to quickly SMS a contact directly from a calendar event card without opening the edit dialog.
3. When a calendar reminder fires in the agent panel, there's no quick way to SMS the contact about the upcoming meeting.

## Solution

### SMS default off in Edit dialog
Changed `_notifyRecipient` from `true` to `false` in `_EditEventDialogState`. New Event dialog keeps it as `true` since that's a deliberate creation.

### SMS icon on event cards
Added a small SMS icon button (`_SmsQuickButton`) in the top-right corner of calendar event cards (only shown when the event has an `inviteeName`). Tapping it:
1. Looks up the contact's phone number via `CallHistoryDb.searchContacts`
2. Sends a quick heads-up SMS about the appointment
3. Shows a snackbar confirmation

### SMS action on reminder bubbles
When a calendar-sourced reminder fires in the agent panel:
- The contact name is extracted from the description ("Meeting with $name") and passed through `ChatMessage.reminder` metadata as `contact_name`
- An "SMS" action chip with an `sms_rounded` icon is added to the reminder bubble actions
- Tapping it looks up the contact phone and sends a quick SMS, same as the event card

### Month view event pills
Replaced the tiny 4px dots in `_MonthDayCell` with full-width `_EventPill` widgets — 13px-tall rounded pills showing the event time, title, and an SMS icon (if the event has a contact). Up to 5 pills render per day cell with a "+N more" overflow label. Grid `childAspectRatio` changed from `1.0` to `0.72` and physics from `NeverScrollable` to `Clamping` to accommodate the taller cells.

## Files

- `phonegentic/lib/src/widgets/calendar_panel.dart` — SMS default off in edit dialog, `_SmsQuickButton` widget (with configurable `size`), `_EventPill` in month view, month grid aspect ratio
- `phonegentic/lib/src/widgets/agent_panel.dart` — added `_sendReminderSms` handler, `sms_contact` action, `icon` param on `_ReminderChip`, imported `MessagingService`
- `phonegentic/lib/src/agent_service.dart` — `addReminderMessage` accepts `contactName`, adds SMS action
- `phonegentic/lib/src/manager_presence_service.dart` — extracts contact name from description, passes to `addReminderMessage`
- `phonegentic/lib/src/models/chat_message.dart` — `ChatMessage.reminder` accepts `contactName` param, stores in metadata
