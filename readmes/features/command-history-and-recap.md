# Command history + `/recap` skill

## Problem

Two papercuts in the agent panel input:

1. **No command recall.** Re-issuing a command you just ran (like
   `/search Patrick` with a typo fix, or `/call +14155551234` after a
   missed connection) requires retyping the whole thing. Every other
   command-line tool — bash, the browser URL bar, the dialpad — lets
   you arrow-up through recent entries. The agent panel should too.

2. **No one-gesture "catch me up" command.** `/search <name>` works
   for contact-scoped recaps, but when the manager wants the _general_
   picture ("what's happened lately — any calls, messages, notes,
   reminders?") there's no single trigger. Asking the agent by voice
   or plain text burns an LLM round-trip on tool-routing the agent
   has to do right.

## Solution

### 1. Command history navigation

`_AgentPanelState` keeps a deduped list of the last 50 inputs the
manager sent. Every `Enter`-submitted string (slash command or plain
message) is pushed to the tail; pushing an entry that already exists
moves it to the tail instead of creating a duplicate, so the history
doesn't fill up with reruns of the same command.

The list is persisted to `SharedPreferences` under
`agent_command_history` (JSON-encoded list of strings) so it
survives restarts.

#### Key bindings

Wired in `_InputBarState._handleKeyEvent`. The slash-menu path takes
priority — history navigation only engages when the menu isn't open.

| Key         | When it fires                                    | Effect |
|-------------|--------------------------------------------------|--------|
| `ArrowUp`   | Input empty OR already navigating history       | Move one step older (toward the start of the list). Saves the current draft on first step. |
| `ArrowDown` | Already navigating history                       | Move one step newer. Falling off the tail restores the saved draft. |
| `Escape`    | Already navigating history                       | Restore the saved draft. |
| `Enter`     | (unchanged — always sends the current text)     | Sending an entry pushes it to history. |
| (type)      | Cancels history navigation                       | The input reverts to a free-form draft — further arrow keys do normal caret movement. |

The "input empty" gate is deliberate: the `TextField` is
`maxLines: 5`, so `ArrowUp` has a natural caret-up use. Forcing it
to always grab history would make multi-line composition painful.
Once the input is empty the arrow key has nothing else to do, so we
claim it.

### 2. `/recap` slash command

A new `_SlashCommand` entry with `takesBody: false`:

```dart
_SlashCommand(
  trigger: '/recap',
  label: 'Recap',
  description: 'Brief agent on recent calls, messages, notes, '
      'and reminders.',
  icon: Icons.history_rounded,
  colorFn: () => AppColors.accent,
),
```

Selecting it from the menu fires `_send` immediately (no body), which
intercepts `/recap` and calls `AgentService.startRecap()`.

`startRecap()` runs four parallel queries:

1. `CallHistoryDb.getRecentCalls(limit: 5)` — last 5 calls across
   every contact.
2. `CallHistoryDb.getSmsMessages(limit: 10)` — last 10 SMS lines
   (inbound + outbound, so the agent can tell which side is waiting
   on a reply).
3. `CallHistoryDb.getRecentNotes(limit: 5)` — last 5 `/note` rows.
4. `CallHistoryDb.getUpcomingReminders(limit: 5)` — pending reminders
   due within the next 24h, plus any already overdue.

The results are folded into a single directive that's pushed through
`announceToManager(...)` so the agent speaks a warm spoken recap
(2–4 sentences) when unmuted. A small system bubble — `Recap
dispatched — agent will brief you aloud.` — also lands in the chat
so the action has a visible receipt even when TTS is off.

## Files

- `phonegentic/lib/src/widgets/agent_panel.dart` — `_cmdHistory`,
  `_historyIdx`, `_historyDraft`, `_pushHistory`, `_historyArrow`,
  `_historyEscape` in `_AgentPanelState`; extended `_InputBar` props
  with history callbacks; `_InputBarState._handleKeyEvent` now
  delegates arrow-up / arrow-down / escape to the history handlers
  when applicable. Added `/recap` entry to `_kSlashCommands`.
- `phonegentic/lib/src/agent_service.dart` — `startRecap()` method.
- `phonegentic/lib/src/db/call_history_db.dart` — added
  `getRecentNotes(limit)` and `getUpcomingReminders(limit)` queries.
