# Audio Compressor (Render Path)

## Problem

Remote speakers in calls have widely varying volume levels. The existing `remoteGain` is a flat linear multiplier (1.5x) that boosts everything uniformly — quiet speech stays relatively quiet while loud peaks risk clipping. This makes some callers hard to hear without turning the volume up so far that loud callers distort.

## Solution

A stateless logarithmic waveshaping compressor ported from [simple_compressor.py](https://github.com/zeropointnine/wave-edit/blob/master/simple_compressor.py). It applies a per-sample transfer function that pushes quiet sounds toward full scale while keeping peaks controlled:

```
exponent = (1 - strength) * 2 + 0.5
out = sign(in) * (1 - (1 - |in|)^exponent)
```

The compressor runs in the WebRTC **render path** (incoming audio from the network) after the whisper tap and before `remoteGain`, so the AI agent still hears the original uncompressed signal while the local speaker output gets leveled.

### Strength configuration

| Strength | Exponent | Effect |
|----------|----------|--------|
| 0.0 | 2.5 | No compression (slight expansion) |
| 0.3 | 1.9 | Light leveling |
| 0.5 | 1.5 | Moderate leveling |
| **0.6** | **1.3** | **Default — good balance** |
| 0.8 | 0.9 | Strong leveling |
| 1.0 | 0.5 | Maximum compression (sqrt curve) |

Configurable at runtime from Dart via `setCompressorStrength` on the `com.agentic_ai/audio_tap_control` method channel.

## Files

### Created
- `phonegentic/macos/Runner/SimpleCompressor.swift` — the compressor class

### Modified
- `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` — added `compressor` property, called in `RenderPreProcessor.audioProcessingProcess`
- `phonegentic/macos/Runner/AudioTapChannel.swift` — added `setCompressorStrength` method channel handler
- `phonegentic/ios/Runner/AudioTapChannel.swift` — added `setCompressorStrength` to the not-yet-implemented stub list
- `phonegentic/lib/src/callscreen.dart` — calls `setCompressorStrength` with default 0.6 on `_enterCallMode`
