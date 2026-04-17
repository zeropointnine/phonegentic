# Contact Message Button

## Problem

The contact detail card only has Call and Delete action buttons. There's no way to quickly start an SMS conversation with a contact from their detail view — users have to manually open the Messages panel and type the number.

## Solution

Added a **Message** action button between Call and Delete on the `ContactCard`. Tapping it:

1. Closes the contacts panel
2. Opens the messaging panel (if not already open)
3. Selects/creates a conversation with the contact's phone number (E.164 formatted)

The button uses `Icons.message_rounded` with the app's accent color, matching the existing action button style.

## Files

- **`phonegentic/lib/src/widgets/contact_card.dart`** — Added `onMessage` callback prop; added Message `_CardAction` between Call and Delete with conditional spacing
- **`phonegentic/lib/src/widgets/contact_list_panel.dart`** — Added `MessagingService` import; added `_messageContact` handler that closes contacts, opens messaging panel, and selects the conversation; wired `onMessage` callback to `ContactCard`
