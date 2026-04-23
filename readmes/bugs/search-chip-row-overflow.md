# `/search` contact chip row: overflow + recency ordering

## Problem

When `/search jon` matched several contacts, the chip row in the
search-guide bubble had two issues:

1. **Visual overflow** — the last chip rendered past the bubble's
   rounded right edge (see screenshot with `Jor…` half-drawn outside
   the bubble). The row was a plain horizontal `ListView` inside a
   `SizedBox(height: 26)`, but without any visual hint that more
   content was scrollable. It looked like broken layout rather than
   an overflowing list.
2. **No recency ordering** — `CallHistoryDb.searchContacts` orders
   by `display_name ASC`, so typing a common first name like "Jon"
   put the alphabetical-first contact at position 0, even if the
   manager had just spoken to a different Jon an hour ago.
   Manager almost always wants the most recently contacted person.

## Solution

### Recency ordering: `searchContactsByRecency(query)`

New DB query that LEFT-JOINs `call_records` on contact id *or* phone
number (SIP `remote_identity` sometimes bypasses `contact_id`),
groups by contact, and orders by `MAX(started_at) DESC` with
never-called contacts pushed to the bottom (alphabetical within).

```sql
SELECT c.*, MAX(cr.started_at) AS last_call_at
FROM contacts c
LEFT JOIN call_records cr
  ON cr.contact_id = c.id
  OR cr.remote_identity = c.phone_number
WHERE c.display_name LIKE ? OR c.phone_number LIKE ? OR c.email LIKE ?
GROUP BY c.id
ORDER BY CASE WHEN last_call_at IS NULL THEN 1 ELSE 0 END,
         last_call_at DESC,
         c.display_name ASC
```

`AgentService.startContactSearch` now calls this new variant and
carries `last_call_at` through the bubble metadata. Match limit
bumped from 5 → 8 since the new chip row handles overflow gracefully.

### Overflow fade: `_SearchContactChipRow`

The inline `SizedBox(height: 26) + ListView.separated` was replaced
with a stateful `_SearchContactChipRow` that wraps the list in a
`ShaderMask(blendMode: BlendMode.dstIn, …)`. The mask's linear
gradient is driven by a `ScrollController` listener:

- **No scroll needed** (short row): mask is opaque everywhere —
  visually identical to the old row for small contact sets.
- **Can scroll right** (fresh long row): right 18px fade to
  transparent. The last chip dissolves into the bubble edge instead
  of clipping mid-word.
- **Can scroll left** (user has scrolled past the start): left
  18px fade to transparent in addition.
- **Both edges** (mid-scroll long row): faded on both sides, same
  feel as iOS horizontal tab bars.

Why `ShaderMask` rather than a gradient `Container` overlay: the
mask multiplies the child's alpha, so fades render over whatever
the chip background happens to be (selected / unselected tints,
hover states, accent borders) without fighting the theme. A
gradient overlay would need a solid match to the bubble's
background, which doesn't work for translucent cards.

### Sizing details

- `ListView` has `padding: EdgeInsets.only(right: 8)` so the
  last chip never slams against the fade region.
- `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics)` so
  the row is always draggable, even when everything fits (gives
  the manager a quick way to verify "this is all of them" by
  pulling horizontally).
- `clipBehavior: Clip.hardEdge` on the inner `ListView` so the
  fade region stays crisp — without it the fade is ambiguous
  because chips can bleed past the ListView's painted region.

## Files

- `phonegentic/lib/src/db/call_history_db.dart` — new
  `searchContactsByRecency(query)` query.
- `phonegentic/lib/src/agent_service.dart` — `startContactSearch`
  uses the recency query, bumps match limit to 8, stashes
  `last_call_at` in the chip metadata.
- `phonegentic/lib/src/widgets/agent_panel.dart` — new
  `_SearchContactChipRow` widget replaces the inline `SizedBox +
  ListView`; `ShaderMask`-driven edge fade.
- `readmes/features/slash-search-command.md` — contact-selection
  section updated to describe recency ordering and the fade mask.
