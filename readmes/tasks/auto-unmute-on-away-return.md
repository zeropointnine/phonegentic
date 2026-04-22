# Auto-unmute call mic on return from away

## Problem

When the user goes away during a call, the app currently mutes the *agent* (AI listening) but does not mute the SIP call microphone (`_softMute`). We want the call mic to be muted while the user is away so the caller doesn't hear ambient noise, and then auto-unmuted when the user returns — **unless** the user had manually muted the mic before going away, in which case we honour their choice and leave it muted.

## Solution

Listen to `ManagerPresenceService.isAway` in the call screen. On transition to away, save the current `_softMute` state and force-mute. On transition back, only unmute if the mic wasn't manually muted before away began.

## Files

- `phonegentic/lib/src/callscreen.dart` — added away-aware soft-mute logic with `ManagerPresenceService` listener
