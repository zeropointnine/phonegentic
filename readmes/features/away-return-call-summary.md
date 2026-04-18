# Away-Return Call Summary Banner

## Problem

When the manager steps away from the computer for more than 5 minutes, calls may come in and be handled by the agent. When the manager returns, they have no quick visual overview of what happened while they were gone — the existing flow just injects a text briefing into the chat stream, which can scroll away or be missed.

We need a prominent, structured call summary banner that appears in the agent panel when the manager returns after 5+ minutes away, showing each call that came in with direction, caller identity, duration, and time.

## Solution

Extend `ManagerPresenceService` to store structured call data (not just a text summary) on return. Add a new `_AwayCallSummaryBanner` widget in the agent panel that watches the presence service and renders a dismissible summary card showing individual call rows.

**Key design decisions:**
- The banner sits between the calendar event banner and the tear sheet bar for visibility
- Structured call list with per-call rows: direction icon, caller name/number, duration, time
- Dismiss button clears the summary; it also auto-clears when a new call starts
- Complements (not replaces) the existing text briefing sent to the agent

## Files

- `phonegentic/lib/src/manager_presence_service.dart` — add `_awayCallRecords`, `awayCallRecords` getter, `dismissAwayCallSummary()`, populate on return
- `phonegentic/lib/src/widgets/agent_panel.dart` — add `_AwayCallSummaryBanner` widget, wire into column layout
