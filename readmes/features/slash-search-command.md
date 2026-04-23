# `/search` command — one-shot contact recap

## Problem

Pulling together "everything about Patrick" currently requires three separate
LLM round-trips that the manager has to prompt for:

1. "Show me recent calls with Patrick" → triggers `search_calls`.
2. "Any texts from Patrick?" → triggers `search_messages`.
3. "When do I have calendar time with him?" → triggers `read_google_calendar`.

Each is an English ask to the agent. The agent has to pick the right tool,
the tool has to correctly resolve the name, and the manager has to wait
three times. There's no way to just say "recap this person" as a single
gesture, and nothing surfaces in the UI as a first-class contact-scoped
view.

## Solution

A new `/search` slash command that opens an inline **search guide bubble**
in the agent panel — a small decorated panel with:

- a search icon header,
- one or more matching contacts (tappable chips when there are multiple
  name matches),
- a row of check-toggle chips for **Calls**, **Messages**, and **Calendar**
  (all selected by default), and
- a **Search** button that fires all three lookups in parallel and brings
  the agent up to speed with a single consolidated system event.

Typing `/search patrick` and hitting Enter creates the bubble; toggling
chips and tapping Search runs the recap. No LLM round-trips are burned on
tool routing — the panel itself gathers the data and hands the agent a
ready-made brief.

### UX flow

```
user types: /search patrick
           ↓
panel shows: [🔍 SEARCH · patrick · 14:22   ×]
             [ patrick (415-555-1212) ]              ← if >1 match, chips
             [✓ Calls] [✓ Messages] [✓ Calendar]
             [           Search            ]
           ↓ tap Search
panel shows: [🔍 SEARCH · patrick · done   ×]
             3 calls · 12 messages · 2 upcoming events
           +
agent (system event): "[SEARCH RECAP] For Patrick (415-555-1212)…"
```

The bubble's running / done state lives inline so the manager sees that
the search completed even if the agent is mid-speech about something
else.

### Contact selection

The match list comes from `CallHistoryDb.searchContactsByRecency(query)`
— a recency-ordered variant of `searchContacts` that LEFT-JOINs
`call_records` on contact id or phone number and orders by
`MAX(started_at) DESC` with never-called contacts last (alphabetical
among themselves). The top 8 matches render as selectable chips; every
chip is selected by default so the common case ("recap everyone named
Jon") just works. If there are zero matches, the bubble never renders
— a single system message `No contacts found for "patrick".` is posted
instead so the manager gets immediate feedback.

The chip row is a horizontal `ListView` wrapped in a `ShaderMask`
(`BlendMode.dstIn`) with a linear-gradient shader that fades the
left / right edges when there's scrollable content on that side.
State is driven by a `ScrollController` listener, so the fade only
appears when it's actually informative: a short row (2–3 chips) has
no fade; a long row (8 chips) shows the right-edge fade from the
start and picks up a left-edge fade once the manager scrolls into
the overflow. The mask also guarantees the last chip never draws
past the bubble's rounded corner, which it did before.

### Option toggles

Three check-chips, rendered with the same `HoverButton`-style tint as
the rest of the panel chrome:

| Chip        | Data source                                     |
|-------------|-------------------------------------------------|
| Calls       | `CallHistoryDb.searchCalls(contactName: …)`     |
| Messages    | `CallHistoryDb.getSmsMessagesForConversation(remotePhone)` |
| Calendar    | `GoogleCalendarService.readEvents(<date>)` × today + tomorrow, filtered by contact name substring match in title/description |

All are toggled on by default (matching the user's spec). Tapping a chip
updates the bubble's metadata in place.

### Running the search

`AgentService.executeSearchGuide(message)` pulls the selected contact +
toggles from metadata, runs the checked queries in parallel, formats a
compact summary (no raw rows — just counts + most-recent highlights),
and:

1. Replaces the bubble's metadata with `stage: 'done'` + a result
   summary string so the bubble transitions to its finished visual.
2. Calls `sendSystemEvent(summary, requireResponse: true)` so the agent
   speaks the recap — exactly the same mechanism used by the startup
   reconciliation feature.

The raw counts also populate the bubble's "done" footer so the manager
can confirm at a glance ("3 calls · 12 messages · 2 events") before the
agent even finishes speaking.

### Calendar scope

Google Calendar `readEvents` takes a single date, so we read today +
tomorrow and filter events whose title or description substring-matches
the contact's name. This keeps the scope tight without a full search
API. If Google Calendar is not enabled, the Calendar chip stays
interactive but the eventual summary line is `Calendar: not enabled.`

## Phase 2 — multi-select contacts, inline result list, reminders treatment

After the initial rollout the bubble was functional but shallow: only one
contact could be selected, and after **Search** fired the only visible
output was a counts line ("3 calls · 12 messages · 2 events"). The
manager still had to wait for the agent to narrate the recap before they
could see what actually matched, and there was no way to pivot a search
across a family of related contact rows (e.g. the same person stored
three ways). Phase 2 addresses both, plus gives upcoming reminders a
treatment that reads as a first-class panel instead of a thin status bar.

### Multi-select contacts

`metadata.selected_indices: List<int>` replaces the single
`selected_index`. `startContactSearch` pre-selects **all** matching
contacts. Each `_SearchContactChip` shows a check glyph on the
selected contacts and toggles on tap via
`AgentService.toggleSearchContact(msg, i)`. The **Search** button is
only enabled when at least one contact is selected.

When the search runs, every selected contact contributes:

* its **name** to the calls and calendar filters (union — we run each
  contact's calls/calendar query and merge),
* its **phone** to the messages query (per-phone thread fetch),
* its **id** + **phone** to the notes query.

Results are deduped (by `call_records.id`, `sms_messages.id`,
`call_transcripts.id`, `GCalEventInfo` identity) so overlapping contacts
(e.g. "Patrick" stored three times) don't inflate the output.

### Fourth toggle: Notes

A **Notes** toggle joins `call_transcripts` → `call_records` with
`role = 'note'` and filters by the selected contacts'
`contact_id` / `remote_identity`. Each note renders with its own chip
in the results list carrying the note text plus a small footer
descriptor ("from call with Patrick · 3d ago") and a deep-link to the
originating call via `CallHistoryService.focusCall`.

All four toggles (Calls / Messages / Calendar / Notes) stay selected
by default.

### Inline result list

After `stage == 'done'`, the bubble replaces the prior "counts footer"
with a vertical stack of themed sections — one per toggle that
returned rows. Each section has a small header (icon + label + count)
and up to 5 rows rendered by dedicated mini widgets:

| Row widget                  | Renders                                         |
|-----------------------------|-------------------------------------------------|
| `_SearchResultCallRow`      | Call direction glyph, contact name, duration/status, relative time. A small tape-reel SVG (same asset as the call history panel, tinted in `AppColors.accent`) appears inline next to the name when `recording_path` is non-empty. Tap → `CallHistoryService.focusCall(callId)` |
| `_SearchResultMessageRow`   | Inbound/outbound glyph, body preview, relative time. Tap → `MessagingService.openToConversation(remotePhone)` which sets both `_isOpen = true` and the selected thread in one `notifyListeners`, so the messaging panel opens straight into the conversation without flashing the list. |
| `_SearchResultNoteRow`      | Sticky-note icon, note text, "from call with Patrick · 3d ago" footer. Tap → `CallHistoryService.focusCall(callId, transcriptId: …)` |
| `_SearchResultCalendarRow`  | Calendar glyph, today/tomorrow label + start time, event title. Trailing `open_in_new` glyph indicates the row is externally actionable; tap → `AgentService.openUrlInBrowser('https://calendar.google.com/calendar/u/0/r/day/YYYY/M/D')` using the raw `date` stashed on the row. |

When a section has more rows than fit, a muted "… and N more" line
sits at the bottom of that section so the manager knows the view is
truncated.

The raw row maps are cached in the bubble's `metadata` (`call_rows`,
`message_rows`, `note_rows`, `calendar_rows`) so the rendered list
survives the widget rebuilding without re-running any queries.

### Silent system dispatch

The raw `[SEARCH RECAP] …` brief with `## Calls`, `## Messages`,
etc. sections is only meant for the LLM — the manager has the exact
same data rendered inline in the search-guide bubble's result list.
We echoed it into the chat as a system bubble early on and it
produced duplicate content the user would have to scroll past.

`sendSystemEvent` now accepts a `silent: true` flag that suppresses
the chat echo while still dispatching the text to the whisper +
text-agent pipelines. `executeSearchGuide` passes `silent: true` so
the agent still reacts to the recap (and narrates its take) but the
briefing text itself stays out of the visible transcript.

### Agent recap styling

The agent's text reply to a `/search` run still uses `**Calls:**`,
`**Messages:**`, `**Calendar:**`, `**Notes:**` as section markers.
`StreamingTypingText` (the widget that reveals agent replies
character-by-character inside `_AgentBubble`) was upgraded from a flat
`Text(...)` to a `Text.rich(...)` that:

* parses any `**…**` run as bold,
* recognises the four section labels above (case-insensitive, colon
  optional) and replaces them with a leading `Icon(…)` tinted in
  `AppColors.accent` followed by the label in bold accent colour,
* strips any unterminated trailing `**` mid-stream so the typewriter
  reveal never flashes raw asterisks — once the closing `**` lands on
  the next tick, the pair renders properly.

Section-label icons match the search-guide bubble's chip icons so the
visual language stays consistent across the card and the narration.

### Slick reminder banner

The pre-Phase-2 `_UpcomingReminderBanner` was a 36px-tall single-row
banner with an icon + countdown + title. It read as "chrome" rather
than an actionable heads-up.

The redesigned banner is a themed panel (matching the `_NoteBubble` /
`_SearchGuideBubble` aesthetic) with:

* a left **accent bar** in `AppColors.orange` that pulses faintly when
  the reminder is < 2 minutes out,
* a bold countdown in the panel's primary slot using the timer font,
* the reminder **title** on its own line so long titles don't get
  ellipsed against the countdown,
* a thin **progress bar** underneath that fills as the remind-at
  approaches (based on `created_at` → `remind_at` span, clamped),
* a `+N more` chip in the header when multiple reminders are
  upcoming — tapping it is a no-op today but the chip is exposed so a
  future "show all" affordance has a natural landing spot,
* a hover-revealed **Dismiss** affordance that calls
  `CallHistoryDb.updateReminderStatus(id, 'dismissed')` and refreshes
  the presence cache via `managerPresenceService.onReminderCreatedOrChanged()`.

The banner still collapses to `SizedBox.shrink()` when there are no
upcoming reminders, so it doesn't take vertical space idly.

## Files

- `readmes/features/slash-search-command.md` — this document.
- `phonegentic/lib/src/models/chat_message.dart` — add
  `MessageType.searchGuide` + `ChatMessage.searchGuide(...)` factory
  that carries the contacts list, multi-select state, toggle state,
  and (after run) structured result rows in `metadata`.
- `phonegentic/lib/src/agent_service.dart` —
  * `startContactSearch(query)`, `toggleSearchContact(msg, i)`,
    `toggleSearchOption(msg, key)`, `executeSearchGuide(msg)`,
    `dismissSearchGuide(msg)`.
  * Per-section helpers (`_searchGuideCalls`, `_searchGuideMessages`,
    `_searchGuideCalendar`, `_searchGuideNotes`) that each return
    formatted body text **and** structured row lists for the UI.
  * Cross-contact merge + dedupe so overlapping contacts don't inflate
    the output.
- `phonegentic/lib/src/db/call_history_db.dart` — add
  `getNotesForContacts({contactIds, phones})` which joins
  `call_transcripts` → `call_records` on `role = 'note'` and filters
  by either contact id or remote identity.
- `phonegentic/lib/src/widgets/agent_panel.dart` —
  * add `/search` to `_kSlashCommands`;
  * intercept `/search <name>` in `_send` and call
    `AgentService.startContactSearch`;
  * `_SearchGuideBubble` with multi-select contact chips (check glyphs),
    four option chips (`Calls` / `Messages` / `Calendar` / `Notes`),
    an action button that transitions from `Search` → spinner →
    inline result list;
  * mini row widgets `_SearchResultCallRow`, `_SearchResultMessageRow`,
    `_SearchResultNoteRow`, `_SearchResultCalendarRow`, each tap-able
    for deep-linking into the relevant panel;
  * redesigned `_UpcomingReminderBanner` — left-accent panel with
    pulsing bar when imminent, countdown + title stack, progress bar,
    hover-revealed dismiss.
