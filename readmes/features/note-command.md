# /note command — private notes in the agent panel

## Problem

During a call (or between calls) the manager often wants to jot down a short
note — "follow up Tuesday", "angry about invoice #44", "check tech bench for
serial" — without:

1. having the agent interpret it as a request and respond,
2. leaking the content over TTS to the remote party, or
3. losing the thought (paper notes / external apps are out-of-band).

There is no existing mechanism: anything typed in the agent panel is either a
message to the AI (`sendUserMessage`), a whisper routed into the AI's ear
(`sendWhisperMessage`), or a slash-macro that expands to a real prompt.

## Solution

Add a new `/note` slash command and a new `MessageType.note` that is treated
as a **UI-only, read-only marker** — persisted to `session_messages` and (when
a call is active) to `call_transcripts` so it shows up in the call-history
detail view, but **never** sent to the LLM, never whispered, never spoken.

### Entering a note

Type any of these at the **start** of a line in the agent-panel input:

```
/note follow up Tuesday about the Peterson case
/note check tech bench for serial 44821
/note
```

- `/note <body>` — records the body as a note.
- `/note` alone on a line — ignored (empty note).

The input is cleared, the note is added to the transcript, and the agent
panel scrolls to show it. Nothing is sent to the AI; the agent does not
"see" the note in its live context.

### UI

A new `_NoteBubble` renders notes with a slick sticky-note aesthetic:

- Full-width row (not left/right-anchored like chat bubbles) so notes read
  as first-class annotations rather than "someone said this".
- A warm amber/yellow tinted surface with a 2px left accent bar.
- Header row: `Icons.sticky_note_2_outlined` + `NOTE` label + timestamp.
- Body text in a softer, slightly italicised style to distinguish it from
  transcript content.
- Themed via `AppColors.orange` / `AppColors.burntAmber` so it harmonises
  with the amber-VT100 and Miami Vice themes.

### Call history

`_TranscriptLine` in the call-history detail view now recognises role
`'note'` — rendering the row with the note icon, an `NOTE` chip, and the
same warm tint so a reviewer sees it as context rather than spoken content.

### Inline "pending attachment" flow (no active call)

When `/note` is entered with **no active call**, the note is staged as a
pending annotation inline in the agent panel — right where the manager is
already looking — and offers them a one-tap attachment to a recent call:

- `AgentService.addNote(...)` detects `callHistory.activeCallRecordId == null`
  and fetches the 3 most recent completed calls as lightweight candidate
  summaries (`{id, name, phone, started_at, direction, duration_seconds,
  status}`), which are embedded in the message's `metadata.candidates`
  array along with `metadata.pending_attachment: true`.
- `_MessageBubble` dispatches those messages to a new `_PendingNoteBubble`
  widget that renders:
  - the note text with a sticky-note header and a `NEW NOTE` chip,
  - a small `Attach to a recent call?` divider,
  - one tappable row per candidate (contact avatar-style icon with the
    direction/missed indicator, contact name, relative time, duration,
    link icon on the right),
  - a `Keep as session note` button,
  - and a discrete `×` discard button in the header.
- Tapping a candidate calls `agent.attachNoteToCall(message, callId, label)`
  which writes a `call_transcripts` row (so the note appears in that call's
  history detail view) and replaces the message's metadata with
  `{attached_call_id, attached_call_name}`. The bubble transitions in place
  to the finalized `_NoteBubble` variant with an `Attached to <name>`
  footer.
- Tapping `Keep as session note` calls `agent.confirmNoteAsSession(message)`
  which clears all metadata, leaving a plain session note.
- Tapping `×` removes the note entirely (never persisted as a real note).
- If there are zero recent calls in history, the pending UI is skipped and
  the note is finalized immediately as a session note.

Persistence of the transition is done via a new
`CallHistoryDb.updateSessionMessageMetadata(messageId, metadata)` helper so
the same row is updated in place (preserving ordering and `message_id`
stability for the Flutter `ValueKey`).

## Files

- `phonegentic/lib/src/models/chat_message.dart` — add `MessageType.note` and
  `ChatMessage.note(...)` factory
- `phonegentic/lib/src/agent_service.dart` — add `addNote(String)` that
  attaches to the active call, or stages a pending note with 3 recent-call
  candidates when idle; `attachNoteToCall(...)`, `confirmNoteAsSession(...)`
  and `_loadNoteCandidateCalls()` helpers; handle role `'note'` in
  `_loadPreviousConversation`
- `phonegentic/lib/src/db/call_history_db.dart` — add
  `updateSessionMessageMetadata(messageId, metadata)` so the pending → final
  transition updates the same row in place
- `phonegentic/lib/src/widgets/agent_panel.dart` — intercept `/note` in
  `_send`; add `_NoteBubble` (with optional `Attached to <name>` footer),
  `_PendingNoteBubble`, `_NoteCandidateRow`, `_NoteCandidateDivider`; wire
  `MessageType.note` + the `pending_attachment` metadata flag into
  `_MessageBubble.build`
- `phonegentic/lib/src/widgets/call_history_panel.dart` — handle role
  `'note'` in `_TranscriptLine` with icon + warm tint
- `phonegentic/lib/src/transcript_exporter.dart` — label notes so exported
  transcripts include them as `[NOTE] …`
