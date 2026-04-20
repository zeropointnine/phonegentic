# Conversation Search Filter

## Problem

The conversation detail view (SMS thread with a contact) has no way to search/filter messages within the current conversation. Other list screens (Contacts, Messages, Call History) all have a search input in their headers — the conversation view should too.

## Solution

Add a search `TextField` to the conversation header row, positioned between the contact name/phone and the action buttons. Reuse the exact same styling pattern from `contact_list_panel.dart` / `messaging_panel.dart` (height 34, `AppColors.card` fill, 8px radius, 0.5px border, `Icons.search_rounded` prefix, 13px font). Filter the message list client-side by matching message text against the query (case-insensitive).

## Files

- `phonegentic/lib/src/widgets/conversation_view.dart` — added search controller, search field in header, message filtering logic
