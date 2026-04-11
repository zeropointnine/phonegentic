# Streaming TTS at Sentence Boundaries

## Problem

When Claude responds to a user, the full LLM response can take 3-10+ seconds to
stream. The original implementation waited for the **entire response** before
synthesizing speech, creating a long silence gap between the user's question and
the agent's audible reply.

This is especially painful with **Kokoro** (on-device TTS), which buffers all
text in `sendText()` and only synthesizes on `endGeneration()`. ElevenLabs was
better (streaming at 50-char thresholds) but used a naive sentence-end check
that false-triggered on abbreviations like "Mr." and "D.C."

## Solution

Port the streaming sentence-segmentation pattern from
[tts-toy](https://github.com/zeropointnine/tts-toy) into Dart. Instead of
waiting for the full response, detect sentence boundaries in the streaming text
deltas and synthesize each sentence independently.

### Architecture

```
Claude SSE deltas
       |
       v
  TextSegmenter  (buffers deltas, detects sentence endings)
       |
       v  (list of complete sentences/phrases)
       |
  +----+-----+
  |          |
  v          v
Kokoro    ElevenLabs
(queue)   (flush to WS)
```

Audio starts after the **first sentence** (~0.5-2s) instead of after the
**entire response** (~3-10s).

## Key Files

### `phonegentic/lib/src/text_segmenter.dart` (new)

Streaming sentence boundary detector. Core API:

- **`addText(chunk) -> List<String>`**: Feed a streaming delta, get back any
  complete sentences detected. Returns empty list if still mid-sentence.
- **`flush() -> String?`**: Return remaining buffer when the stream ends.
- **`reset()`**: Clear state for a new generation.

Sentence detection rules:
- Splits on `.` `?` `!` `...` `…` followed by whitespace
- Skips abbreviations: Mr., Mrs., Dr., Prof., Sr., Jr., St., vs., etc., e.g.,
  i.e., single-capital-letter initials (A. B. C.)
- Long sentences (>25 words) are split into phrases at `, ; :` nearest the
  midpoint, inspired by tts-toy's `sentence_segmenter.py`
- **Overflow flush:** if the buffer exceeds 25 words without any sentence
  terminator (e.g. poems, lists with colons), force-splits at the nearest
  phrase boundary so TTS doesn't stall waiting for punctuation

### `phonegentic/lib/src/kokoro_tts_service.dart` (rewritten)

The big latency improvement. Changed from "buffer everything, synthesize once"
to a **sentence queue pipeline**:

1. `sendText()` feeds deltas into `TextSegmenter`
2. Complete sentences go into `_sentenceQueue`
3. `_synthesizeLoop()` processes the queue serially — each sentence calls the
   native `synthesize` method independently
4. Audio chunks from each sentence emit via EventChannel as before
5. Pipeline overlap: while sentence N's audio plays through AudioTap, sentence
   N+1 is synthesizing on the native side

`endGeneration()` flushes the segmenter remainder into the queue and awaits a
`Completer` that resolves when the queue drains.

### `phonegentic/lib/src/elevenlabs_tts_service.dart` (minor change)

Replaced the naive `_hasSentenceEnd` (checked last char of delta for `. ? ! ;`)
with `TextSegmenter`-based detection. Keeps the 50-char `_minFlushChars`
threshold for fast time-to-first-audio since ElevenLabs handles its own
server-side buffering via `chunk_length_schedule`.

### `phonegentic/lib/src/models/agent_context.dart` (minor change)

Added a "Voice mode" output section to the agent's system instructions so the
model knows its text is spoken aloud, it can hear via transcription, and it
should write conversationally with short sentences.

### `phonegentic/lib/src/agent_service.dart` (modified)

Orchestrates the voice-hold and TTS integration:

- **Markdown flattening** (`_flattenMarkdownForTtsDelta`): strips `**`, `__`,
  backticks, and headings from text deltas before sending to TTS so the
  synthesizer doesn't read formatting aloud. Paragraph breaks (`\n\n`) become
  `. ` to act as sentence boundaries — this prevents long introductions or
  poem stanzas from accumulating into a single oversized first segment.
- **Voice-hold buffer**: when the split pipeline is active (`_splitPipeline &&
  _hasTts && !_ttsMuted`), Claude deltas accumulate in `_voiceUiBuffer` while
  `ChatMessage.text` stays `""`. The first TTS PCM chunk triggers release.
- **Kokoro warmup**: calls `warmUpSynthesis()` after voice initialization to pay
  the MLX cold-start cost before the first real utterance.

### `phonegentic/macos/Runner/KokoroTtsChannel.swift` (modified)

Added a `warmup` method handler that performs a discarded synthesis of `"."` on
the background queue, pre-loading the MLX model and voice embedding so the first
real call is fast.

### `phonegentic/lib/src/widgets/streaming_typing_text.dart` (new)

Typewriter-reveal widget for agent chat bubbles. See [Chat UI sync](#chat-ui--voice--tts-sync-not-text-only) below.

### `phonegentic/lib/src/widgets/agent_panel.dart` (modified)

Always uses `StreamingTypingText` for agent message bubbles (both during and
after streaming) so the typewriter animation survives the `isStreaming → false`
transition without snapping to full text.

## No Other Changes Required

- **`KokoroTtsChannel.swift` synthesize path**: The native synthesize method
  already works for arbitrary text lengths; we just call it multiple times with
  smaller chunks.
- **AudioTap / playback pipeline**: Unchanged — PCM chunks arrive the same way.

## Performance

| Provider    | Before                        | After                          |
|-------------|-------------------------------|--------------------------------|
| Kokoro      | Wait for full response (3-10s)| First sentence audio (~0.5-2s) |
| ElevenLabs  | Occasional stutter on abbrevs | Cleaner sentence-aligned flush |

No additional API costs — same total text synthesized, just chunked differently.

## Reference

The sentence segmentation approach is adapted from:
- [`text_segmenter.py`](https://github.com/zeropointnine/tts-toy/blob/main/text_segmenter.py) — pysbd-based streaming sentence detection
- [`sentence_segmenter.py`](https://github.com/zeropointnine/tts-toy/blob/main/sentence_segmenter.py) — phrase splitting for long sentences

We ported the concepts to Dart without the `pysbd` dependency, using a
regex-based abbreviation matcher and character-scanning approach instead.

## Chat UI — voice / TTS sync (not text-only)

Two layers work together so text and speech appear synchronized:

### Layer 1: Voice hold (`agent_service.dart`)

When the **split pipeline** is active (Claude text agent + Kokoro or ElevenLabs),
TTS is enabled and not muted, and TTS is not suppressed for IVR phases:

- Claude deltas accumulate in `_voiceUiBuffer`; `ChatMessage.text` stays `""`.
- On the **first TTS PCM chunk**, `_releaseVoiceUiIfWaitingForTts` (called from
  both Kokoro and ElevenLabs audio listeners before `playResponseAudio`) copies
  the buffer into `ChatMessage.text` and clears the hold flag.
- Subsequent deltas append to `message.text` normally.
- **`isFinal` respects the hold:** if Claude finishes streaming before the first
  PCM arrives (common for short/fast responses), the final text stays in
  `_voiceUiBuffer` and a `_voiceFinalPending` flag is set. The PCM listener
  finalizes the message (`isStreaming = false`) when audio actually starts. An
  8-second safety timer force-releases if TTS never produces audio.

With **no TTS** (text-only / provider none) or **TTS muted**, text updates
immediately on every delta — no hold.

### Layer 2: Typewriter reveal (`StreamingTypingText` widget)

When the hold releases, `message.text` jumps from `""` to all buffered text in
one frame. A plain `Text` widget would show that as a wall of text appearing
instantly.

[`StreamingTypingText`](../../phonegentic/lib/src/widgets/streaming_typing_text.dart)
is used for **all** agent bubbles (via `agent_panel.dart`). It tracks a
`_revealed` character count and advances it on a periodic timer with fixed
(non-proportional) rates. The speed adapts via the **`voiceSync`** flag
(driven by `AgentService.ttsActiveForUi`):

| Mode | Tick | Stream rate | Drain rate | 100 chars in |
|------|------|-------------|------------|--------------|
| **Voice sync** (TTS active) | 80 ms | 1 char/tick | 2 chars/tick | ~8 s |
| **Text-only** (muted / no TTS) | 40 ms | 4 chars/tick | 8 chars/tick | ~1 s |

- **Sentence boundary pause (voice sync only):** when the reveal cursor crosses
  a sentence-ending punctuation mark (`. ` `? ` `! ` followed by space/newline),
  the timer stops for 2 seconds before resuming. This keeps the text animation
  in lockstep with TTS audio, which has natural inter-sentence gaps while the
  next sentence synthesizes. Without this pause the text would race ahead of
  the audio during multi-sentence responses.
- **Steady state:** once caught up (`_revealed >= target`), the timer stops and
  restarts when new text arrives.
- **No snap on stream end:** the widget **does not** snap to full text when
  `isStreaming` transitions to false. This was a key bug fix — previously
  `agent_panel.dart` switched from `StreamingTypingText` to a plain `Text`
  widget on that transition, destroying the animation mid-reveal.
- **Dynamic switching:** if `voiceSync` changes mid-stream (e.g. user toggles
  mute), the timer restarts at the new cadence.

Combined effect: with TTS active, the bubble is empty until audio begins, then
text "types in" at roughly speech pace. In text-only / muted mode, text appears
quickly with just enough animation to feel streamed rather than dumped.

## Reading Kokoro logs (latency)

From a typical trace:

1. **`[KokoroTTS] Generation started`** — first Claude delta arrived with speakable
   text; `startGeneration` ran.
2. **`Synthesizing sentence (N chars)`** (Dart) — `TextSegmenter` released the first
   queued phrase; native work is about to start.
3. **`[KokoroTTS] Synthesizing N chars...`** (native) — **first PCM is still not
   playing**. Swift calls `generateAudio` for the **entire** segment, then only
   then pushes chunks to the EventChannel. So time-to-first-audio includes **full
   first-segment synthesis** (often 1.5–3s on first cold inference, then faster).
4. **`Claude response final`** can appear **before** first audio finishes — the
   HTTP stream ends while Kokoro is still working through the sentence queue;
   `endGeneration` awaits that queue.

**Mitigations in tree:** after model load, native **`warmup`** runs a discarded
`.` synthesis to pay MLX cold-start once. TTS deltas also pass through
**markdown flattening** (`**`, headings, newlines) so the first segment is not
literally `**Perseus and…`.

## Bug fixes: text-only mode and per-job Kokoro voice

### Kokoro speaking in text-only mode

Two issues caused Kokoro to synthesize speech even when the job function had
`whisperByDefault = true` (text-only):

1. **`_buildTextAgentInstructions()`** only checked `_tts != null` (ElevenLabs)
   for the `hasTts` flag. With Kokoro as the provider `_tts` is null, so Claude
   was told "TEXT-ONLY mode" while the actual TTS feeding gate (`_hasTts`) still
   evaluated true (it checks `_tts != null || _kokoroTts != null`). Fixed to
   `(_tts != null || _kokoroTts != null) && !_ttsMuted && !_muted`.

2. **Idle transition after a call ended** unconditionally cleared `_ttsMuted`,
   ignoring the job function's `textOnly` setting. Added a `!_bootContext.textOnly`
   guard so text-only jobs stay muted between calls.

### Per-job-function Kokoro voice

Previously only ElevenLabs had a per-job voice override (`elevenLabsVoiceId`).
Added `kokoroVoiceStyle` through the full stack:

- **`JobFunction`** — new nullable `kokoroVoiceStyle` field (+ `toMap`/`fromMap`/`copyWith`)
- **DB migration** — version 11 → 12: `ALTER TABLE job_functions ADD COLUMN kokoro_voice_style TEXT`
- **`AgentBootContext`** — new `kokoroVoiceStyle` field
- **`JobFunctionService.buildBootContext()`** — passes through `jf.kokoroVoiceStyle`
- **`AgentService._syncFromJobFunctionIfNeeded()`** — calls `_kokoroTts!.setVoice()`
  on job function switch when an override is set
- **`job_function_editor.dart`** — Kokoro voice dropdown (shown when TTS provider
  is Kokoro), listing all `KokoroTtsService.voiceStyles` with a "Default (from
  settings)" fallback

### Mute button now suppresses TTS

Previously the Mute button (`toggleMute`) only stopped the microphone (`_muted` /
`_whisper.muted`). TTS output continued because the feeding gate only checked
`_ttsMuted`, which is the separate whisper-mode flag. Now:

- **TTS feeding gate** — `_appendStreamingResponse` checks `!_muted` alongside
  `!_ttsMuted`, so no text is sent to Kokoro/ElevenLabs while muted.
- **`toggleMute()`** — when muting in the split pipeline, immediately calls
  `_activeTtsEndGeneration()` to stop any in-progress synthesis.
- **Claude instructions** — `_buildTextAgentInstructions()` treats the agent as
  text-only when muted, so Claude writes for reading rather than speaking.

### Echo guard now tracks playback, not generation

The two-layer echo detection (time-based buffering + text-match filtering) relied
on `_speaking` and `_speakingEndTime`, which were set by the TTS service's
`speakingState` stream. That stream fires when **synthesis** finishes — but with
the sentence pipeline, AudioTap keeps playing queued PCM for several more
seconds after the last sentence is synthesized. Transcripts of the tail end of
the agent's own speech would arrive after the echo guard window had already
expired, causing the agent to "hear itself" and respond to its own words.

**Fix (both Kokoro and ElevenLabs):**

- **`speakingState` listener** — now only sets `_speaking = true` (opens the
  guard). It no longer closes the guard on `speaking = false`.
- **`onPlaybackComplete` debounce** — AudioTap fires this callback per buffer
  drain, not once at the true end of playback. A single response can produce
  playback-end events spanning 10–15 s after the first chunk finishes. The
  handler now uses a 2 s debounce timer (`_playbackEndDebounce`): each event
  resets the timer, keeping `_speaking = true` and `_whisper.isTtsPlaying = true`
  (mic suppressed) until 2 s after the **last** event. Only then does it set
  `_speaking = false`, record `_speakingEndTime`, update status text, set
  `_whisper.isTtsPlaying = false`, and trigger `_schedulePostSpeakFlush()`.

The echo guard now spans from first TTS generation through actual audio playback
end (debounced), plus the `_echoGuardMs` (2 s) cooldown. This applies uniformly
to Kokoro, ElevenLabs, and any future TTS provider.

### Mute ↔ unmute updates Claude instructions

`toggleMute()` now calls `_pushInstructionsIfLive()` so that Claude's system
prompt reflects the current TTS availability immediately after the user toggles
mute. Previously, Claude would remain in text-only mode after unmuting because
the instructions were only pushed on job function changes or reconnects.

### Waveform visualization during TTS playback

The `_WaveformPill` in the agent header was driven by `_whisper.audioLevels`,
which computes RMS from mic audio delivered via the native AudioTap
`EventChannel`. However, AudioTap's `flushBuffers()` guards the event sink with
`if isPlayingResponse { return }` — during TTS playback (and a 1 s post-playback
suppression), **no audio data reaches Flutter at all**, so the waveform went flat
whenever the agent spoke and stayed flat for the cooldown period afterward.

**Fix:** Dual-source level data, both computed in Dart (no native changes).
Works identically for ElevenLabs and Kokoro — both audio listeners call the
same `_pushTtsAudioLevel(pcm)`:

- **Mic levels** (user speaking) — unchanged `_levelSub` on
  `_whisper.audioLevels`, which fires whenever AudioTap's EventChannel delivers
  data (i.e. when TTS is NOT playing).
- **TTS levels** (agent speaking) — `_pushTtsAudioLevel(pcm)` slices each TTS
  audio chunk into 100 ms segments (2400 samples at 24 kHz), computes RMS for
  each, and pushes them into `_ttsLevelQueue`. A 100 ms periodic timer
  (`_ttsLevelTimer`) drains one value per tick into the `_levels` display queue.
  Because the drain rate matches the playback sample rate, the waveform
  animation closely tracks actual audio duration — e.g. 74 800 bytes of audio
  (~1.56 s) produces ~15 segments that drain over ~1.5 s.

### Speaking state tracks TTS level drain

The UI status ("Speaking" / green vs "Listening" / blue) previously relied on
`_speaking`, which is set by the `speakingState` listener (generation start) and
cleared by the debounced `onPlaybackComplete` callback. Because AudioTap fires
`onPlaybackComplete` per buffer drain — not once at the true end — the debounce
often resolved before all audio had played, causing the status to flip to
"Listening" while the agent was still audibly speaking.

**Fix:** The `speaking` getter now includes the TTS level drain as a signal:

```dart
bool get speaking => _speaking || _ttsLevelTimer != null;
```

The `_ttsLevelTimer` runs as long as `_ttsLevelQueue` has segments to drain, and
each segment represents 100 ms of real audio. So the "Speaking" state persists
for the full playback duration regardless of when `_speaking` clears. When the
queue empties, the timer stops, `_ttsLevelTimer` goes null, `speaking` returns
false, and `notifyListeners()` triggers the UI to switch to "Listening".

This is provider-agnostic — both ElevenLabs and Kokoro audio listeners call
`_pushTtsAudioLevel`, and the same drain/timer logic applies to both.
