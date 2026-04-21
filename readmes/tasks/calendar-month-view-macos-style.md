# Calendar Month View — macOS Style Refresh

## Problem

The current month view in `CalendarPanel` doesn't match macOS Calendar typesetting conventions. Differences include:

- Full day-of-week names instead of 3-letter abbreviations
- Day numbers centered at the top of cells instead of top-right
- Today highlight is a tinted background on the whole cell instead of a filled circle behind the number
- No days shown for adjacent months (empty cells before the 1st)
- No grid lines between cells
- Cells are nearly square instead of the wider/taller macOS proportions

## Solution

Restyle `_MonthView`, `_MonthDayCell`, and the day-label row to closely match macOS Calendar month view:

1. Abbreviate day labels to 3 letters (Sun, Mon, Tue, Wed, Thu, Fri, Sat)
2. Position day numbers at the top-right of each cell
3. Today indicator becomes a small filled circle behind the day number
4. Fill leading/trailing cells with grayed-out days from adjacent months
5. Add subtle border grid lines between cells
6. Adjust cell aspect ratio for wider, taller proportions

## Phase 2 — Search, legend toggles, day view, segmented control, typography

### Problem
- Search bar was below header instead of in it; only searched title/name/description
- No day view
- View toggle used separate chips instead of a macOS-style segmented control
- Day numbers in month view were too small (11px) and used a circle for today

### Solution
- **Search bar moved to header** — now sits inside the top bar, below the title row
- **Full-field search** — searches title, invitee name, email, description, location, and event type across *all* events (not just the current range). Results shown as an overlay list; tapping a result navigates to that event's date/view.
- **Day view** — new `_DayView` widget mirrors `_WeekView` layout but for a single day. Tapping a day in month view now opens day view.
- **Segmented control** — Day / Week / Month selector is now a macOS-style button bar with dividers, replacing the separate chip buttons.
- **Day number typography** — 22px, font-weight 300 (light), subtle secondary color. Today uses accent color + w600 weight but no circle. Adjacent-month days are very faint.
- **Cursor rule created** — `.cursor/rules/ui-reference-first.mdc` enforces reading reference implementations before adding new UI widgets.

## Files

- `phonegentic/lib/src/widgets/calendar_panel.dart` — `_CalendarPanelState`, `_DayView`, `_MonthView`, `_MonthDayCell`, segmented control
- `.cursor/rules/ui-reference-first.mdc` — new rule
