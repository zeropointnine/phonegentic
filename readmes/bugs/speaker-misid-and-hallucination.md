# Speaker Misidentification & Transcript Hallucination

## Problem

Two related bugs observed during use:

1. **Host labeled as contact**: During calls and in direct mode, the host's (Patrick's) speech gets labeled with a contact name ("Jon Siragusa") in the transcript UI. Root causes:
   - SpeakerIdentifier correctly ignores contact matches on mic audio, but then **returns without setting any identity** — `identifiedHostSpeaker` stays empty forever, since the contact always wins `assignSpeaker`.
   - In direct mode (no call), `dominantSpeaker` is never updated from its initial `"unknown"` value because the RMS-based detection only runs in the call-mode flush path.

2. **Garbled transcript (WhisperKit hallucination)**: Repetitive numeric loops like "1, 2, 3, 1, 2, 3, 1, 2, 3" slip through the hallucination filter because `_isRepeatedWordHallucination` discards words with `length <= 1` — single digits are invisible to the detector.

## Solution

### Speaker identification fixes

- **SpeakerIdentifier.swift**: When a mic→contact match is ignored, explicitly check the `host_user` voiceprint as a fallback. If cosine similarity is reasonable (≥ 0.5), assign it as the host identity. This ensures `identifiedHostSpeaker` gets populated even when a contact embedding is closer.
- **AudioTapChannel.swift**: In direct mode, always set `dominantSpeaker = "host"` since all audio comes from the mic.

### Hallucination filter fix

- **agent_service.dart**: In `_isRepeatedWordHallucination`, lower the word-length threshold from `> 1` to `> 0` so single-digit numbers and single-letter words participate in repetition detection. Also add cyclic repetition detection (period ≤ 4, repeated 2+ full cycles).

## Files

- `phonegentic/macos/Runner/SpeakerIdentifier.swift` — host_user fallback on mic
- `phonegentic/macos/Runner/AudioTapChannel.swift` — direct mode dominant speaker
- `phonegentic/lib/src/agent_service.dart` — hallucination filter
