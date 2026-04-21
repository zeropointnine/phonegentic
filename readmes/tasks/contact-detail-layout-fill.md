# Contact Detail Screen Layout Fix

## Problem

The contact detail card was floating in the panel — it sized to its content height, leaving a visible gap of dark background (`AppColors.bg`) below the fields. The identicon/header was also too close to the top of the panel with only 24px of spacing.

## Solution

Two changes to make the contact detail fill the panel and position the header lower:

1. **`contact_list_panel.dart` — `_buildContactDetail`**: Wrapped in `LayoutBuilder` + `ConstrainedBox(minHeight: constraints.maxHeight)` + `Container(color: AppColors.surface)` so the surface background extends to fill the entire available area, eliminating the dark gap. Top padding is calculated as 18% of available height (clamped 24–120px) and passed to the card.

2. **`contact_card.dart` — `ContactCard`**: Added `topPadding` parameter (default 24) to replace the fixed spacer. Removed the root `Container(color: AppColors.surface)` since the parent now provides the background. Increased spacing between action buttons and fields card from 20px to 32px.

## Files

- `phonegentic/lib/src/widgets/contact_list_panel.dart` — `_buildContactDetail` layout wrapper
- `phonegentic/lib/src/widgets/contact_card.dart` — `topPadding` parameter, removed background, increased spacing
