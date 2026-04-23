# Reset Voiceprints

## Problem

User wants to start fresh with speaker identification. The `speaker_embeddings` table in `call_history.db` has accumulated 13 voiceprints over the past month, including at least one known contaminated entry (contact `1441` "Patrick", see `readmes/bugs/voiceprint-contamination-loop.md`) and a duplicate Patrick entry at contact `1098`. Clearing the table lets the system relearn organically from future calls.

## Solution

Delete all rows from the `speaker_embeddings` table in the live database at:

```
~/Library/Containers/ai.phonegentic.softphone/Data/Documents/phonegentic/call_history.db
```

This includes:

- Host embedding (`contact_id = 0`) — will be re-captured on the next call where the mic speaker is correctly identified.
- All per-contact embeddings — will be re-captured organically as calls come in and agent-attributed turns are saved via `upsertSpeakerEmbedding`.
- The agent's own TTS voiceprint is computed in-memory per call in `SpeakerIdentifier.swift` and is not persisted, so nothing to clear there.

The raw `voice_samples/` WAV directory is **not** touched — those are audio recordings used for voice cloning (a separate feature), not speaker-ID voiceprints.

A backup snapshot of the current rows is saved to `readmes/tasks/reset-voiceprints-backup.sql` just in case.

## Files

- `readmes/tasks/reset-voiceprints.md` — this doc
- `readmes/tasks/reset-voiceprints-backup.sql` — SQL dump of the rows that were deleted (embeddings stored as hex BLOBs)

No source files changed.
