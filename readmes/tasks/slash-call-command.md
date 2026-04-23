# `/call` Slash Command

## Problem

The slash-command menu already exposed `/note`, `/whisper`, `/search`,
`/ready`, `/speakers`, `/trivia`, `/score`, and `/stttest`, but there
was no one-step way to place a call from the agent panel. The manager
either had to switch to the dialpad (context switch, loses their
place in the conversation) or ask the agent by voice (slow, relies on
STT round-trip).

Adding `/call` closes that gap: the manager types `/call Patrick` (or
`/call +14155551234`) and the panel dials immediately, keeping focus
in the same pane.

## Solution

A new `_SlashCommand` entry `/call <query>` sits in the slash-command
catalog next to `/search`, themed green (dial affordance) with a
`Icons.call_rounded` glyph. Selecting it in the menu inserts
`/call ` and keeps the caret in the input (like `/search`) so the
manager can type the contact name or number.

`_AgentPanelState._send` intercepts `/call <body>` and hands the body
to a new public method `AgentService.placeCallByInput(input)` which:

1. Trims the input and short-circuits when empty.
2. Checks `sipHelper != null` — if missing, posts a system bubble and
   bails. (Saves us from a needless `getUserMedia` call on a phone
   that can't dial.)
3. Detects whether the body is a phone number by counting digits
   (≥ 4 digits + matches `^[\d+\-\s().]+$`). If so, uses it as the
   number.
4. Otherwise calls `CallHistoryDb.searchContacts(query)` and picks
   the first match's `phone_number`. Zero matches → system bubble
   "No contacts found for <query>". Match-without-phone → system
   bubble "Contact X has no phone number on file."
5. Normalises to E.164 via `ensureE164`, grabs a local audio media
   stream, and invokes `sipHelper.call(e164, voiceOnly: true,
   mediaStream: stream)` — the same path every other caller
   (`conversation_view`, `call_history_panel`, `contact_list_panel`,
   `tear_sheet_service`) already uses. On success, posts
   `Dialing <Name> (<number>)…` as a system bubble (or a masked
   number when `demoModeService.enabled`).

Unlike the agent's `make_call` tool handler, `placeCallByInput` is
UI-facing and returns `void`, surfacing outcome via `ChatMessage.system`
bubbles instead of a string. The tool handler (`_handleMakeCall`)
stays unchanged.

### Menu UX

`/call` uses `takesBody: true`, matching `/search`. The description
shown in the `_SlashMenu` row is "Dial a contact name or phone
number."

## Files

- `phonegentic/lib/src/agent_service.dart` — new
  `placeCallByInput(String input)` method.
- `phonegentic/lib/src/widgets/agent_panel.dart` — new `/call` entry in
  `_kSlashCommands`; `_send` interception that calls
  `agent.placeCallByInput(body)`.
