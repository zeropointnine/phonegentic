# Auto-answer safety path skips enterCallMode

## Problem

When the auto-answer safety timer fires (because the CallScreen's SIP listener missed the ACCEPTED/CONFIRMED state transitions), the dialpad forces the agent into settling via `notifyCallPhase`. However, it never calls `enterCallMode` on the native AudioTap. This means the WebRTC audio processor is never registered, and all TTS audio plays through the direct (local speaker) path instead of being injected into the WebRTC stream. The remote party hears silence — the agent's voice is inaudible.

The symptom is `[AudioTap] flush: mode=direct` throughout the call instead of `mode=call`, combined with the `[Dialpad] Auto-answer safety: agent stuck in ringing, forcing settling` log message.

## Solution

Added `enterCallMode` (plus `setRemoteGain` and `setCompressorStrength`) to the auto-answer safety path in the dialpad. Also added matching `exitCallMode` cleanup when all calls end, gated by a `_safetyCallModeForced` flag to avoid interfering with normal call teardown.

The native AudioTap uses refcounting for `enterCallMode`/`exitCallMode`, so even if the CallScreen's listener eventually fires and enters call mode too, the cleanup is balanced.

## Files

### Modified
- `phonegentic/lib/src/dialpad.dart` — added `enterCallMode` to safety path, `exitCallMode` on call end
