# Whisper Hallucination Feedback Loop in Idle Mode

## Problem

In idle mode (no call active), WhisperKit continuously processes ambient mic audio and hallucinates religious/gratitude phrases — "Thank God. Thank God, thank God. Thank the Lord. Thank the Holy One." — which are a well-known Whisper artifact on silence/noise.

The existing hallucination filter catches the exact-match and cyclic-repetition patterns, but variants with enough unique words slip through:
- "Thank the Holy One." (4 unique words, no repetition)
- "Thank God for the you and" (6 unique words)
- "- Thanking. - Thank you." (3 unique words)
- "You. Thank you for watching." (classic YouTube-outro hallucination)

These surviving hallucinations get sent to the TextAgent, which generates real responses. The TTS audio then feeds back into the mic, producing more hallucinations — a feedback loop.

### Secondary issues in the same logs

1. **`StreamController` crash**: `WhisperKitSttService.dispose()` closes the controller, but native events arriving afterwards trigger `add()` on the closed controller → `Bad state: Cannot add new events after calling close`.

2. **Comfort noise `stopPlayback` spam**: Every TTS audio chunk calls `comfortNoiseService.stopPlayback()`, producing dozens of "not playing" log lines per response.

## Solution

### Fix 1: Vocabulary-based hallucination filter

Added `_hallucinationVocab` — a set of words that dominate Whisper's noise hallucinations (thank, god, lord, holy, amen, watching, subscribing, etc. plus common function words). `_isVocabHallucination()` checks if ≥ 85% of words come from this set. This catches the religious phrases without flagging real speech like "Why are you hallucinating?" or "I'm watching the voice to see what's going on here."

Hyphens are now split into spaces before tokenizing so "Thank-you" correctly becomes two vocab words.

### Fix 2: Stream controller guard

Added `_transcriptionController.isClosed` check before `.add()` in the native event listener, preventing the crash when dispose races with pending events.

### Fix 3: Comfort noise deduplication

Wrapped all four TTS chunk listener `stopPlayback()` calls with `if (comfortNoiseService?.isPlaying ?? false)` so the stop is only called when comfort noise is actually active, eliminating the log spam.

## Files

- `phonegentic/lib/src/agent_service.dart` — added `_hallucinationVocab`, `_isVocabHallucination()`, wired into `_isWhisperHallucination()`; guarded comfort noise stop calls with `isPlaying` check
- `phonegentic/lib/src/whisperkit_stt_service.dart` — added `isClosed` guard before `_transcriptionController.add()`

---

## Phase 2 — YouTube-outro escape & suppression at the source

### New symptoms

After Phase 1 landed, two problems remained:

1. **YouTube-outro hallucinations escaped the filter and triggered real side effects.**
   When the user said "Can you send me a text?", Whisper *also* transcribed a silence-hallucination as "Thank y all for watching! Please subscribe!" on the very next tick. The LLM combined the two inputs and called `send_sms` with the hallucinated text as the message body — the SMS was actually delivered to the user's real contact.

   The vocab filter missed it because "please", "y", "all", "subtitles" weren't in the vocab, and the 85% threshold meant phrases with a few unknown tokens slipped through (4/7 = 57%).

2. **Hallucination-prefix escape.** Transcripts like `"Thank God. Thank god. That's what I'm talking 'tis."` reached the TextAgent because the "thank god thank god" prefix was diluted by nonsense appended tokens ("That's what I'm talking 'tis"), dropping the vocab ratio below 85%.

3. **Volume of hallucinations.** Dozens of "Thank God. Thank God…" dropped per minute indicates WhisperKit is transcribing near-silence constantly. The filter catches them but the log is noisy and every tick is wasted compute.

### Fixes

**A. YouTube-outro regex (`_youtubeOutroRe`)** — explicit pattern match for the iconic Whisper-from-silence phrases: "thanks for watching", "please subscribe", "like and subscribe", "hit the bell", "see you next time", "subtitles by …". Runs before the vocab-ratio check inside `_isVocabHallucination`.

**B. Hallucination-prefix regex (`_hallucinationPrefixRe`)** — if a transcript *starts* with a signature loop ("Thank God. Thank God", "Thank you. Thank you", "You. You. You.", "Thank the Lord"), the entire line is dropped regardless of what's tacked on the end. Whisper often appends real-sounding garbage to its loops; the prefix alone is diagnostic.

**C. Expanded vocabulary** — added `please`, `y`, `yall`, `yknow`, `subtitles`, `captions`, `channel`, `video`, `videos`, `content`, `hit`, `bell`, `everyone`, `guys`, `today`, `forget`, `all`, `my`, `your` so the ratio check catches remaining YouTube/gratitude variants.

**D. WhisperKit threshold tuning** (macOS `WhisperKitChannel.swift`) — kill hallucinations at the source using Whisper's built-in confidence gates:

| Knob | Old (default) | New | Effect |
|---|---|---|---|
| `noSpeechThreshold` | 0.6 | 0.4 | Drop when model's no-speech prob > 0.4 (stricter) |
| `logProbThreshold` | -1.0 | -0.6 | Require higher avg token log-prob |
| `compressionRatioThreshold` | 2.4 | 1.8 | Drop repetitive sequences like "Thank God. Thank God. Thank God." |

These directly target silence-hallucinations (low no-speech, low confidence) and looping ones (high compression ratio).

### Files (Phase 2)

- `phonegentic/lib/src/agent_service.dart` — added `_youtubeOutroRe`, `_hallucinationPrefixRe`; expanded `_hallucinationVocab`; both regexes run before the vocab-ratio check
- `phonegentic/macos/Runner/WhisperKitChannel.swift` — tightened `noSpeechThreshold`, `logProbThreshold`, `compressionRatioThreshold`
