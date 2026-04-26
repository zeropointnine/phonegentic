# Comfort Noise

## Problem

When a call is answered but the agent hasn't started speaking yet (the settling/pre-connect window), the remote party hears dead silence. This creates an awkward experience — callers may think the line dropped or no one is there. Traditional telephony uses comfort noise (low-level background audio) to signal the line is alive, but our app has no equivalent.

We need a way for users to upload custom audio clips (office ambience, gentle hum, soft hold music) that loop into the call stream during this gap, stopping automatically when the agent begins speaking.

## Solution

Comfort noise is a user-uploaded audio clip that loops into the call audio stream via the existing `playAudioResponse` native path. It plays during every silence gap in the call — the initial settling phase, the pauses between remote speech ending and agent TTS arriving, the gap after the agent finishes speaking, and continuously through the remote party's own speech. Playback only pauses for outgoing agent TTS (so the agent's voice isn't muddied) and stops on call end/fail.

**Lifecycle triggers:**
- **Settling** — starts with a 250ms pipeline-init delay when the call enters settling, survives the settling→connected transition.
- **Between turns** — resumes immediately (no pipeline delay) when a transcript is sent to the LLM, provided the agent isn't already speaking.
- **After agent TTS** — resumes when native `onPlaybackComplete` fires so the gap between the agent finishing and the remote replying stays filled.
- **Through remote speech** — VAD speech-start events do **not** stop comfort noise. Because the loop is sent outbound only, the caller never hears themselves echoed and the ambient stays continuous instead of dropping out the moment they speak.
- **Pause on TTS** — all three TTS paths (ElevenLabs, Kokoro, OpenAI Realtime) pause comfort noise on the first audio chunk so the agent's voice plays cleanly.
- **Stop on call end** — ended/failed phases stop comfort noise.

**Continuous loop position:** the loop offset is persisted on the service across pause/resume cycles, so each resume continues from where the previous chunk left off rather than restarting at byte 0. This makes the ambient feel like one continuous track rather than the same opening seconds repeating after every silence gap. The offset is reset only when the selected file changes or is deleted.

The PCM is pre-cached at app startup to avoid file I/O latency during calls. A cancellation flag prevents late starts when the call phase advances before loading completes.

**Configuration layers:**
- **Global** — enabled/disabled toggle, volume (0–1), and selected file path stored in SharedPreferences via `AgentConfigService`.
- **Per-job-function** — nullable `comfort_noise_path` column on the `job_functions` SQLite table. `null` = use global, non-empty = use this specific file. Comfort noise is disabled simply by not enabling it globally or not selecting a file.

**Audio pipeline:** files are converted to PCM16 24 kHz mono (the format `playAudioResponse` expects) and chunked into the stream on a timer. Volume is applied by scaling PCM samples before sending.

**File management:** uploaded files are copied to `phonegentic/comfort_noise/` under the app documents directory (same pattern as custom ringtones). A shared picker widget handles upload, delete, preview, and selection in both the agent settings tab and the job function editor.

## Files

### Created
- `phonegentic/lib/src/comfort_noise_service.dart` — service: prefs, file management, PCM conversion, looped playback
- `phonegentic/lib/src/widgets/comfort_noise_picker.dart` — reusable upload/delete/preview/select widget

### Modified
- `phonegentic/lib/src/agent_config_service.dart` — `ComfortNoiseConfig` class + load/save
- `phonegentic/lib/src/models/job_function.dart` — `comfortNoisePath` field
- `phonegentic/lib/src/db/call_history_db.dart` — migration for `comfort_noise_path` column
- `phonegentic/lib/src/job_function_service.dart` — pass comfort noise path through boot context
- `phonegentic/lib/src/models/agent_context.dart` — `comfortNoisePath` on `AgentBootContext`
- `phonegentic/lib/src/agent_service.dart` — start/stop comfort noise on call phase transitions
- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — comfort noise settings card
- `phonegentic/lib/src/widgets/job_function_editor.dart` — comfort noise override section
- `phonegentic/lib/main.dart` — register `ComfortNoiseService` provider
- `phonegentic/lib/src/settings_port_service.dart` — include comfort noise in export/import
