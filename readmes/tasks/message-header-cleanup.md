# Message Header Cleanup

## Problem

The Messages list panel and Conversation view panel headers are visually inconsistent with the Contacts and Call History panels. Differences include:

- Wrong padding (`fromLTRB(90, 18, 16, 10)` vs the standard `fromLTRB(16, 28, 8, 12)`)
- Missing `Container` decoration (no `AppColors.surface` background, no bottom border)
- Missing panel icon before the title
- Different text style (fontSize 18/w700 vs the standard 15/w600)
- Unstyled close button (bare icon instead of 30×30 decorated container)
- No `SafeArea` wrapping

## Solution

Update both `messaging_panel.dart` `_buildHeader` and `conversation_view.dart` `_buildConvoHeader` to match the pattern established by `contact_list_panel.dart` and `call_history_panel.dart`:

- Use `Container` with `AppColors.surface` background and bottom border
- Standard padding and text styling
- Styled 30×30 close button with card background
- Add `SafeArea` wrapping to the panel build methods
- Remove redundant `Divider` widgets below headers (the container border handles the separator)

## Files

- `phonegentic/lib/src/widgets/messaging_panel.dart` — Messages list header + panel wrapping
- `phonegentic/lib/src/widgets/conversation_view.dart` — Conversation header + panel wrapping
- `readmes/tasks/message-header-cleanup.md` — This file
