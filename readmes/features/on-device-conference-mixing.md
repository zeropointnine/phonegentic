# On-Device Conference Mixing

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-16

## Problem

Three-way calling requires a conference bridge to mix audio from two SIP calls. Phases 1–2 of `telnyx-conferencing-improvements` proved the Telnyx Conference API is unusable with SIP credential connections: the API never redirects media to a server-side bridge, and linking the credential connection to a Call Control App reassigns it away from SIP Trunking, breaking registration.

SIP REFER ("Basic" mode) also fails — Telnyx's FreeSWITCH does not bridge the referred parties into the same media path.

No server-side conference option works with our SIP architecture.

## Solution

The Flutter app becomes the conference bridge. With two concurrent WebRTC PeerConnections (Call A and Call B), the native `WebRTCAudioProcessor` (Swift, macOS) cross-routes audio between them:

- Call A's remote audio is injected into Call B's outgoing capture stream (so Party B hears Party A)
- Call B's remote audio is injected into Call A's outgoing capture stream (so Party A hears Party B)
- The mic signal flows into both capture streams (both parties hear the local user)
- TTS audio flows into both capture streams (both parties hear the AI agent)

No Telnyx REST API calls, no webhook relay, no server-side bridge needed.

### Configuration

A new `ConferenceProviderType.onDevice` option is added to the conference settings dropdown. When selected, the merge button triggers `_mergeLocal()` instead of SIP REFER or Telnyx REST calls.

```
Settings → Conference Calling → Provider dropdown:
  Off | Basic | Telnyx | On Device
                                ^^^ new
```

### Audio mixing architecture

```
┌──────────────────────────────────────────────────┐
│                  Flutter App                      │
│                                                   │
│  ┌──────────┐    render audio    ┌──────────┐    │
│  │ Call A    │──────────────────►│ Mixer     │    │
│  │ (WebRTC) │                   │           │    │
│  │          │◄──────────────────│ inject B  │    │
│  └──────────┘    capture inject  │ + mic     │    │
│                                  │           │    │
│  ┌──────────┐    render audio    │           │    │
│  │ Call B    │──────────────────►│           │    │
│  │ (WebRTC) │                   │ inject A  │    │
│  │          │◄──────────────────│ + mic     │    │
│  └──────────┘    capture inject  └──────────┘    │
│                                                   │
│  Each party hears: the other party + mic          │
│  (mic is shared across both capture streams)      │
└──────────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
    ┌─────────┐          ┌─────────┐
    │ Telnyx   │          │ Telnyx   │
    │ (SIP A)  │          │ (SIP B)  │
    └─────────┘          └─────────┘
         │                    │
         ▼                    ▼
    Remote Party A       Remote Party B
```

### Implementation: double-slot cross-inject

WebRTC's `ExternalAudioProcessingDelegate` callbacks fire per-PeerConnection in deterministic order (creation order). With two concurrent calls:

```
Per 10ms audio cycle:
  1. RenderPreProc(PC_A audio)  → writes slot0
  2. RenderPreProc(PC_B audio)  → writes slot1
  3. CapturePostProc(PC_A mic)  → reads slot1, mixes B's audio into A's capture
  4. CapturePostProc(PC_B mic)  → reads slot0, mixes A's audio into B's capture
```

The toggle mechanism alternates which slot each callback writes/reads, and capture reads from the **opposite** slot to what render wrote. This achieves zero-echo cross-routing:

- Party A's voice → slot0 → read by PC_B's capture → sent to Party B (never back to A)
- Party B's voice → slot1 → read by PC_A's capture → sent to Party A (never back to B)
- Mic audio is already in the capture buffer from WebRTC's ADM → both parties hear local user

The slots are raw `UnsafeMutablePointer<Float>` buffers (pre-allocated at 960 frames = 10ms at 96kHz). Cross-inject gain is 0.7 to prevent clipping when mixed with mic. Rate mismatch between render and capture is handled via linear interpolation.

### Conference-mode TTS injection

The `ExternalAudioProcessingDelegate` callbacks are **global** — one invocation per 10ms audio cycle regardless of how many PeerConnections are active. This means the TTS ring buffers have a single consumer and no depletion problem exists. TTS is mixed via `mixTTSInto()` unconditionally in both capture and render paths, whether or not conference mode is active.

### Known limitations

1. **Callback ordering assumption**: The double-slot approach relies on WebRTC processing PeerConnections in consistent creation order. If order flips, one audio cycle would have incorrect routing (self-echo) before self-correcting.

2. **Two-party limit**: The slot toggle only handles exactly 2 PeerConnections. Three or more would require a different routing strategy.

### Configuration

A new `ConferenceProviderType.onDevice` option is added to the conference settings dropdown. When selected, the merge button triggers `_mergeLocal()` instead of SIP REFER or Telnyx REST calls.

```
Settings → Conference Calling → Provider dropdown:
  Off | Basic | Telnyx | On Device
                                ^^^ new
```

### Existing infrastructure leveraged

- **APM conference mode**: AEC, NS, and AGC are already disabled when `callModeRefCount > 1` (prevents the "wind tunnel" from two PCs confusing single-stream AEC).
- **`ConferenceService` leg tracking**: Hold/unhold, merge orchestration, and conference UI (badge, add call modal) all work unchanged.
- **Whisper tap**: `writeToWhisper()` in the render processor continues to feed the AI agent's audio stream in conference mode, so the agent still hears both parties.

## Files

| File | Changes |
|------|---------|
| `phonegentic/lib/src/conference/conference_config.dart` | Added `onDevice` to `ConferenceProviderType` enum |
| `phonegentic/lib/src/conference/conference_service.dart` | Added `_mergeLocal()` path, `onConferenceModeChanged` callback, conf-aware `reset()` |
| `phonegentic/lib/src/agent_config_service.dart` | Persistence works via enum index (no code change needed) |
| `phonegentic/lib/src/register.dart` | Added "On Device" dropdown option with subtitle text |
| `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` | Added double-slot cross-inject: `confSlot0/1`, `confRenderStore()`, `confCaptureMix()`, `confResetSlots()`. Wired into RenderPreProc and CapturePostProc when `conferenceMode=true`. |
