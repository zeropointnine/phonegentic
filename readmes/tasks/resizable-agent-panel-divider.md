# Resizable Agent Panel Divider

## Problem

The agent panel width was computed as a fixed proportion of the window width (`width * 0.38`, clamped 320–440px). Users had no way to resize the panel to give more or less space to the dialpad vs. the agent conversation.

## Solution

Added a draggable vertical divider between the left content area and the agent panel:

- **Drag to resize**: horizontal drag adjusts the panel width, clamped between 280px and 65% of the window.
- **Double-tap to reset**: restores the default proportional width.
- **Visual feedback**: thin 1px line at rest, expanding to 3px with accent color on hover/drag. 7px invisible hit-test area for easy grabbing. Cursor changes to `resizeColumn` on hover.
- **Stack-level positioning**: the divider is a `Positioned` child of the outermost `Stack`, placed as the last child so it renders on top of all overlay panels (Call History, Contacts, Calendar, Messaging, etc.). This ensures the divider is always reachable and the overlay panels resize along with the agent panel since they use the same `panelWidth` for their `right:` offset.

## Files

- `phonegentic/lib/src/dialpad.dart` — added `_agentPanelWidth` state, `_PanelDivider` widget positioned in the Stack, all overlay `right:` offsets driven by the same `panelWidth` variable.
