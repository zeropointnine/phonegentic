# Message Updates — reactions, replies, deletes (iOS paradigm)

## Problem

The messaging panel currently supports send / receive / soft-delete via a
long-press bottom-sheet but is missing the rich per-message affordances that
users expect from macOS Messages and iOS iMessage:

1. **Tap-back emoji reactions** with an iOS-style radial/row picker.
2. **Reply** with a threaded quote above the new bubble.
3. **Right-click (desktop) / long-press (mobile)** context menu with the
   focused bubble raised over a blurred background and an elastic pop-in
   animation.
4. **Multi-select delete** with round checkboxes and a "Delete n messages"
   confirm, just like iOS.
5. **Thread-level delete** via right-click on desktop or swipe-to-reveal on
   mobile, with confirmation.

The back-end reality shapes the contract: Telnyx's SMS/MMS API has **no native
reactions**, **no `reply_to` field**, and cannot delete messages that have
already been delivered (only scheduled-but-unsent ones). So reactions and
reply-links have to live as local metadata, delete is a local soft-delete
(surviving resync without resurrecting), and the wire fallback for the far
end follows Apple's plain-text tapback and quote conventions
(`Loved "…"`, `→ "…"\n\n<reply>`). When we receive those patterns back on
inbound, we parse them and render them as proper reactions/replies instead
of as standalone bubbles.

## Solution

### Data model (schema v22)

New columns on `sms_messages`:

- `reactions_json TEXT` — serialized map of `emoji → [{actor, at}]`.
- `reply_to_provider_id TEXT` / `reply_to_local_id INTEGER` — pointer to the
  quoted parent message (either / both depending on whether the parent has a
  provider-side id yet).

New `sms_thread_deletes(remote_phone TEXT PRIMARY KEY, deleted_at TEXT NOT
NULL)` — a sliding-window tombstone. Messages with `created_at <= deleted_at`
are hidden from the thread view and from the conversation aggregate, but
fresh inbound messages after the tombstone resurface the thread (matches
iOS). Telnyx backfill older than the tombstone stays hidden even after a
full resync.

All queries that power the UI (`getSmsMessagesForConversation`,
`getSmsConversations`, `getLastSmsForConversation`, `searchSmsMessages`,
`getUnreadSmsCount`) LEFT JOIN the tombstone table and filter
`created_at > COALESCE(deleted_at, '')`.

Resync safety: `_persistMessage` already short-circuits on an existing
`provider_id` and `insertSmsMessage` uses `ConflictAlgorithm.ignore` against
the unique `(provider_id, provider_type)` index, so local-only columns like
`reactions_json` and `reply_to_*` are never overwritten on a sync pass.

### Fallback text protocol (iOS-compatible)

`phonegentic/lib/src/messaging/reaction_reply_parser.dart` handles both
serialization (outbound) and parsing (inbound):

- **Tapbacks** — `❤️ → Loved`, `👍 → Liked`, `👎 → Disliked`,
  `😂 → Laughed at`, `‼️ → Emphasized`, `❓ → Questioned`, rendered as
  `Loved "original text"` on the wire; custom emoji use
  `<emoji> to "original text"`.
- **Replies** — outbound body prepends `→ "first ~80 chars of parent"\n\n`.
- On inbound, the parser tries to match the quoted target against the last
  ~50 messages in the thread (case-insensitive, trimmed) and, when it finds
  one, attaches the reaction or reply-link and suppresses rendering of the
  raw fallback string as its own bubble.

Self-echo dedupe: when we send a reaction fallback, the outbound row is
tagged `reflects_provider_id=<target>` inside its reactions metadata so it
doesn't render as a bubble on our side either.

### UI: context overlay

`phonegentic/lib/src/widgets/message_context_overlay.dart`:

- Captured via `RenderBox.localToGlobal` + `GlobalKey` on the source bubble;
  pushed with `Navigator.of(context).push(PageRouteBuilder(opaque: false))`
  so it doesn't steal gesture arena from the list below.
- Full-screen `BackdropFilter(ImageFilter.blur(sigmaX: 18, sigmaY: 18))` +
  a 0.25 black scrim.
- The focused bubble is cloned at its original rect and scaled from 0.6 → 1.0
  via `Curves.elasticOut` over 280ms. Dismiss is a linear 150ms fade.
- Reaction bar (6 tapbacks) floats just above the bubble; action menu
  (`Reply`, `Copy`, `Delete`, `Select more…`) floats below — or swaps sides
  if screen edges don't allow it.
- Critical: the barrier `GestureDetector` is a **sibling** of the bubble
  clone / reaction bar / menu, not a parent, and each selection uses
  `onTapUp` with `HitTestBehavior.opaque` — so emoji / menu taps fire before
  the barrier dismiss and never drop the selection.

### UI: bubble chrome

- Reaction chips overlay the bubble in a small row (28px circles,
  `AppColors.surface` fill, thin border) at the top-left (outbound) or
  top-right (inbound), offset with `Transform.translate(-8, -12)`.
- Reply-threaded bubbles render a small grey quote pill above the bubble
  with a thin accent bar; tapping scrolls the target into view and flashes
  a highlight (same pattern used by the note feature's scroll-to).
- `_MessageBubble` gesture routing uses `defaultTargetPlatform` (same as
  the dialpad) — `onSecondaryTapDown` on desktop, `onLongPress` on iOS /
  Android — to open the overlay.

### UI: multi-select delete

`_ConversationViewState._selectMode = true` flips each `_MessageBubble` into
showing a leading 22px round checkbox. The header shows `Cancel` and
`Delete (n)`; the latter opens a destructive confirm dialog and calls
`MessagingService.deleteMany(ids)`.

### UI: thread-level delete

In `messaging_panel.dart`, each conversation tile wraps:

- `onSecondaryTapDown` → `showMenu` with a red `Delete conversation` (desktop).
- A lightweight self-contained horizontal drag gesture that translates the
  tile up to -88px to reveal an inline red delete button (mobile). We avoid
  a new `flutter_slidable` dependency.

Both paths hit a destructive confirm dialog → `deleteThread(remotePhone)`.

## Files

- Modified: `phonegentic/lib/src/db/call_history_db.dart`,
  `phonegentic/lib/src/messaging/messaging_service.dart`,
  `phonegentic/lib/src/messaging/models/sms_message.dart`,
  `phonegentic/lib/src/widgets/conversation_view.dart`,
  `phonegentic/lib/src/widgets/messaging_panel.dart`
- New: `phonegentic/lib/src/widgets/message_context_overlay.dart`,
  `phonegentic/lib/src/messaging/reaction_reply_parser.dart`,
  `readmes/features/message-updates.md`

## Phase 2 — Agent panel reaction decoration

### Problem

When an inbound SMS is received while the agent panel is open, it renders as
a small inline `SmsThreadBubble`. Reactions applied to that message (e.g. the
caller "Loved" it) were persisted in the DB and shown as badges inside the
messaging panel, but the agent-panel bubble had no visual indication — the
reaction status of a message was inconsistent across the two surfaces.

### Solution

- Extend `ChatMessage.sms` with optional `smsProviderId` / `smsProviderType`
  metadata so the agent-panel bubble can look up the underlying `SmsMessage`
  row.
- Pass these from every `ChatMessage.sms` construction site in
  `agent_service.dart` (inbound handler + send/reply paths).
- `SmsThreadBubble` now subscribes to `MessagingService` via `addListener`
  and refetches the persisted row on notify. When the row has reactions, it
  renders a `_ReactionChipRow` clone positioned top-left (outbound) or
  top-right (inbound) of the speech bubble — matching the conversation-view
  placement, so the same decoration follows the message wherever it's shown.
- Lookup is cached in state; the bubble only repaints when the reaction map
  actually changes (compared via a lightweight signature string).

### Files

- Modified: `phonegentic/lib/src/models/chat_message.dart`,
  `phonegentic/lib/src/agent_service.dart`,
  `phonegentic/lib/src/widgets/sms_thread_bubble.dart`
