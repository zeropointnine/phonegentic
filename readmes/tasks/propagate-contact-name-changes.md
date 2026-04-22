# Propagate Contact Name Changes to Call History & Transcriptions

## Problem

When a user updates a contact's display name, the change only applied to the `contacts` table. Call history and transcript records stored stale snapshot data:

- **`call_records.remote_display_name`** — captured from SIP at call time, never updated
- **`call_records.contact_id`** — almost always NULL because `startCallRecord` never resolved the contact by phone
- **`call_transcripts.speaker_name`** — captured from `Speaker.label` at transcription time, never updated
- **`tear_sheet_items.contact_name`** — captured at creation time, never updated

The call history UI does a `LEFT JOIN contacts ON contact_id` to show the current name, but since `contact_id` was rarely set, it fell back to the stale `remote_display_name`.

## Solution

### Core: `CallHistoryDb.propagateContactName()`

A single method that, given a contact's ID, display name, and phone number:

1. **Links** unlinked `call_records` whose `remote_identity` matches the contact's phone (normalised last-10-digit comparison)
2. **Updates** `remote_display_name` on all linked `call_records`
3. **Updates** `speaker_name` on `call_transcripts` with `role = 'remote'` for those calls
4. **Updates** `contact_name` on `tear_sheet_items` matching by phone

### Call sites — every path that creates or renames a contact

| Path | Trigger |
|------|---------|
| `ContactService.updateField` | User edits name or phone in the contact card |
| `ContactService.quickAdd` | New contact created via quick-add |
| `ContactService.importFromMacOS` | Tier 1 (linked update) and Tier 2 (new import) |
| `ContactService.resolveUseMacOS` | Merge conflict resolved by choosing macOS data |
| `ContactService.resolveMerge` | Merge conflict resolved with per-field merge |
| `AgentService._handleSaveContact` | Agent tool creates or updates a contact |

### Bonus: link `contact_id` at call start

`CallHistoryService.startCallRecord` now resolves the contact by phone before inserting, so new call records are linked from the start and use the contact's display name.

### Bonus: `searchAndFormat` fix

`CallHistoryService.searchAndFormat` now prefers `contact_name` (from the JOIN) over `remote_display_name`, matching the UI's precedence order.

### Bug fix: agent overwrites manager contact name

`_handleSaveContact` had no guardrail preventing the agent from overwriting the manager's own contact. If the agent called `save_contact` with a phone number that matched the manager's phone, it would blindly replace `display_name` (e.g. "Patrick" → "Tess"). Added an early-return guard that checks the phone against `_agentManagerConfig.phoneNumber` and refuses to modify the manager's contact.

## Files

| File | Change |
|------|--------|
| `lib/src/db/call_history_db.dart` | Added `propagateContactName()` method |
| `lib/src/contact_service.dart` | Call propagation from `updateField`, `quickAdd`, `importFromMacOS`, `resolveUseMacOS`, `resolveMerge` |
| `lib/src/call_history_service.dart` | Link `contact_id` at `startCallRecord`; fix `searchAndFormat` name precedence |
| `lib/src/agent_service.dart` | Call propagation from `_handleSaveContact` (both update and insert paths); manager contact guard |
