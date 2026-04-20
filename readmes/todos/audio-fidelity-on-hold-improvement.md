# Audio Fidelity Improvement: Leverage Hold-State Clarity

## Finding

When the Add2Call modal is presented, the agent's TTS audio becomes noticeably clearer. This is because pressing "Add Call" puts the current call on hold (SIP re-INVITE with `a=sendonly`), which drops the remote party's audio (`remoteRMS → 0.0`). The silence from the remote end improves TTS clarity through two mechanisms:

1. **Reduced AEC interference** — The Acoustic Echo Cancellation algorithm has no remote signal to subtract from the microphone/render path. The agent's TTS passes through untouched by AEC processing, eliminating the subtle artifacts AEC introduces when it tries to separate overlapping signals.

2. **Clean compressor/gain staging** — With only the TTS signal present, the compressor and gain stages (`setRemoteGain`, `setCompressorStrength`) operate on a single, stable input. This avoids the "pumping" effect that occurs when the compressor responds to a mix of TTS and live remote audio competing for headroom.

## Problem

During normal (non-hold) conversation, the agent's TTS competes with the remote party's audio in the render pipeline. AEC treats the TTS as potential echo and partially cancels it, and the compressor pumps between the two signals. The result is lower-fidelity agent audio whenever the remote party is also producing sound.

## Suggested Improvement

Explore a **virtual hold lane** or **split-render architecture** that gives the agent's TTS a dedicated audio path that bypasses AEC and has its own gain/compressor stage, even while the remote call is active:

- **Option A — Dual render streams**: Route TTS into a separate audio bus that mixes *after* AEC processing, so AEC never sees the TTS signal. The compressor on this bus can be tuned independently for speech clarity.
- **Option B — AEC-aware TTS injection**: Feed the TTS signal into AEC's reference input so it's excluded from cancellation rather than treated as echo. This is a lighter change that keeps a single render path but teaches AEC to ignore the agent.
- **Option C — Dynamic AEC bypass during TTS**: Momentarily reduce AEC aggressiveness or bypass it entirely while the agent is speaking (gated on `isSpeaking` state from the TTS engine). This is the simplest approach but may allow brief echo artifacts during overlap.

### Evaluation criteria

| Criterion | Option A | Option B | Option C |
|---|---|---|---|
| Audio quality | Best | Good | Acceptable |
| Implementation complexity | High | Medium | Low |
| Echo risk | None | Low | Moderate |
| Latency impact | Minimal | None | None |

## Files

- `phonegentic/lib/src/callscreen.dart` — `_handleHold()` / `_handleAddCall()` flow where hold triggers the clarity improvement
- `phonegentic/lib/src/audio/` — Audio processing pipeline (AEC, compressor, gain staging)
- `phonegentic/lib/src/agent_service.dart` — TTS playback integration point
