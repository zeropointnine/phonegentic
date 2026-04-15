# Call Interruption & Speaker Attribution Bugs

## Problem

During live phone calls, three related issues degraded conversation quality:

1. **False barge-in interruptions** — The AI agent was being interrupted by subtle ambient sounds and noise. The VAD (Voice Activity Detection) fast path had only a 300ms debounce and no speech substance check, so any sound triggering OpenAI's server VAD while TTS was playing would kill the agent's audio after just 300ms.

2. **Whisper hallucinations triggering interrupts** — The server VAD threshold (0.5) was too sensitive, causing noise to be sent to Whisper for transcription. Whisper would hallucinate text like "Vous dites ?", "Ja, ja.", "Hallo?" on ambient noise, which then triggered barge-in interrupts and confused the LLM conversation context.

3. **Speaker attribution chaos** — The SpeakerID system bounced between identities (e.g., "Ron Pastore" → "Patrick Lemiuex" → "+18002211212" for remote, "Lee" → "Zach" → "Luis Baro" → "Speaker 1" for host). Root causes: dominant speaker ties defaulted to "remote", the smoothing window was too short (3s), and SpeakerIdentifier overwrote identity on every 3s embedding chunk with no hysteresis or minimum confidence.

## Solution

### VAD sensitivity (whisper_realtime_service.dart)
- Raised server VAD `threshold` from `0.5` to `0.65` — reduces false triggers on ambient noise while still detecting genuine speech.

### Barge-in debounce (agent_service.dart)
- Increased VAD barge-in debounce from 300ms to 600ms — short noise bursts that don't persist are filtered out. The speech_stopped event cancels the timer, so genuine speech that stops quickly never fires.

### Whisper hallucination filter (agent_service.dart)
- Added `_isWhisperHallucination()` static method with a regex matching common hallucination patterns (non-English phrases, subtitle credits, very short utterances).
- Applied at the top of `_onTranscript` to drop hallucinated text before it can trigger barge-in or be processed as real speech.

### Dominant speaker stability (AudioTapChannel.swift)
- Changed tie-breaking from `>=` (favoring remote) to strict `>` — ties now resolve to "unknown" instead of arbitrarily picking "remote".
- Increased smoothing window from 30 flushes (3s) to 50 flushes (5s) for more stable dominant speaker tracking.

### Speaker identity locking (SpeakerIdentifier.swift)
- Added minimum confidence threshold (0.6) — low-confidence matches are completely ignored and reset the consecutive-hit counter.
- Added lock mechanism — once the same speaker is identified twice consecutively at ≥0.75 confidence, the identity is locked for the rest of the call. No further re-identification happens on that channel. `reset()` clears locks between calls.
- This prevents the first noisy embedding (from ringing tones / call setup audio) from permanently misidentifying the speaker, since a single garbage match can't lock — the same name must appear in two consecutive 3-second windows.

### IVR length heuristic eating real conversation (ivr_detector.dart)
- The length heuristic classified any ≥15-word utterance without a greeting keyword ("hello", "hi") as IVR. This caused real mid-conversation responses (e.g. "At the time that I stole my parents' car...") to be dropped by the post-settle `isIvr()` filter.
- Changed the length-only heuristic from returning `CallPartyType.ivr` to `CallPartyType.ambiguous`. Only keyword matches should classify as IVR; length alone is not a reliable signal outside the settle phase.

### Whisper hallucinations in non-English (agent_service.dart)
- Added CJK/Cyrillic/Arabic/Thai script detection (`_nonLatinRe`) to the hallucination filter. Whisper hallucinates Korean (여기라고?), Japanese, Chinese text when it hears noise on English calls.

## Files

- `phonegentic/lib/src/whisper_realtime_service.dart` — VAD threshold 0.5 → 0.65
- `phonegentic/lib/src/agent_service.dart` — VAD debounce 300→600ms, hallucination filter (incl. non-Latin), comment update
- `phonegentic/lib/src/ivr_detector.dart` — length heuristic no longer classifies as IVR
- `phonegentic/macos/Runner/AudioTapChannel.swift` — dominant window 30→50, tie→unknown
- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — lock mechanism with consecutive-hit requirement
