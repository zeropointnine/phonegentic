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

**UI** -- a reusable `SettingsExportImportCard` widget is placed at the bottom
of each settings panel (Phone tab, Agent tab, User tab). It contains the format
toggle and Export/Import buttons.

## Files

### Created
- `phonegentic/lib/src/settings_port_service.dart` -- core export/import logic for all four sections
- `phonegentic/lib/src/widgets/settings_export_import_card.dart` -- reusable UI card with format toggle + buttons

### Modified
- `phonegentic/pubspec.yaml` -- added `archive` dependency for ZIP/TAR support
- `phonegentic/lib/src/register.dart` -- added SIP export/import card to Phone tab
- `phonegentic/lib/src/widgets/agent_settings_tab.dart` -- added Agent export/import card
- `phonegentic/lib/src/widgets/user_settings_tab.dart` -- added Job Functions + Inbound Workflows export/import cards
