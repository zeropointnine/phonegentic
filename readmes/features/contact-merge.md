# Contact Import with Merge & Thumbnails

## Problem

The existing macOS contact import does a blind upsert keyed on `macos_contact_id`. Manually-created local contacts (which have no `macos_contact_id`) that share a phone number with a macOS contact produce duplicates. There's no way for users to review, merge, or resolve these conflicts. Additionally, contact photos from macOS are never imported — the `thumbnail_path` column exists in the schema but is never populated, so every contact shows a procedural identicon.

## Solution

### Phase 1: Contact thumbnails (complete)

- Import now requests `ContactProperty.photoThumbnail` from `flutter_contacts`.
- Thumbnail bytes are saved as JPG files to `~/Documents/phonegentic/contact_thumbnails/{macosContactId}.jpg`.
- The file path is stored in the `thumbnail_path` column via `upsertByMacosContactId`.
- `ContactIdenticon` widget gains an optional `thumbnailPath` parameter — when a file path is present, it renders the real photo in a circular clip instead of the identicon grid.
- All call sites with access to the contact map (contact list, contact card, dialpad preview, autocomplete overlay) now pass `thumbnail_path` through.
- Sites without the contact map (call history, callscreen, messaging) gracefully fall back to the identicon.

### Phase 2: Merge flow

Three-tier import categorization:
- **Linked** — local contact already has matching `macos_contact_id` → auto-update
- **New** — no local contact shares a normalized phone number → auto-import
- **Conflict** — local contact (without `macos_contact_id`) shares phone → queue for review

Inline review mode replaces the contact list when conflicts exist. Each conflict shows local vs macOS side-by-side with field-level merge. Resolution options: Use Local, Use macOS, Merge (field-pick), Keep Both.

## Files

### Phase 1 (thumbnails)
- `phonegentic/lib/src/contact_service.dart` — fetch `photoThumbnail`, save to disk, pass path to DB
- `phonegentic/lib/src/db/call_history_db.dart` — `upsertByMacosContactId` accepts `thumbnailPath`
- `phonegentic/lib/src/widgets/dialpad_contact_preview.dart` — `ContactIdenticon` shows real photo when available
- `phonegentic/lib/src/widgets/contact_list_panel.dart` — passes `thumbnail_path` to identicon
- `phonegentic/lib/src/widgets/contact_card.dart` — passes `thumbnail_path` to identicon
- `phonegentic/lib/src/widgets/dialpad_autocomplete_overlay.dart` — passes `thumbnail_path` to identicon

### Phase 2 (merge flow)
- `phonegentic/lib/src/contact_service.dart` — `ImportConflict` model, three-tier import, review mode state, resolution methods
- `phonegentic/lib/src/db/call_history_db.dart` — `linkMacosContactId()` method
- `phonegentic/lib/src/widgets/contact_list_panel.dart` — review mode branch with banner + conflict tiles
- `phonegentic/lib/src/widgets/contact_merge_card.dart` — new widget: field comparison + action buttons
