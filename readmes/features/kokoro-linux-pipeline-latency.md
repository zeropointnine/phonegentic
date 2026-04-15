# Kokoro TTS Latency — Linux Pipeline

This document explains why TTS audio starts noticeably later than text on Linux,
where latency is produced, and what has been done (and what can still be done) to
reduce it.

---

## The problem

On Linux, when the agent responds, the chat bubble starts filling with text
immediately but the Kokoro voice starts speaking 1000–1400 ms later. This gap is
inherent to a batch ONNX pipeline but is significantly reducible.

---

## Latency chain

```
First LLM delta arrives
        │
        ├─ UI update: text starts printing            [0 ms — immediate]
        │
        └─ TextSegmenter begins accumulating deltas
               │
               │  (waiting for sentence terminator: . ? ! …)
               │
        Sentence boundary detected                   [+100–400 ms]
               │  (depends on LLM speed and length of opening sentence)
               │
        invokeMethod('synthesize', text)
               │  platform channel dispatch           [~1 ms]
               │
        ── native thread spawned ──────────────────────────────────────
               │
        espeak-ng phonemize(text)                    [~20–50 ms]
               │
        ONNX session.Run()    ← primary bottleneck
               │  full forward pass over whole sentence
               │  (non-autoregressive: no partial output possible)
               │
        float32 → PCM16 conversion                   [~5 ms]
               │
        g_idle_add → deliver all PCM chunks at once  [~1 ms GLib tick]
        ── main thread ─────────────────────────────────────────────────
               │
        EventChannel → audioChunks → playResponseAudio()
               │
        PulseAudio buffer → speaker                  [~50–100 ms]
               │
        FIRST AUDIO                                  [total: ~1100–1400 ms]
```

---

## Why each cost exists

### Sentence boundary wait

`KokoroTtsService.sendText()` pipes each LLM delta into `TextSegmenter`, which
only releases a synthesis-ready chunk when it detects a sentence terminator
(`.?!…`) followed by whitespace, or when the buffer overflows `maxWords = 25`.

No synthesis call is made until the first chunk is released. For typical Claude
responses that open with a short sentence ("Sure! I can help with that."), this
wait is 100–200 ms. For longer opening phrases ("Let me walk you through how
this works in more detail:"), it runs to 300–400 ms before the 25-word overflow
triggers a phrase split.

### ONNX inference (the primary bottleneck)

Kokoro is a non-autoregressive TTS model (based on StyleTTS2). Its ONNX
`session.Run()` call performs a single forward pass over the entire tokenised
sentence and returns **all** audio samples at once. There is no way to stream
audio out of a single inference call — audio arrives in a burst only after
synthesis is 100% complete.

Before the fix, the session was configured with:

```cpp
impl_->session_opts.SetIntraOpNumThreads(1);
```

This pinned every matrix multiplication and attention operation inside the
82M-parameter model to a single CPU core. On a mid-range machine a 2-second
sentence took 700–900 ms to synthesize.

### PCM delivery (not a bottleneck)

`deliver_synth_result_idle` sends all PCM chunks synchronously in a loop on the
GLib main thread via `g_idle_add`. All chunks arrive in Dart in one event-loop
tick; `playResponseAudio()` is called on the first chunk immediately. Audio
playback does not wait for subsequent chunks or for the `invokeMethod` future to
resolve — EventChannel events arrive independently of the MethodChannel response.

---

## Fix applied

**File:** [linux/runner/kokoro_onnx_engine.cc](../../phonegentic/linux/runner/kokoro_onnx_engine.cc)

```cpp
// Before
impl_->session_opts.SetIntraOpNumThreads(1);

// After
impl_->session_opts.SetIntraOpNumThreads(0);  // let ORT use hardware_concurrency
```

Setting to `0` tells ONNX Runtime to auto-configure intra-op parallelism based
on the number of physical cores. On a 4-core machine the dominant matrix
operations run ~3-4× faster; on 8 cores, ~5-6×. Inference time drops from
700–900 ms to roughly 200–350 ms for the same sentence.

Rebuild required (`fvm flutter build linux`). After rebuilding, each synthesis
call logs:

```
[KokoroOnnx] Audio output: 48012 samples, infer=214 ms
```

Compare that figure before and after the change.

---

## Expected result

| Phase | Before fix | After fix |
|---|---|---|
| Sentence boundary wait | 100–400 ms | unchanged |
| ONNX inference (2 s sentence) | 700–900 ms | 200–350 ms |
| Delivery + PulseAudio | ~100 ms | unchanged |
| **Total first-audio latency** | **~1100–1400 ms** | **~400–650 ms** |

---

## Remaining irreducible latency

~300–400 ms of latency remains after the fix and cannot be eliminated without
architectural changes:

- **Sentence boundary**: ~100–200 ms to stream a short opening sentence. Can be
  reduced by lowering `TextSegmenter.maxWords` (currently 25), but values below
  ~10 risk mid-phrase splits that sound choppy.
- **One ONNX pass**: the model must complete before any audio is available. This
  is a property of the non-autoregressive architecture. Shorter first sentences
  = faster first audio.
- **PulseAudio buffer**: ~50–100 ms fixed playback latency.

---

## Further levers (not yet applied)

### 1. Reduce `TextSegmenter.maxWords`

Lowering from 25 to 12–15 reduces the overflow threshold for long opening
phrases. The risk is choppy short phrases when no punctuation is available near
the midpoint; test on representative responses before committing.

```dart
// text_segmenter.dart
TextSegmenter({this.maxWords = 12});  // was 25
```

### 2. Per-session ONNX tuning

If inference is still slow on a specific machine, try adding:

```cpp
impl_->session_opts.SetInterOpNumThreads(2);
```

`InterOpNumThreads` controls parallelism across independent graph nodes. For a
mostly-sequential TTS graph this rarely helps, but is worth profiling.

### 3. Sentence splitting in C++ before synthesis

The current architecture splits text at the Dart level (TextSegmenter) and
synthesizes each segment serially. An alternative: let the native layer accept
a longer text, phonemize it in full, then run ONNX on smaller token sub-sequences
(split at word boundaries in the phoneme sequence) and stream partial audio
between sub-sequences. This would require significant native changes and
careful prosody handling.

### 4. ONNX quantization / smaller model

The Kokoro ONNX model is FP32. INT8 quantization (`OrtQuantizeLinear`) typically
halves inference time with minimal quality loss. Alternatively, the `ggml-tiny`
Kokoro variant (if it exists as ONNX) would synthesize faster at the cost of
voice quality.

---

## Reading the logs

```
[KokoroTTS] Generation started          ← first LLM delta; startGeneration() called
[KokoroTTS] Synthesizing sentence (42 chars, 0 queued): "Sure! I can help you..."
                                          ← TextSegmenter released first sentence
[KokoroOnnx] IPA: ...                   ← espeak-ng phonemize complete
[KokoroOnnx] Audio output: 48012 samples, infer=214 ms
                                          ← ONNX done; PCM burst sent to Dart
[AgentService] Kokoro audio #1: 4800 bytes → playResponseAudio
                                          ← first chunk playing; voice audible ~50 ms later
```

The gap between "Generation started" (first text in UI) and "Kokoro audio #1"
(first sound) is the measurable first-audio latency.
