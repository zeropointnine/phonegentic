# Slash-command menu in the agent panel

## Problem

The agent panel already supports a growing set of slash commands — `/note`,
`/w` / `/whisper`, `/ready`, `/trivia`, `/speakers`, `/score`, `/stttest` —
but they are entirely undiscoverable: you have to know they exist (and how
they are spelled) to use them. New users can't find the escape hatches, and
regulars still mistype `/whipser` and send it to the LLM as a plain
message.

There's also an asymmetry in how command output is rendered: `/note`
produces a full-width, decorated "sticky note" bubble (`_NoteBubble`) that
clearly reads as an annotation rather than a chat turn, while `/w`
whispers come out as a smaller right-anchored speech bubble. Visually the
whisper doesn't announce itself as "this was a different channel" nearly
as loudly, so in a long transcript it can look like a normal reply.

## Solution

Two UI additions:

1. **Slash-menu overlay** — typing `/` as the first character of the agent
   panel input opens a themed, in-panel overlay listing the available
   commands (inspired by Cursor's own "Skills" menu). As you type, matches
   filter live. Arrow keys move the highlight; Enter accepts; Escape
   dismisses. Clicking a row also accepts.

2. **Themed whisper panel** — `_WhisperBubble` is restyled to match
   `_NoteBubble`'s full-width annotation aesthetic: a left-accent bar in
   `AppColors.burntAmber` (the theme's whisper color — amber on VT-100,
   purple on Miami Vice), a header row with the
   `Icons.hearing_disabled_outlined` icon and `WHISPER` label, and the
   whispered body in a softer italic style. Whispers now visually parse as
   "agent-only context" at a glance, the same way notes parse as
   "annotation".

### Command catalog

A static `_kSlashCommands` list lives near the bottom of
`agent_panel.dart`. Each entry is a `_SlashCommand` with:

| Field          | Meaning                                                     |
|----------------|-------------------------------------------------------------|
| `trigger`      | Canonical slash form, e.g. `/note`                          |
| `label`        | Short title shown in the menu                               |
| `description`  | One-line explanation (matches Cursor's menu density)        |
| `icon`         | `IconData` for the leading glyph                            |
| `colorFn`      | Callback returning the theme-aware accent color for the row |
| `takesBody`    | `true` ⇒ selecting inserts `trigger<space>` and waits for the manager to type the body; `false` ⇒ selecting fills the input and fires send immediately |
| `aliases`      | Extra triggers (e.g. `/w` → `/whisper`)                     |

The catalog is deliberately centralised so adding a new command is a
one-entry change that surfaces both the runtime behaviour (via existing
`_send` / `_expandCommand` branches) and the discoverability in the menu.

### Filter semantics

The menu opens when the trimmed input:

* starts with `/`, and
* contains no whitespace (i.e. we're still typing the command, not the
  body — `/note follow up` hides the menu because you're in body-entry
  mode).

Matches are case-insensitive, prefix-based against `trigger` and
`aliases`. `/` alone shows the full catalog.

### Keyboard

`_InputBar._handleKeyEvent` gains a short-circuit: when the menu is open,
`ArrowUp` / `ArrowDown` move the highlighted index, `Enter` accepts the
highlighted command, and `Escape` dismisses the menu (without clearing
the input). Shift+Enter still passes through for multi-line input.
Normal Enter-to-send is preserved when the menu is closed.

### Selection behavior

* **`takesBody = true`** (`/note`, `/whisper`) — input is replaced with
  `trigger ` (with trailing space) and the caret is placed at the end.
  Focus stays in the input so the manager can keep typing the body.
* **`takesBody = false`** (`/ready`, `/trivia`, `/speakers`, `/score`,
  `/stttest`) — input is set to `trigger` and `_send` fires immediately,
  running through the existing `_expandCommand` path.

### Theming

All chrome uses existing `AppColors` tokens:

* `AppColors.card` — menu background
* `AppColors.surface` — header strip
* `AppColors.border` — 0.5px outer border
* `AppColors.accent.withValues(alpha: 0.10)` — highlighted-row tint
  (mirrors `HoverButton`'s hover tint for consistency)
* Per-row leading icon uses the command's own `colorFn()` so `/note`
  stays amber-orange, `/whisper` stays burnt-amber (purple in Miami),
  and action commands use `accent`.

No new color constants are introduced.

## Files

* `readmes/features/slash-command-menu.md` — this document.
* `phonegentic/lib/src/widgets/agent_panel.dart`:
  * add `_SlashCommand` + `_kSlashCommands` catalog;
  * add `_slashFilter`, `_slashIndex` state to `_AgentPanelState`, with a
    listener on `_controller` that updates them;
  * render `_SlashMenu` between the message list and `_InputBar` when
    the filter is active and matches are non-empty;
  * extend `_InputBar` with `slashMenuActive` + `onSlashArrow` /
    `onSlashSelect` / `onSlashEscape` callbacks and delegate arrow /
    enter / escape when the menu is open;
  * restyle `_WhisperBubble` to match the full-width `_NoteBubble`
    aesthetic (left accent bar, header with icon + `WHISPER` label,
    italic body) using `AppColors.burntAmber`.
