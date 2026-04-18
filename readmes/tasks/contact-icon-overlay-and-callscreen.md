# Contact Icon on Overlay & Call Screen Edit vs Add

## Problem

Three UX issues around contacts and messaging from the dialpad/call screen:

1. The dialpad autocomplete overlay dropdown rows show phone and message icons but no contact icon, making it impossible to open a contact's details directly from search results.
2. On the call screen, the "Contact" action button always shows an add-person icon (`person_add_outlined`) even when the remote party is already a saved contact. This is misleading — it should show a regular edit/view contact icon when the contact exists.
3. Tapping the message icon from the autocomplete overlay (or the call screen Message button) opens the messaging panel to the conversation list instead of navigating directly to the conversation for that contact. Root cause: `toggleOpen()` fires `notifyListeners()` before `selectConversation()` sets `_selectedRemotePhone`, so the panel renders its list state first.

## Solution

1. **Autocomplete overlay**: The `onContact` callback and icon were already wired into the `DialpadAutocompleteDropdown` widget and passed from the dialpad. Verified no further changes needed.

2. **Call screen**: In `_buildActionButtons`, look up the remote identity against `ContactService.lookupByPhone` to determine whether the party is already saved. If a contact exists, render `Icons.person_outline_rounded` (view/edit); otherwise keep `Icons.person_add_outlined` (add new). The underlying `_handleAddContact` handler already routes correctly via `openContactForPhone` which handles both new and existing contacts.

3. **Message open-to-conversation**: Added `MessagingService.openToConversation(phone)` which sets both `_isOpen` and `_selectedRemotePhone` before the first `notifyListeners()`, so the panel renders directly into the conversation view. Updated `_onAutocompleteMessage` (dialpad) and `_handleSendMessage` (call screen) to use this new method.

## Files

| Action | File |
|--------|------|
| Modify | `phonegentic/lib/src/callscreen.dart` — conditional contact icon, message opens to conversation |
| Modify | `phonegentic/lib/src/messaging/messaging_service.dart` — added `openToConversation()` |
| Modify | `phonegentic/lib/src/dialpad.dart` — use `openToConversation()` in autocomplete message action |
