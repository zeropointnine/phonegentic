# Call History — Message Button

## Problem

Call history entries only had a call/redial button. There was no way to quickly start an SMS conversation with a number directly from the call history panel.

## Solution

Added a messaging icon (chat bubble) next to the existing call button on each call history entry, in both the collapsed row and the expanded header. Tapping it closes the call history panel, opens the messaging panel, and selects/creates the conversation for that phone number — mirroring the same pattern used in the contacts list.

## Files

- `phonegentic/lib/src/widgets/call_history_panel.dart` — added `MessagingService` import, `_openMessage` method, and chat bubble icon buttons in both collapsed and expanded entry views
