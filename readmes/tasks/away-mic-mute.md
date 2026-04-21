# Away Mic Mute

## Problem

When the manager goes away (either manually or via the 5-minute inactivity timer), the microphone stays in its current state. This means the agent continues listening to ambient noise, processing transcripts, and potentially burning STT/LLM resources while nobody is at the desk.

## Solution

Save the current mute state when transitioning to away, force-mute the microphone, and restore the original state when the manager returns.

**AgentService** gains two new methods and two bookkeeping fields:

- `_awayMuteSaved` / `_mutedBeforeAway` — track whether a save is pending and what the original mute state was.
- `muteForAway()` — records `_muted` into `_mutedBeforeAway`, then force-mutes if not already muted.
- `restoreFromAway()` — if the mic was unmuted before away, unmutes it; if it was muted, leaves it muted (no-op).

Both fields are cleared on `reconnect()` to prevent stale state across sessions.

**ManagerPresenceService** calls these at all four transition points:

| Transition | Method called |
|---|---|
| `setManuallyAway()` | `muteForAway()` |
| Auto-away timer fires (`_onFocusLost` timer) | `muteForAway()` |
| `clearManuallyAway()` | `restoreFromAway()` |
| `_onFocusGained()` (auto-return) | `restoreFromAway()` |

## Files

- `phonegentic/lib/src/agent_service.dart` — added `_awayMuteSaved`, `_mutedBeforeAway`, `muteForAway()`, `restoreFromAway()`; reset flag in `reconnect()`
- `phonegentic/lib/src/manager_presence_service.dart` — call `muteForAway()` / `restoreFromAway()` on away transitions
