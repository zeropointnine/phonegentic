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

### 3. Increased TTS Echo Cooldown
- **Dart (whisper_realtime_service.dart)**: `_ttsEchoCooldownMs` raised from 300ms → 800ms — the window after `isTtsPlaying` goes false where mic audio is still suppressed from feeding WhisperKit
- **Native (AudioTapChannel.swift)**: Post-playback suppression raised from 0.20s → 0.50s, and playback-end timer from 0.10s → 0.15s — more reverb tail is discarded before mic audio resumes flowing to Flutter

### 4. Adaptive Echo Guard (agent_service.dart)
- Added `_speakingStartTime` tracking across all 3 TTS backends (ElevenLabs, Kokoro, Pocket)
- New `_effectiveEchoGuardMs` getter computes guard based on speaking duration:
  - < 2s spoken → 800-1200ms guard (50% of base)
  - 2-4s spoken → 75% of base
  - > 4s spoken → full 2000ms guard
- Applied to `_onTranscript`, `_flushPendingTranscripts`, and text-echo-check window
- User can now reply quickly to short questions without being muted

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

## Files

### Modified
- `phonegentic/lib/src/agent_service.dart` — hallucination filtering, loop breaker, adaptive echo guard, voiceprint echo check
- `phonegentic/lib/src/whisper_realtime_service.dart` — increased `_ttsEchoCooldownMs` 300ms → 800ms
- `phonegentic/macos/Runner/AudioTapChannel.swift` — increased post-playback suppression, feed mic to SpeakerIdentifier in direct mode
- `phonegentic/macos/Runner/WhisperKitChannel.swift` — reduced carry-over, added transcript dedup
- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — exposed `lastMicIsAgentVoice`, enriched `speakerInfo()` response

### Created
- `readmes/bugs/whisperkit-hallucination-feedback-loop.md` — this file
