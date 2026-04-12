# Voice Clone Modal — UI Polish & Feature Additions

## Summary

Overhaul of the voice clone modal (`voice_clone_modal.dart`) to fix visual bugs, add a waveform visualizer, modernize timers, add file upload support, and improve the playback scrubber.

## Changes

### 1. Fixed Double-Overlapped Text Input

The voice name field was wrapped in a `Container` with its own border/padding, plus a `TextField` inside — creating the visual appearance of two stacked input fields. Replaced with a single `TextField` using `InputDecoration` with `filled`, `fillColor`, `enabledBorder`, and `focusedBorder` so there's one clean input with a proper focus-ring highlight.

### 2. Animated Waveform Visualizer

Added a custom `_WaveformPainter` (CustomPainter) that draws 45 vertical bars with rounded caps, driven by two animation controllers:

- **`_waveCtrl`** — continuous 3s loop driving horizontal phase shift across three overlapping sine waves at different frequencies, creating organic fluid motion.
- **`_pulseCtrl`** — 1.2s ping-pong controlling amplitude intensity.

Amplitude varies by state:
| State | Amplitude Range |
|-------|----------------|
| Recording | 0.55 – 1.0 (strong pulse) |
| Playing back | 0.40 – 0.70 (medium pulse) |
| Has audio (idle) | 0.15 – 0.20 (gentle presence) |
| No audio | 0.08 – 0.12 (subtle breathing) |

Bar colors gradient from `AppColors.accent` → `AppColors.accentLight` across the width (amber → gold in VT-100, cyan → pink in Miami Vice). Active bars gain a blur-based glow effect when amplitude > 0.3.

### 3. macOS 26–Style Timer

Recording timer renders as `HH:MM:SS` with all six digits always visible. Zero-valued higher units get:
- **Strikethrough** text decoration
- **Dimmed opacity** (35% of tertiary color)

So 23 seconds displays as ~~00~~:~~00~~:23 — the leading zero pairs are struck through and faded, while active digits are fully bright. Uses tabular figures for stable width. A pulsing red dot with glow shadow animates alongside the timer during recording.

### 4. File Upload Button

Added an "Upload" circle button next to the Record button (hidden while recording). Uses `file_picker` (already a project dependency) with `FileType.custom` restricted to audio extensions: `wav`, `mp3`, `m4a`, `ogg`, `flac`, `aac`.

When a file is selected:
- `_uploadedFilePath` is set, `_recordingPath` is cleared
- The uploaded filename displays in the waveform section
- The file becomes the audio source sent to ElevenLabs on submit

Recording and uploading are mutually exclusive — starting a recording clears any uploaded file, and uploading clears any recording.

### 5. Playback Slider with Thumb Track

Replaced the thin `LinearProgressIndicator` with a `SliderTheme` + `Slider`:
- 3px track height
- 6px radius circular thumb in accent color
- 14px overlay radius on interaction
- Draggable — seeks playback position on change
- Accent-colored active track, dimmed inactive track

### 6. Pre-Recorded Path Waveform

When the modal opens with a `preRecordedPath` (from call recording), a dedicated waveform section displays with a "recording ready" label — so the user still sees the animated visualizer even without the record/upload controls.

### 7. General Polish

- `HoverButton` wrapping on all interactive circle buttons (record, upload, play/pause) per project UI conventions
- Proper `TickerProviderStateMixin` for dual animation controllers
- Accent border glow on the record section container while recording
- Consistent spacing, border radii, and visual hierarchy
- Error message for upload case: "Please record or upload an audio sample"

### 8. Agent Auto-Mute on Modal Open

When the voice clone dialog opens, it reads `AgentService` from the Provider tree and mutes the agent if it was active and unmuted. This prevents:
- TTS speaking over the recording session
- Whisper STT competing for the audio session
- Audio session conflicts that block `just_audio` playback

The previous mute state is restored when the dialog closes (dispose).

### 9. Playback via Native AudioTap

Replaced `just_audio` (AVFoundation) with direct native AudioTap playback. The app routes all audio through a native AudioTap engine that targets the user's specific audio interface (e.g., MOTU M4 USB). `just_audio` plays through macOS's default AVFoundation path, which routes to a different output device — resulting in silent playback.

The new flow:
1. **Read WAV** from disk and parse the header (channels, sample rate, bit depth)
2. **Stereo → mono** mix-down if the recording is stereo
3. **Resample to 24 kHz** via linear interpolation (AudioTap expects 24 kHz PCM16, matching ElevenLabs/Kokoro output)
4. **Send PCM chunks** to native via `playAudioResponse` on the `com.agentic_ai/audio_tap_control` method channel
5. **Track position** via wall-clock timer (80ms ticks) since native playback is fire-and-forget
6. **Stop** via `stopAudioPlayback` native call, clearing the buffer immediately

Additional fixes:
- **300ms delay** after `stopVoiceSample` to let the native side finalize the WAV
- **File validation** — checks existence and minimum size before attempting playback
- **Error surfacing** — playback failures now show in the UI error bar

## Files Modified

| File | Change |
|------|--------|
| `widgets/voice_clone_modal.dart` | Full rewrite — waveform, timer, upload, slider, agent mute, playback fixes |
