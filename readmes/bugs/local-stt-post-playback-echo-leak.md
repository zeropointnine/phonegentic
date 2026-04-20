# Local STT Post-Playback Echo Leak

## Problem

The agent "hears itself" after TTS playback finishes — short words like "You" are
transcribed from the residual TTS echo and fed to the LLM as user speech. This
creates a feedback loop where the agent responds to its own output. The user never
spoke.

This is a recurrence of the echo-suppression issue documented across multiple
readmes (`aec-comparison.md`, `agent-echo-self-talk-voice-interrupts.md`,
`streaming-tts-sentence-pipeline.md`), but in a gap not covered by prior fixes.

## Root cause

Two timing gaps in the local STT (WhisperKit) echo-suppression chain:

### Gap 1 — feedAudio gate has no cooldown

The Dart-level gate in `_localAudioSub` (agent_service.dart) checks
`!_whisper.isTtsPlaying`. When `isTtsPlaying` transitions to false, mic audio
immediately feeds to WhisperKit. Any residual room reverb or AEC leakage in the
first few hundred ms is transcribed. The `sendAudio()` path for OpenAI Realtime
has a 300 ms cooldown via `_ttsSuppressed`, but this was never applied to the
local STT path.

### Gap 2 — `_speakingEndTime` set at gen-done, not playback-complete

The echo guard timer (`_echoGuardMs = 2000ms`) buffers incoming transcripts for
2 s after `_speakingEndTime`. This timestamp is set when `_onTtsGenerationDone()`
fires (200 ms after the last TTS chunk is synthesised), NOT when native audio
playback actually finishes (which can be seconds later — ring buffers hold up
to 30 s).

The `onPlaybackComplete` debounce handler only updates `_speakingEndTime` inside
`if (_speaking)`, which is already false by this point (cleared by gen-done).
Result: by the time `isTtsPlaying` goes false and the mic opens, the echo guard
window has expired, and transcripts flow directly to the LLM without buffering.

### Timeline (before fix)

```
T+0ms     gen-done fires → _speaking=false, _speakingEndTime=T0
T+0ms     postSpeakFlush scheduled at T0+2000ms
T+2000ms  flush runs (nothing to flush — mic still gated by isTtsPlaying)
T+3000ms  onPlaybackComplete fires, 300ms debounce starts
T+3300ms  debounce fires → isTtsPlaying=false, _speakingEndTime NOT updated
T+3300ms  feedAudio gate opens → whisperKit receives mic audio
T+3500ms  transcript arrives: msSinceSpoke=3500 > _echoGuardMs(2000) → NOT buffered → LLM
```

### Timeline (after fix)

```
T+0ms     gen-done fires → _speaking=false, _speakingEndTime=T0
T+3000ms  onPlaybackComplete fires, 300ms debounce starts
T+3300ms  debounce fires → isTtsPlaying=false, _speakingEndTime=T+3300 (updated!)
T+3300ms  postSpeakFlush rescheduled at T+3300+2000ms
T+3600ms  ttsSuppressed cooldown (300ms) expires → feedAudio gate opens
T+3800ms  transcript arrives: msSinceSpoke=500 < _echoGuardMs(2000) → buffered ✓
T+5300ms  postSpeakFlush runs, text-match filter applied
```

## Solution

### 1. Expose `ttsSuppressed` in WhisperRealtimeService

Made the private `_ttsSuppressed` getter public. It returns true while
`isTtsPlaying` is true OR for 300 ms after it goes false (cooldown covers
reverb tail).

### 2. Use `ttsSuppressed` in the local STT feedAudio gate

Changed the guard from `!_whisper.isTtsPlaying` to `!_whisper.ttsSuppressed`
so the 300 ms cooldown applies to the local STT path, matching the sendAudio
path.

### 3. Always update `_speakingEndTime` at playback-complete

Moved `_speakingEndTime = DateTime.now()` outside the `if (_speaking)` block
in the `onPlaybackComplete` debounce handler. The echo guard window now resets
from the actual end of audio playback.

### 4. Re-schedule post-speak flush at playback end

`_schedulePostSpeakFlush()` is now called unconditionally in the
`onPlaybackComplete` handler, ensuring buffered transcripts wait the full
`_echoGuardMs` after playback ends.

## Files

- `phonegentic/lib/src/whisper_realtime_service.dart` — public `ttsSuppressed` getter
- `phonegentic/lib/src/agent_service.dart` — feedAudio gate, playback-complete handler
- `readmes/features/aec-comparison.md` — updated Path 3 to note in-call gap
