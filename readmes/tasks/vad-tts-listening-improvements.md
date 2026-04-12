# VAD & TTS Listening Transition Improvements

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-11 (Phase 1), 2026-04-12 (Phase 1.5)

## Goal

Eliminate the ~5.5 second dead-air delay between the agent finishing speaking and resuming listening. The root cause was three stacked timers that all had to expire sequentially before `sendAudio` resumed streaming mic/remote audio to OpenAI.

## Status

Phase 1 (fast listen transition) is complete. Phase 1.5 (echo feedback fix) is complete. Phase 2 (industry-standard interruption handling) is planned.

---

## Problem

After the agent finishes speaking, the mic-to-OpenAI pipeline was blocked by a triple-stacked delay:

| Layer | Timer | Purpose |
|-------|-------|---------|
| Native (`AudioTapChannel.swift`) | `callModeTTSSuppression` = **2.0s** after last TTS chunk | Fires `onPlaybackComplete` to Flutter |
| Flutter (`AgentService`) | `_playbackEndDebounce` = **2.0s** after last native callback | Debounce per-buffer drain events |
| Flutter (`WhisperRealtimeService`) | `_ttsEchoCooldownMs` = **1.5s** after `isTtsPlaying` clears | Extra suppression on `sendAudio` |

**Total: ~5.5s** of silence where the agent couldn't hear anything — not even the remote party on a phone call.

## Changes Made (Phase 1)

### Core idea

We know exactly when TTS generation completes (ElevenLabs `isFinal`, Kokoro queue drain, OpenAI `response.audio.done`). Use that as the trigger with a short 500ms drain buffer, instead of waiting for the slow native-callback chain.

### Files Changed

| File | Changes |
|------|---------|
| `phonegentic/lib/src/agent_service.dart` | Added `_ttsGenEndTimer` field and `_onTtsGenerationDone()` method — 500ms timer after TTS generation ends that clears `isTtsPlaying` and transitions to "Listening" |
| `phonegentic/lib/src/agent_service.dart` | ElevenLabs & Kokoro `_ttsSpeakingSub` listeners now call `_onTtsGenerationDone()` on `speaking=false` (previously only handled `speaking=true`) |
| `phonegentic/lib/src/agent_service.dart` | Unified pipeline `_speakingSub` also calls `_onTtsGenerationDone()` on generation done |
| `phonegentic/lib/src/agent_service.dart` | `onPlaybackComplete` handler is now a safety fallback (800ms debounce, no-ops if gen-done timer already handled it) |
| `phonegentic/lib/src/whisper_realtime_service.dart` | Reduced `_ttsEchoCooldownMs` from 1500 → 300ms (native already handles echo suppression at audio level) |

### New timing

**Flutter side** (gates `sendAudio`):

| Path | Delay |
|------|-------|
| Generation-done (fast path) | **~300ms** (200ms drain + 100ms cooldown) |
| Native fallback (safety net) | **~900ms** (800ms debounce + 100ms cooldown) |

**Native side** (`AudioTapChannel.swift`, gates event sink in direct mode):

| Timer | Before | After |
|-------|--------|-------|
| `playbackEndTimer` (buffer scheduling gap) | 0.35s | 0.10s |
| `outputSuppressedUntil` (reverb decay) | 1.00s | 0.20s |
| **Total native post-playback** | **1.35s** | **0.30s** |

In **call mode**, native echo suppression (`callModeTTSSuppression` 2s) is independent — it strips mic audio from the event sink but remote audio always flows. In **direct mode**, the native post-playback window is the real bottleneck since the event sink is fully blocked during playback + suppression.

---

## Phase 1.5: Echo Feedback Fix (2026-04-12)

### Problem

Phase 1 introduced a regression: the agent was hearing its own TTS output and responding to garbled Whisper transcriptions of it (e.g. "residue and nummy and over the", "valder's type letters you from"). This created a feedback loop where the agent responded to echo, generating more speech, generating more echo.

**Root cause**: `_onTtsGenerationDone()` cleared `isTtsPlaying` 200ms after TTS **generation** ended, but the native layer still had buffered audio playing through the speakers. With `_ttsEchoCooldownMs` at 100ms, Whisper started receiving mic audio while TTS was still audible. The garbled transcriptions didn't match the text echo filter (`_isEchoOfAgentResponse`) because Whisper mangled them beyond recognition.

### Fix: Split UI transition from audio pipeline gating

The two concerns — "show Listening in the UI" and "let Whisper hear the mic" — require different timing:

| Signal | Controls | Timing |
|--------|----------|--------|
| `_speaking = false` | UI state, echo guard window start | 200ms after gen-done (fast) |
| `isTtsPlaying = false` | Whisper `sendAudio` gate | When native confirms playback done (accurate) |

### Changes

| File | Change |
|------|--------|
| `agent_service.dart` — `_onTtsGenerationDone()` | No longer clears `isTtsPlaying` or cancels `_playbackEndDebounce`. Only transitions UI (`_speaking = false`). Added `_playbackSafetyTimer` (3s) in case native never reports completion. |
| `agent_service.dart` — `onPlaybackComplete` | Removed early-exit guard (`!_speaking && !_whisper.isTtsPlaying`). Now always processes native callbacks and is the authoritative signal for clearing `isTtsPlaying`. |
| `whisper_realtime_service.dart` | `_ttsEchoCooldownMs` increased from 100ms → 300ms for residual reverb after playback ends. |

### Resulting timing

| Event | Time after gen-done |
|-------|---------------------|
| UI shows "Listening" | ~200ms |
| Echo guard window starts (`_speakingEndTime`) | ~200ms |
| Native finishes playing buffered audio | variable (depends on buffer depth) |
| `onPlaybackComplete` debounce fires | native done + 800ms |
| `isTtsPlaying` clears | native done + 800ms |
| Whisper starts receiving audio | native done + 800ms + 300ms cooldown |
| Buffered transcripts flushed (echo-filtered) | ~200ms + `_echoGuardMs` (2000ms) |
| Safety fallback if native silent | ~3200ms |

---

## Phase 2: Interruption Handling (TODO)

Industry-standard barge-in so the user can interrupt the agent mid-speech:

- [ ] Detect user speech (via server VAD `speech_started`) while agent is speaking
- [ ] Cancel in-flight TTS generation (`_activeTtsEndGeneration()`)
- [ ] Stop native audio playback (`stopResponseAudio()`)
- [ ] Cancel OpenAI response if unified pipeline (`response.cancel`)
- [ ] Immediately transition to listening and process the interrupting transcript
- [ ] Tunable sensitivity: threshold for how much speech triggers an interrupt vs. background noise
- [ ] Currently transcripts during speech are buffered in `_pendingTranscripts` — need to distinguish genuine barge-in from echo

### Key challenge

The echo guard exists for a reason — mic picks up the agent's own voice from speakers, and Whisper transcribes it. Barge-in detection must reliably distinguish the user's voice from TTS echo. Options:
1. Speaker identification (voiceprint) — already partially implemented
2. Energy threshold differential — if mic energy significantly exceeds expected TTS leakage
3. Server-side VAD confidence + text echo matching — keep the text-echo filter but don't buffer, process immediately with echo check
