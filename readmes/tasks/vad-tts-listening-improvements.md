# VAD & TTS Listening Transition Improvements

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-11 (Phase 1), 2026-04-12 (Phase 1.5), 2026-04-13 (Phase 3, Phase 2, Phase 2b)

## Goal

Eliminate dead-air delays in the agent voice pipeline. Phase 1–1.5 targeted the post-speech → listening transition. Phase 3 targets the outbound call greeting delay.

## Status

Phase 1 (fast listen transition) is complete. Phase 1.5 (echo feedback fix) is complete. Phase 3 (outbound greeting latency) is complete. Phase 2 (interruption / barge-in handling) is complete. Phase 2b (VAD-based fast interrupt) is complete.

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

## Phase 3: Outbound Greeting Latency (2026-04-13)

### Problem

On outbound calls, the remote party waits ~10 seconds after answering before hearing the agent. The delay is a serial chain of timers and network round-trips:

| Step | Delay | Source |
|------|-------|--------|
| Settle window | 4000ms | `_settleWindowMs` |
| VAD defer in settle | +1000ms/loop | callee "Hello?" keeps VAD hot |
| Connected greet delay | 1500ms | `_connectedGreetDelayMs` |
| VAD defer in greeting | +800ms/loop | callee still talking |
| LLM first token | ~1-2s | Network + model latency |
| TTS first chunk | ~0.5-1s | ElevenLabs/Kokoro generation |
| **Total** | **~7-12s** | |

### Fix: Pre-Generate Greeting During Settle + Reduce Timer Chain

Three stacked optimizations:

1. **Pre-generate LLM greeting during settling** (saves ~2-3s): Fire the greeting prompt to the text agent immediately when entering `settling` on outbound split-pipeline calls. Buffer the streaming response in `_preGreetTextBuffer`/`_preGreetFinalText`. On promotion to `connected`, flush the pre-generated text through TTS immediately instead of starting from zero.

2. **Shorter settle window for outbound** (saves ~2s): New `_settleWindowOutboundMs = 2000` (vs 4000ms for inbound). IVR extension path still works — `_extendSettleTimer` handles voicemail greetings.

3. **Reduce connected greeting delay** (saves ~1s): `_connectedGreetDelayMs` from 1500ms → 500ms. When pre-greeting is ready, delay is 0 (immediate flush).

### Changes

| File | Change |
|------|--------|
| `agent_service.dart` | Added `_preGreetInFlight`, `_preGreetTextBuffer`, `_preGreetFinalText`, `_preGreetReady` fields |
| `agent_service.dart` | `_startSettleTimer()` uses `_settleWindowOutboundMs` (2s) for outbound calls and fires `_firePreGreeting()` |
| `agent_service.dart` | `_appendStreamingResponse()` intercepts pre-greeting responses into buffer |
| `agent_service.dart` | `_scheduleConnectedGreeting()` flushes pre-greeting immediately if ready, or waits for in-flight |
| `agent_service.dart` | New `_firePreGreeting()`, `_flushPreGreeting()`, `_discardPreGreeting()` methods |
| `agent_service.dart` | `_connectedGreetDelayMs` reduced from 1500 → 500 |

### Resulting timing

| Scenario | Before | After |
|----------|--------|-------|
| Human answers, no IVR | ~7-8s | ~3-4s |
| Human answers, VAD active | ~10-12s | ~4-5s |
| IVR/voicemail | unchanged | unchanged |

### Edge cases handled

- **IVR detected during settle**: Pre-greeting discarded (`_ivrHeard` check in `_flushPreGreeting`), voicemail prompt path takes over.
- **LLM error in pre-greeting**: Error detected in `_appendStreamingResponse`, pre-greeting discarded, falls back to normal `_connectedGreetDelayMs` timer.
- **Settle transcripts exist**: Pre-greeting flushes first (plays immediately). Settle transcripts are added as **system context** (`addSystemContext`) rather than `addTranscript` to avoid triggering a duplicate LLM response. The agent has the context for subsequent turns without generating a second greeting.
- **Pre-greeting still streaming when connected fires**: `_scheduleConnectedGreeting` returns early; the `_appendStreamingResponse` handler flushes on arrival.
- **Phase-transition context causes duplicate greeting**: During the pre-greeting LLM call, `notifyCallPhase(settling)` and `notifyCallPhase(connected)` each call `addSystemContext()`, accumulating context in `_pendingContext`. When the pre-greeting response completes, `_respond()`'s finally block sees non-empty `_pendingContext` and auto-fires `_scheduleFlush()` → another LLM call → duplicate greeting. Fix: `_flushPreGreeting()` calls `_textAgent.clearPendingContext()` which discards accumulated phase context without triggering a response.
- **Live "Hello?" transcript triggers duplicate greeting**: Whisper VAD captures the remote party's initial speech (e.g. "Hello?") during or overlapping the settle window. The transcription arrives during `connected` phase and flows through `_processTranscript` → `addTranscript` → triggers a full LLM response that duplicates the greeting. Fix: `_preGreetGraceUntil` timestamp is set when flushing the pre-greeting. The first transcript within this 10-second grace window is added as `addSystemContext` (context only, no response) instead of `addTranscript`. The LLM sees what the callee said for future turns but doesn't generate a redundant greeting.

---

## Phase 2: Interruption / Barge-In Handling (2026-04-13)

### Problem

Two stacked issues prevented the agent from being interrupted:

1. **Audio suppression dropped remote audio during TTS.** `WhisperRealtimeService.sendAudio()` checked `_ttsSuppressed` (true when `isTtsPlaying`) and dropped ALL audio. No audio reached Whisper, so no transcripts were generated while the agent spoke.

2. **Transcripts buffered, not acted on.** Even when a transcript arrived during `_speaking`, it was silently buffered in `_pendingTranscripts` and only processed after the agent finished + `_echoGuardMs` (2000ms).

Combined: the remote party had to wait for the agent's entire utterance + 2s echo guard before the agent reacted.

### Root cause discovery: native already handles echo

The native `flushBuffers` in call mode (`AudioTapChannel.swift`) already strips mic audio during TTS via `ttsEchoActive`. It sends only remote party audio from `whisperRingBuffer` (populated in the render processor before TTS mixing). Flutter received clean, echo-free remote audio during TTS — and threw it away at the `_ttsSuppressed` check.

### Fix: Four-layer interrupt

**Layer 0 — Stop discarding remote audio in call mode:**
- Added `inCallMode` flag to `WhisperRealtimeService`
- `sendAudio()` bypasses `_ttsSuppressed` when `inCallMode` is true — native already provides echo-free remote-only audio
- `AgentService` sets `inCallMode = true` on `CallPhase.settling`, clears on call end

**Layer 1 — Cancel in-flight LLM response:**
- Added `_cancelRequested` flag and `cancelCurrentResponse()` to `TextAgentService`
- `_callClaude()` SSE loop checks the flag after each chunk; breaks early when set
- Emits partial `ResponseTextEvent(isFinal: true)` with accumulated text, adds to history

**Layer 2 — Clear native TTS audio queue:**
- Added `clearTTSBuffers()` to `WebRTCAudioProcessor.swift` — resets `ttsCaptureRing`, `ttsRenderRing`, `ttsRecordingRing`
- Added `clearTTSQueue` method channel handler in `AudioTapChannel.swift` — clears buffers, invalidates `callModePlaybackTimer`, fires `onPlaybackComplete`
- Added `clearTTSQueue()` Dart method in `WhisperRealtimeService`

**Layer 3 — Interrupt orchestration in AgentService:**
- New `_interruptAgent(TranscriptionEvent)` method:
  0. `_ttsInterrupted = true` — gate the audio listener so in-flight ElevenLabs/Kokoro chunks are dropped (prevents re-filling ring buffers after clear)
  1. `_textAgent.cancelCurrentResponse()` — stop LLM streaming
  2. `_activeTtsEndGeneration()` — stop TTS text-to-audio
  3. `_whisper.stopResponseAudio()` + `_whisper.clearTTSQueue()` — silence native playback
  4. `_whisper.isTtsPlaying = false` — ungate audio immediately
  5. Cancel all post-speak / playback timers
  6. `_speaking = false`, `_speakingEndTime = now`
  7. Finalize interrupted UI message (truncate to spoken text)
  8. Flush `_pendingTranscripts` immediately (skip echo guard)
  9. Process the interrupting transcript via `_processTranscript`
- `_ttsInterrupted` cleared in `_activeTtsStartGeneration()` so the next response's audio flows normally

**Layer 4 — Modified `_onTranscript` interrupt detection:**
- Condition expanded from `if (_speaking)` to `if (_speaking || _whisper.isTtsPlaying)` — covers the window after gen-done where `_speaking` is false but ring buffers still have queued audio
- Non-echo transcripts trigger `_interruptAgent()` instead of buffering
- Echo detection via `_isEchoOfAgentResponse()` still filters TTS echo (safety net)
- Pre-greet grace window still adds first transcript as context only

**Layer 5 — Native playback timer based on ring buffer depth:**
- `callModePlaybackTimer` changed from a fixed 2s one-shot timer to a 250ms repeating poll
- Polls `ttsRenderRing.availableToRead` — only fires `onPlaybackComplete` when the ring is empty AND the 2s echo suppression window has elapsed
- Prevents premature `isTtsPlaying = false` when large responses queue 20+ seconds of audio in the ring buffers
- Timer created once per generation (nil-check guard); invalidated on `clearTTSQueue`, `enterCallMode`, `exitCallMode`

### Changes

| File | Change |
|------|--------|
| `whisper_realtime_service.dart` | Added `inCallMode` flag; `sendAudio` bypasses `_ttsSuppressed` in call mode; new `clearTTSQueue()` method |
| `text_agent_service.dart` | Added `_cancelRequested` flag, `cancelCurrentResponse()`, early exit in `_callClaude()` SSE loop |
| `agent_service.dart` | New `_interruptAgent()` method with `_ttsInterrupted` gate; `_onTranscript` checks `_speaking \|\| isTtsPlaying`; sets `_whisper.inCallMode` on settling/end |
| `WebRTCAudioProcessor.swift` | New `clearTTSBuffers()` — resets all TTS ring buffers |
| `AudioTapChannel.swift` | New `clearTTSQueue` method channel handler; `callModePlaybackTimer` changed to ring-buffer-aware repeating poll |

### Edge cases handled

- **Pre-greet grace period**: First transcript during grace window is added as context only (no interrupt)
- **Echo detection**: `_isEchoOfAgentResponse()` filters any TTS echo that slips through
- **Post-speak echo guard**: Still active after agent finishes naturally (non-interrupt path unchanged)
- **Direct mode**: `_ttsSuppressed` still applies (native blocks event sink via `isPlayingResponse`); interruption works via buffered pre-TTS transcripts
- **Tool calls in progress**: Handled by normal `_processTranscript` flow after interrupt
- **Gen-done / playback gap**: `_speaking` clears ~200ms after TTS generation ends, but ring buffers may still have 20+ seconds of audio. The expanded `_onTranscript` condition (`_speaking || isTtsPlaying`) catches interrupts in this window. The native repeating timer ensures `isTtsPlaying` stays true until buffers actually drain. The `_playbackSafetyTimer` was increased from 3s to 45s to avoid prematurely clearing `isTtsPlaying` for long responses (ring buffers hold up to 30s).
- **In-flight TTS chunks after interrupt**: ElevenLabs generates chunks ahead of playback; `endGeneration()` + `clearTTSBuffers()` alone are insufficient because chunks still in the WebSocket pipeline refill the ring buffers after the clear. `_ttsInterrupted` flag gates the `_ttsAudioSub` listener, dropping all remaining chunks from the old generation. Cleared on `_activeTtsStartGeneration()` for the new response.
- **UI message cleanup**: Interrupted response finalized with partial text, voice hold released

---

## Phase 2b: VAD-Based Fast Interrupt (2026-04-13)

### Problem

Transcript-based interruption (Phase 2) requires the full Whisper pipeline to complete: user speaks → VAD detects speech stop → audio committed → Whisper transcribes → transcript event arrives → `_onTranscript` triggers interrupt. Minimum latency: ~2-3 seconds (speech duration + Whisper processing). For long agent responses (20-30s of buffered audio), the user has to wait the full 2-3s before audio stops.

### Fix: Interrupt on VAD speech detection

Instead of waiting for a complete transcript, listen for the raw VAD `speech_started` event from OpenAI Realtime and stop agent audio immediately with a short debounce.

**New stream — `vadEvents` in `WhisperRealtimeService`:**
- `StreamController<bool>.broadcast()` emitting `true` on `input_audio_buffer.speech_started`, `false` on `speech_stopped`
- Exposed as `Stream<bool> get vadEvents`

**New handler — `_onVadEvent()` in `AgentService`:**
- On `speech_started`: if `_speaking || isTtsPlaying` is true, starts a 300ms debounce timer
- If VAD is still active after 300ms, calls `_vadInterruptStop()` — same cleanup as `_interruptAgent()` (gate audio, cancel LLM, clear buffers, finalize UI) but without processing a transcript
- The transcript arrives later through the normal `_onTranscript` path and is handled as a new utterance
- Skips during `settling` phase and if `_ttsInterrupted` is already set
- On `speech_stopped`: cancels the debounce timer (prevents false triggers from brief noise)

**Safety timer adjustment:**
- `_playbackSafetyTimer` increased from 3s to 45s — the native ring-buffer-aware polling timer fires `onPlaybackComplete` accurately; the safety timer is now a last resort

### Changes

| File | Change |
|------|--------|
| `whisper_realtime_service.dart` | Added `_vadController` stream; emits on `speech_started`/`speech_stopped`; exposed as `vadEvents`; closed in `dispose()` |
| `agent_service.dart` | Added `_vadSub` subscription to `vadEvents`; new `_onVadEvent()` handler with 300ms debounce; new `_vadInterruptStop()` method (audio-only interrupt, no transcript); `_vadInterruptDebounce` timer cancelled in all cleanup paths |
| `agent_service.dart` | `_playbackSafetyTimer` increased from 3s to 45s |

### Resulting interrupt latency

| Path | Latency | When |
|------|---------|------|
| VAD barge-in (new) | ~300ms | User speaks during agent audio |
| Transcript barge-in (Phase 2) | ~2-3s | Fallback if VAD debounce cancelled |
| Safety timer | 45s | Last resort if native timer fails |

---

## Phase 2c: Transcript Animation Snap on Interrupt (2026-04-13)

### Problem

When a barge-in interrupt fires, the audio stops immediately but the agent's text bubble keeps revealing text character-by-character via the `StreamingTypingText` typewriter animation. This happens because:

1. `ttsActiveForUi` was a static config check (`_splitPipeline && _hasTts && !_ttsMuted && !_muted`) that stayed true even after audio stopped
2. The widget's `voiceSync` prop never changed on interrupt, so it kept draining at 25 chars/sec
3. For long responses where Claude finished before the interrupt, `isStreaming` was already false — there was no state transition to trigger a snap

### Fix

**`ttsActiveForUi` now reflects runtime TTS state:**
- Added `(_speaking || _whisper.isTtsPlaying)` condition so it returns false the moment audio stops
- This causes `voiceSync` to transition from true→false on both `_vadInterruptStop` and `_interruptAgent`

**`StreamingTypingText` freezes and truncates on voiceSync transition:**
- When `voiceSync` transitions from true→false while `isStreaming` is false (drain mode), the widget sets `_frozenByInterrupt = true`, stops the timer, and leaves `_revealed` at its current position
- The `build` method appends "…" when frozen mid-text, so the user sees only the text that was actually spoken
- A new streaming message (`isStreaming` false→true) resets the freeze, allowing the next response to animate normally
- While frozen, all `didUpdateWidget` rebuilds are short-circuited to prevent the drain timer from restarting

### Changes

| File | Change |
|------|--------|
| `agent_service.dart` | `ttsActiveForUi` getter now includes `(_speaking \|\| _whisper.isTtsPlaying)` |
| `streaming_typing_text.dart` | Interrupt freezes at current `_revealed` with "…" suffix instead of snapping to full text |
