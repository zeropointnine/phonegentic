# WhisperKit Hallucination & TTS Feedback Loop Fix

## Problem

In local STT mode (WhisperKit on macOS), the app was effectively unusable due to several interacting issues:

1. **TTS feedback loop**: The agent's TTS output was picked up by the mic, transcribed by WhisperKit, and sent back to the LLM — causing the agent to respond to itself in an endless loop ("Hi Patrick! → What's next? → Anything I can help with? → ...")

2. **Hallucinated non-speech sounds**: WhisperKit transcribed ambient noise as bracketed tags like `(upbeat)`, `{bell dinging}`, `[POP]`, `[Paper]`, `{no audio}` — some of which slipped past the existing filter and triggered LLM responses.

3. **Repeated/duplicated words**: The 500ms carry-over buffer in WhisperKitChannel.swift caused the same audio tail to be transcribed in consecutive windows, producing transcripts like "Good, good, perfect. Perfect, perfect" when the user only said "perfect."

4. **User couldn't reply after short responses**: The fixed 2000ms echo guard was too long — after a short "What's next?" from the agent, the user's immediate reply was eaten by the guard window.

5. **Voiceprint unused for echo detection**: The `SpeakerIdentifier` already had agent TTS voiceprint capture (`feedAgentTTS`) and matching (`isAgentVoice`), but this wasn't wired for local STT echo filtering.

## Solution

A six-layer fix across Dart, Swift, and native audio:

### 1. Loop Breaker (agent_service.dart)
- Added `_consecutiveAgentResponses` counter, incremented on each finalized agent response
- Reset to 0 when genuine user speech is forwarded via `_processTranscript`
- After 2+ consecutive responses without user input, only substantive transcripts (4+ words) can break through — short fragments (echo residue) are dropped
- Prevents the "AI talking to itself" death spiral

### 2. Expanded Hallucination Filtering (agent_service.dart)
- Added curly brace `{tag}` support alongside existing `[tag]` and `(tag)` patterns
- Expanded `_nonSpeechTagPattern` with ~40 additional tags (upbeat, bell, POP, Paper, sound, typing, keyboard, etc.)
- Added `_entirelyNonSpeechRe` to catch transcripts composed only of bracketed tags
- Added `_isRepeatedWordHallucination()` to detect "good good good" style artifacts
- Added common hallucination phrases: "thank you", "bye", "i'm sorry", "you", "the end"
- Changed `_whisperParenPrefixRe` to also strip `[tag]` and `{tag}` prefixes, not just `(tag)`
- Now strips ALL non-speech tags from anywhere in the transcript (not just leading prefix)

### 3. TTS Echo Cooldown — Tuned Down for Responsiveness
- **Dart (whisper_realtime_service.dart)**: `_ttsEchoCooldownMs` initially raised from 300ms → 800ms, then **reduced back to 300ms** once voiceprint + text echo matching + loop breaker made the aggressive cooldown unnecessary. The higher value was causing ~1.25s of user speech to be thrown away, making it impossible to reply quickly.
- **Native (AudioTapChannel.swift)**: Post-playback suppression raised from 0.20s → 0.50s, then **reduced to 0.30s** for the same responsiveness reason. The 0.15s playback-end timer is kept.

### 4. Adaptive Echo Guard (agent_service.dart)
- Added `_speakingStartTime` tracking across all 3 TTS backends (ElevenLabs, Kokoro, Pocket)
- New `_effectiveEchoGuardMs` getter computes guard based on speaking duration:
  - < 2s spoken → 400-600ms guard (25% of base) — user can reply almost immediately to short questions
  - 2-4s spoken → 600-1000ms guard (50% of base)
  - > 4s spoken → full 2000ms guard
- Applied to `_onTranscript`, `_flushPendingTranscripts`, and text-echo-check window
- Previously the short-response guard was clamped to 800-1200ms, which still created a ~2s dead zone when combined with native + Dart cooldowns

### 5. WhisperKit Carry-Over Dedup (WhisperKitChannel.swift)
- Reduced carry-over from 500ms → 250ms (less audio overlap per window)
- Added `lastTranscriptText` tracking and `deduplicateCarryOver()` method
- New method finds longest suffix-of-previous that matches prefix-of-current, strips the overlap
- If the entire new transcript is a repeat, it's dropped entirely
- Cleared on transcription start/stop

### 6. Voiceprint Echo Suppression (SpeakerIdentifier.swift + agent_service.dart)
- `SpeakerIdentifier.processAudioSegment()` now sets `lastMicIsAgentVoice` when mic audio matches the agent's TTS voiceprint
- `speakerInfo()` now returns `isAgentVoice` and `hasAgentVoiceprint` fields
- `AudioTapChannel.flushBuffers()` now feeds mic audio to SpeakerIdentifier in direct mode (previously only in call mode)
- `_initLocalSttPath()` now initializes SpeakerIdentifier and loads known speaker embeddings
- `_processTranscript()` checks `isAgentVoice` flag and drops the transcript if it matches the agent's voice

### Phase 2 Fixes (first-word clipping & stale voiceprint suppression)

### (Phase 2.1) Loop-Breaker Redesign (agent_service.dart)
- **Critical fix**: Loop-breaker now blocks AGENT OUTPUT instead of USER INPUT
- Previously: dropped user transcripts like "Testing." when consecutive counter was high — blocking the user
- Now: suppresses TTS generation and discards the response when the agent has responded 3+ times without user input
- User transcripts always flow through to `_processTranscript` and reset the counter
- TTS start is also suppressed (not just the final response) so no audio plays
- Threshold raised from 2 → 3 to avoid false triggers

### 7. Smart Carry-Over (WhisperKitChannel.swift)
- Added `lastTranscriptWasEmpty` flag that tracks whether the previous transcription was silence/hallucination
- When previous was silence, carry-over buffer is **cleared** instead of prepended — stale silence audio no longer poisons the next window's transcription, preventing the first real word from being stripped by dedup
- Added `isLikelyHallucination()` method to detect bracketed tags, known silence phrases, and empty/short text at the native level
- Dedup is now **skipped entirely** when the previous transcript was a hallucination — only dedup between consecutive real-speech windows
- Hallucinations are still emitted to Flutter for Dart-side filtering but no longer update `lastTranscriptText`

### 8. Time-Gated Voiceprint Echo Check (SpeakerIdentifier.swift + agent_service.dart)
- `lastMicIsAgentVoice` now records a timestamp (`lastMicAgentVoiceTime`) when set
- New `isMicRecentlyAgentVoice` property only returns true if the flag was set within 2 seconds
- `speakerInfo()` uses the time-gated check instead of the raw flag
- `AudioTapChannel.schedulePlaybackEnd()` now calls `SpeakerIdentifier.clearAgentVoiceFlag()` when TTS finishes — prevents stale voiceprint flags from suppressing real user speech that arrives 3+ seconds later
- Dart-side `_processTranscript` now double-gates the voiceprint check: only suppresses if `isTtsPlaying` or within `_effectiveEchoGuardMs` of speaking end — speech like "You're not." or "It's Gus." arriving 2.5s+ after TTS is no longer falsely suppressed

### 9. WhisperKit Timer Reset on Playback End (WhisperKitChannel.swift + agent_service.dart)
- The 1500ms transcription timer fires on a fixed schedule regardless of when TTS ends
- If the timer fires too soon after the gate opens (< 1s of audio accumulated), the audio is put back and waits another full 1.5s cycle — total wait up to 2.4s
- New `notifyPlaybackEnded` method on WhisperKitChannel resets the timer when TTS playback ends
- Called from the playback-end debounce in agent_service.dart via WhisperKitSttService
- Guarantees the first post-TTS processing happens exactly 1.5s after the gate opens with a full buffer
- Consistent ~1.5s latency instead of variable 1.0–2.4s

### 10. Hardened Echo Suppression (AudioTapChannel.swift + agent_service.dart)
- Native `suppressionSeconds` increased from 0.30s to 0.75s — the primary defense against echo; discards the most reverb-contaminated mic audio at the hardware level before it reaches WhisperKit
- `_isEchoOfAgentResponse` word overlap now strips punctuation before comparison (e.g. "clear," matches "clear") — fixes false negatives that let echo transcripts through
- Word overlap threshold lowered from 0.40 to 0.35 for broader echo catch
- Loop breaker reset now requires 6+ words (was 4) — typical agent echo fragments are 4–5 words and no longer unlock the breaker

### 11. Aggressive Loop Breaker (agent_service.dart)
- `_maxConsecutiveAgentResponses` lowered from 2 to 1 — the agent can respond ONCE after user speech, then the breaker engages immediately
- Counter resets when a transcript has 4+ words OR any words arrive 3+ seconds after TTS ended
- Loop breaker suppression no longer calls `stopResponseAudio`/`clearTTSQueue` when TTS isn't playing — prevents native `onPlaybackComplete` from flushing user audio
- Short transcripts that won't unlock the breaker skip the LLM call entirely
- Text echo detection (`_isEchoOfAgentResponse`) runs unconditionally — the 35% word-overlap threshold with punctuation stripping is selective enough to avoid false positives

### 12. WhisperKit Buffer Flush on TTS End (WhisperKitChannel.swift + agent_service.dart)
- `notifyPlaybackEnded` flushes the entire audio buffer AND carry-over buffer before resetting the timer — ensures WhisperKit starts transcribing with only clean post-TTS audio
- `flushAudioBuffer` method (flush-only, no timer reset) kept as a safety net
- Dart `WhisperKitSttService` exposes `flushAudioBuffer()` as a method channel bridge

### 13. Eliminate Ghost onPlaybackComplete Events (AudioTapChannel.swift + agent_service.dart)
- **Root cause**: `AVAudioPlayerNode.scheduleBuffer` fires a per-buffer completion callback. With 3 audio chunks per TTS response, 3 completion callbacks fire sequentially. Each intermediate callback started a 0.15s timer that sent `onPlaybackComplete` to Flutter before the remaining buffers finished — producing "ghost" events spaced ~1.6s apart
- Between ghost events, native mic suppression expired and re-engaged, creating gaps where 42-47KB of echo-contaminated audio leaked into the WhisperKit buffer. WhisperKit hallucinated speech from this leaked audio, which reset the loop-breaker counter and restarted the self-talk cycle
- **Fix**: Added `pendingBufferCount` in `AudioTapChannel.swift`. Incremented when `handlePlayAudio` queues a buffer, decremented in the `scheduleBuffer` completion callback. `schedulePlaybackEnd()` only fires when count reaches zero — exactly ONE `onPlaybackComplete` per TTS response
- Reset in `stopPlayback()` and `clearTTSQueue` for clean state
- Removed the Dart-side ghost guard (`_lastGhostFlushTime`, ghost flush logic) from `agent_service.dart` — no longer needed since ghosts don't occur
- Simplified counter reset in `_processTranscript` to use `_speakingEndTime` directly instead of the more complex `echoWindowEnd` calculation

## Files

### Modified
- `phonegentic/lib/src/agent_service.dart` — hallucination filtering, loop breaker, adaptive echo guard, time-gated voiceprint echo check, punctuation-normalized echo detection
- `phonegentic/lib/src/whisper_realtime_service.dart` — `_ttsEchoCooldownMs` tuned (300→800→300ms) as other defenses matured
- `phonegentic/macos/Runner/AudioTapChannel.swift` — post-playback suppression tuned (0.20→0.50→0.30→0.75s), feed mic to SpeakerIdentifier in direct mode, clear agent voice flag on playback end, `pendingBufferCount` to eliminate ghost `onPlaybackComplete` events
- `phonegentic/macos/Runner/WhisperKitChannel.swift` — smart carry-over (clear on silence), hallucination-aware dedup, native hallucination detection, timer reset on playback end
- `phonegentic/lib/src/whisperkit_stt_service.dart` — added `notifyPlaybackEnded()` method channel bridge
- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — time-gated `isMicRecentlyAgentVoice`, `clearAgentVoiceFlag()`, enriched `speakerInfo()` response

### Created
- `readmes/bugs/whisperkit-hallucination-feedback-loop.md` — this file
