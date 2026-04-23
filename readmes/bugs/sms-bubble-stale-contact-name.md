# SMS Bubble Shows Stale Contact Name

## Problem

When a contact's display name is updated (e.g. changed from "Tess" back to "Patrick"), the SMS thread bubbles in the agent panel continue showing the old name. This happens because:

1. `ChatMessage.sms()` bakes the contact name into message metadata at creation time (`sms_contact_name`)
2. `SmsThreadBubble._displayName` checks the baked metadata **first** and only falls back to the live `ContactService` if metadata has no name
3. The widget uses `context.read<ContactService>()` (one-shot) instead of `context.watch` so it never rebuilds when contacts change

## Solution

Flip the lookup priority in `SmsThreadBubble._displayName`:
1. Check the live `ContactService` first via `context.watch` (so the widget rebuilds on contact changes)
2. Fall back to the baked `sms_contact_name` metadata only when no live contact is found
3. Final fallback remains the formatted phone number

## Files

- `phonegentic/lib/src/widgets/sms_thread_bubble.dart` — modified `_displayName` getter
