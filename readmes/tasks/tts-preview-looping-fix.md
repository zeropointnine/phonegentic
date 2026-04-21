# TTS Voice Preview Plays Once (Not Looping)

## Problem

The voice preview in the settings panel keeps looping / overlapping instead of playing once. Root causes:

1. **Button resets before audio finishes**: `endGeneration()` completes when *synthesis* is done, but the native `AVAudioPlayerNode` still has queued PCM buffers playing. The button resets to "Preview", user clicks again, and a new synthesis overlaps with the still-playing audio—sounding like a loop.

2. **PocketTTS singleton channel conflict**: `PocketTtsService` uses a static `MethodChannel` and `EventChannel`. Creating a second instance for preview replaces the native EventChannel subscription and can interfere with the agent's active TTS.

## Solution

- **PocketTTS preview**: Bypass `PocketTtsService`. Use the static `MethodChannel`/`EventChannel` directly to import the voice embedding, synthesize, and stream audio. Don't call `initialize` or `dispose` on the native engine (leave it for the agent). Track total PCM bytes to estimate playback duration and keep the button in "playing" state until audio finishes. Call `stopAudioPlayback` before starting a new preview.

- **ElevenLabs preview**: Call `stopAudioPlayback` before starting and estimate remaining playback time after synthesis to keep the button active.

## Files

- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — rewritten `_playPocketPreview`, `_stopPocketPreview`, `_playElevenLabsPreview`, `_stopElevenLabsPreview`
