# Consistent panel headers with inline search

## Problem

The Messages, Call History, and Contacts panels each had a separate header row and search bar row, wasting vertical space. The headers were also visually inconsistent (different padding, different layout patterns).

## Solution

Unified all three panel headers into a single-row pattern:

**`[icon] [label] [search field (expanded)] [action buttons] [close]`**

- Padding: `fromLTRB(12, 28, 8, 10)` across all panels
- Search field: height 34, `borderRadius(8)`, card bg, `AppColors.border` at 0.4 alpha, "Search..." hint
- Label uses fontSize 15, w600, -0.3 letterSpacing
- Action buttons use 30×30 containers with `borderRadius(8)`
- Conversation view header also aligned to match (Expanded name column, no Spacer)
- Contacts panel conditionally hides the search field when viewing a contact detail (falls back to label + Spacer)

## Files

- `phonegentic/lib/src/widgets/messaging_panel.dart` — merged search bar into header, added "Messages" label
- `phonegentic/lib/src/widgets/call_history_panel.dart` — merged search bar into header, kept Tear Sheet button and loading spinner
- `phonegentic/lib/src/widgets/contact_list_panel.dart` — merged search bar into header, conditionally hidden on detail view
- `phonegentic/lib/src/widgets/conversation_view.dart` — aligned header padding and layout
