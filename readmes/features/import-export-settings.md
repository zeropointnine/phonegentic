# Import / Export Settings

## Problem

There is no way to back up or transfer Phonegentic configuration between devices
or recover after a reset. Users who have carefully configured SIP credentials,
agent LLM/TTS/STT settings, job functions with custom prompts and guardrails,
and inbound call-flow routing rules must recreate everything from scratch.

A portable import/export mechanism is needed so that any settings panel can be
saved to a labeled file (JSON, ZIP, or TAR) and restored later or on another
machine.

## Solution

A `SettingsPortService` centralises all serialization logic. Each of the four
settings areas (SIP, Agent, Job Functions, Inbound Workflows) can be exported
independently to a labeled file and re-imported on any device.

**Export format** -- every file is a JSON envelope:

```json
{
  "app": "phonegentic",
  "version": 1,
  "section": "sip_settings",
  "exported_at": "...",
  "data": { ... }
}
```

Users choose between three output formats via a segmented toggle:

| Format | Extension | Notes |
|--------|-----------|-------|
| JSON | `.json` | Human-readable, directly editable |
| ZIP | `.zip` | Compressed archive containing the JSON |
| TAR | `.tar.gz` | Gzipped tarball containing the JSON |

**Import** reads any of the three formats, validates the envelope, confirms with
the user, then replaces the current settings for that section. Inbound workflow
rules remap `job_function_id` by matching on job function title, so the
recommended import order is Job Functions first, then Inbound Workflows.

**Full Backup** -- a `FullBackupExportImportCard` on the User tab exports all
four sections into a single ZIP or TAR archive (one JSON per section inside).
Import reads the archive and applies all sections in dependency order (job
functions before inbound workflows). The confirmation dialog explicitly notes
that contacts and call history are not included.

**Per-section UI** -- a reusable `SettingsExportImportCard` widget is placed at
the bottom of each settings panel (Phone tab, Agent tab, User tab). It contains
the format toggle and Export/Import buttons.

## Files

### Created
- `phonegentic/lib/src/settings_port_service.dart` -- core export/import logic for all four sections
- `phonegentic/lib/src/widgets/settings_export_import_card.dart` -- reusable UI card with format toggle + buttons

### Modified
- `phonegentic/pubspec.yaml` -- added `archive` dependency for ZIP/TAR support
- `phonegentic/lib/src/register.dart` -- added SIP export/import card to Phone tab
- `phonegentic/lib/src/widgets/agent_settings_tab.dart` -- added Agent export/import card
- `phonegentic/lib/src/widgets/user_settings_tab.dart` -- added Job Functions + Inbound Workflows export/import cards

## Phase 2: Bundle Voice WAV Files

### Problem

Job Functions can reference a custom Pocket TTS voice (by `pocket_tts_voice_id`)
and/or a custom comfort-noise audio clip (by absolute `comfort_noise_path`).
Inbound Workflows point at Job Functions, so they inherit those references.

When a user exported their settings and re-imported them on another device, the
numeric IDs and absolute paths were meaningless on the target machine, so Job
Functions and Inbound Workflows would quiet-fail (fall back to default voice /
no comfort noise) even though the rest of the configuration was restored.

### Solution

The export/import envelope now bundles the actual WAV files alongside the JSON
config so imports work out of the box.

**On export** (`Agent Settings` and `Job Functions` sections):

- Each referenced *user-added* Pocket TTS voice WAV is inlined in the envelope
  as base64 along with its metadata (name, accent, gender) and any cloned
  voice embedding bytes. Default voices are referenced by name only -- they get
  re-seeded from bundled assets on import.
- Each referenced user comfort-noise WAV is inlined as base64 keyed by
  basename.
- `pocket_tts_voice_id` in each job function is replaced with
  `pocket_tts_voice_name`; `comfort_noise_path` is replaced with
  `comfort_noise_filename`.
- The global comfort-noise `selected_path` in Agent Settings is similarly
  replaced with `selected_filename` + inline base64.

**On import**:

1. Bundled comfort-noise WAVs are written to
   `{docs}/phonegentic/comfort_noise/` (skipping duplicates by filename).
2. Bundled Pocket TTS WAVs are written to
   `{docs}/phonegentic/pocket_tts_voices/` and a DB row (with embedding, if
   present) is inserted or re-used by voice name.
3. Job Functions are re-inserted with remapped `pocket_tts_voice_id`
   (name -> id) and `comfort_noise_path` (filename -> absolute path). Global
   Agent comfort-noise `selected_path` is remapped the same way.
4. Inbound Workflows re-map to the new Job Function IDs by title (unchanged
   from phase 1).

Backwards-compatible: older exports without the bundled audio fields still
import cleanly; missing assets just mean those references silently fall back
to defaults, matching the pre-phase-2 behaviour.

### Files

#### Modified
- `phonegentic/lib/src/settings_port_service.dart` -- gather/apply helpers
  now bundle + extract Pocket TTS and comfort-noise WAV files and remap IDs
  by voice name / file basename.
