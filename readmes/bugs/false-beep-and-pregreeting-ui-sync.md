# False Beep Detection on Human Speech & Pre-Greeting UI Desync

## Problem

Three related issues during outbound calls when a real person answers:

1. **False beep detection on speech** — The native Goertzel tone detector triggered "Beep tone DETECTED" on Lee's voice when he answered. Male voices with strong fundamental harmonics near 440/480 Hz were misidentified as voicemail beeps, causing the agent to switch to voicemail mode mid-conversation.

2. **Pre-greeting text appears before TTS plays** — `_flushPreGreeting()` added the full greeting text to the agent panel immediately, then started TTS generation asynchronously. The user saw text with no audio for ~200–500 ms, and if TTS was interrupted (e.g. by the false beep), the text was visible but never spoken.

3. **Missing speaking animation** — Because the false beep interrupted TTS before significant audio played, the waveform bars and "Speaking" status never activated. The root cause was the false beep, but the immediate text display without voice hold made it worse.

## Solution

### 1. Tighter Goertzel thresholds (`WebRTCAudioProcessor.swift`)

- **Energy concentration**: Raised from 60% → **80%**. Real voicemail beeps are pure sinusoids (>90% energy at one frequency); speech spreads energy across multiple harmonics.
- **Sustain requirement**: Raised from 40 frames (400 ms) → **80 frames (800 ms)**. Human vowels can sustain 400 ms at a single pitch, but voicemail beeps are typically 0.5–2 seconds of perfectly stable tone.

### 2. Voice hold on pre-greeting (`agent_service.dart`)

`_flushPreGreeting()` now uses the same `_voiceHoldUntilFirstPcm` mechanism as the streaming response path:
- Creates the chat message with **empty text** and `isStreaming: true`
- Buffers the display text in `_voiceUiBuffer`
- Sets `_voiceFinalPending = true` so the first PCM chunk both reveals the text and finalizes the message
- 8-second safety timeout force-releases text if TTS never produces audio

This ensures text + waveform animation appear simultaneously when audio starts playing.

### 3. Expanded Whisper hallucination filter (`agent_service.dart`)

- Added `[BEEP]`, `[RING]`, `[TONE]`, `[dial tone]`, `[busy signal]`, `[phone ringing]`, `[crickets chirping]`, `[inaudible]` to the bracketed tag regex — these were passing through as valid transcripts during settle and being classified as "human speech".
- Regex now matches both `[tag]` and `(tag)` formats since WhisperKit uses both.
- Added `_whisperParenPrefixRe` to strip leading parenthetical artifacts from otherwise-valid transcripts, e.g. "(crickets chirping) Yes" → "Yes".

## Files

| File | Change |
|------|--------|
| `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` | Raised Goertzel energy threshold (0.60 → 0.80) and sustain frames (40 → 80) |
| `phonegentic/lib/src/agent_service.dart` | Voice hold on pre-greeting; expanded hallucination filter with `[BEEP]` et al; parenthetical artifact stripping |
