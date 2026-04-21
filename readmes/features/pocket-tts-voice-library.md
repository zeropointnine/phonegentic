# Pocket TTS Voice Library

## Problem

Pocket TTS currently only supports a single voice clone path stored in SharedPreferences. There's no way to manage multiple voices, no default bundled voices, and the voice selection UX is just a file picker — nothing like the polished ElevenLabs voice dropdown.

Users need:
- Default bundled voices they can use out of the box
- Ability to upload and name custom voices (like ElevenLabs clone UI)
- A dropdown to select voices across settings, job functions, callscreen, and agent tools
- Voice embeddings persisted in SQLite so they survive restarts without re-encoding

## Solution

### Architecture

1. **Bundled voice assets**: WAV files in `assets/voices/` registered in pubspec.yaml. On first launch, these are extracted to the documents directory. On first PocketTTS init, they are encoded through the voice encoder and the embeddings are cached in SQLite.

2. **SQLite `pocket_tts_voices` table**: Stores voice metadata (name, accent, gender, audio path) plus the serialized voice embedding blob. Both default and user-uploaded voices live here.

3. **`PocketTtsVoiceDb`** service: CRUD for voices, seeding defaults from assets, loading embeddings into the native engine at TTS init time.

4. **Updated settings UI**: Pocket TTS section gets a full voice dropdown with "On Device Voices" header for defaults and user uploads, plus an "Add Voice" button that opens an upload modal, and a "Preview" button that synthesizes a sample sentence with the selected voice for instant audition.

5. **Integration points**: Voice selection flows through `TtsConfig.pocketTtsVoiceId` (replacing the old clone path) into `AgentService._initPocketTts`, job function editor, callscreen clone, and agent tools.

### Default Voices

| Name | Accent | Gender | Asset |
|------|--------|--------|-------|
| Reassuring Raj | Indian | Male | reassuring_raj_indian_male.wav |
| Super Scott | American | Male | super_scott_american_male.wav |
| Happy Jose | Spanish | Male | Happy_Jose_spanish_male.wav |
| Likable Lacy | American | Female | Likable_Lacy_american_female.wav |
| Queen Anne | British | Female | queen_anne_british_female.wav |
| Handly Harold | American | Male | handly_harold.wav |

### DB Schema (v20)

```sql
CREATE TABLE pocket_tts_voices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  accent TEXT,
  gender TEXT,
  is_default INTEGER NOT NULL DEFAULT 0,
  audio_path TEXT,
  embedding BLOB,
  created_at TEXT NOT NULL
)
```

## Files

### Created
- `phonegentic/assets/voices/*.wav` — 6 bundled default voice WAV files
- `phonegentic/lib/src/db/pocket_tts_voice_db.dart` — PocketTtsVoice model + CRUD + default seeding
- `readmes/features/pocket-tts-voice-library.md` — this file

### Modified
- `phonegentic/pubspec.yaml` — register voice assets
- `phonegentic/lib/src/db/call_history_db.dart` — v20 migration: pocket_tts_voices table + job_functions.pocket_tts_voice_id column
- `phonegentic/lib/src/agent_config_service.dart` — TtsConfig.pocketTtsVoiceId field, load/save
- `phonegentic/lib/src/models/agent_context.dart` — AgentBootContext.pocketTtsVoiceId
- `phonegentic/lib/src/models/job_function.dart` — pocketTtsVoiceId field + serialization
- `phonegentic/lib/src/job_function_service.dart` — pass pocketTtsVoiceId to boot context
- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — voice library dropdown + upload modal (replaces old file picker)
- `phonegentic/lib/src/widgets/job_function_editor.dart` — Pocket TTS voice override dropdown
- `phonegentic/lib/src/agent_service.dart` — DB voice loading in _initPocketTts, override apply, tool handlers (list/set)
- `phonegentic/lib/src/callscreen.dart` — Pocket TTS sample-to-DB flow
- `phonegentic/lib/main.dart` — seed default voices on startup
