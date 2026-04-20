# Conference Max Participants & Audio Routing Fix

## Problem

### 1. No configurable participant limit

Conference calls are effectively hard-capped at 2 remote legs (3-way calling):

- `_mergeBasic()` only REFERs `_legs[0]` and `_legs[1]`
- On-device mixer uses a 2-slot toggle cross-inject in `WebRTCAudioProcessor.swift`
- No `maxParticipants` field on `ConferenceConfig`
- No enforcement in `addLeg()`, UI, or agent tools

### 2. Agent audio breaks during hold in conference

When any conference participant is placed on hold, TTS audio stops reaching non-held participants. Root cause: the double-slot toggle in `WebRTCAudioProcessor.swift` assumes exactly 2 render + 2 capture callbacks per 10ms cycle. When a held PeerConnection's callbacks stop or change pattern, the toggle desyncs — capture reads the wrong slot (stale data / self-echo). Additionally, the `ttsCaptureRing` SPSC ring is consumed per-PC capture callback, so held PCs waste TTS samples that should go to non-held participants.

## Solution

1. Add `maxParticipants` to `ConferenceConfig` (default 5), with persistence, settings UI, and enforcement in `addLeg()`, callscreen, agent service, and agent tools.
2. Replace the 2-slot toggle cross-inject with an N-slot approach driven by the **actual leg count from Flutter**. WebRTC audio callbacks fire in interleaved per-PC order (`R_0, C_0, R_1, C_1, ...`), not batched (`R_0, R_1, ..., C_0, C_1, ...`). An earlier auto-detect approach that counted render callbacks per cycle failed because the interleaved pattern meant only 1 render had fired by the time the first capture ran, causing slot overwrites and wrong gain. The fix passes the real leg count via `setConferenceMode(slotCount:)` and updates it whenever legs are added or removed.
3. **Removed both render-side and capture-side TTS snapshot mechanisms.** Both had the same root cause: with `confSlotCount=2` but only 1 PeerConnection actively firing callbacks (the held PC is silent), the `confRenderIndex`/`confCaptureIndex` still alternated 0→1→0→1. The snapshot only fired when the index was 0 (every other callback), consuming TTS at half the needed rate (12,000 vs 24,000 samples/sec) and replaying the same 10ms chunk twice — producing a stuttery/robotic artifact. The render-side snapshot caused robotic audio on the local speaker; the capture-side snapshot caused robotic audio heard by remote parties (the phone). Fix: call `mixTTSInto` directly from the ring buffer on every callback for both render and capture, identical to the non-conference path.
5. Store per-slot sample rates (`confSlotRates[]`) instead of a single global `confSlotRate`, fixing incorrect resampling when cross-mixing PCs that render at different rates (e.g. 48kHz held vs 8kHz active).
6. Cap basic (SIP REFER) provider to 2 legs since REFER is fundamentally pairwise.
7. Fix merge not reliably unholding: replaced fire-and-forget `call.unhold()` with a poll loop that waits for the SIP re-INVITE to complete (up to 3s). Added a post-merge sweep that re-unholds any legs that got re-held due to SIP re-INVITE collisions.
8. Fix TTS pipeline dying after discarded LLM response: when `_appendStreamingResponse` discards an entire response (hallucinated CALL_STATE, dial-pending), it now calls `_activeTtsEndGeneration()` to cleanly close the ElevenLabs WebSocket. Previously, the BOS was sent but no text or EOS followed, causing a 20-second timeout that left the TTS pipeline dead for all subsequent responses.

## Files

| File | Changes |
|------|---------|
| `phonegentic/lib/src/conference/conference_config.dart` | Add `maxParticipants` field (default 5), `effectiveMaxParticipants` getter (clamps basic to 2), `copyWith` |
| `phonegentic/lib/src/conference/conference_service.dart` | Enforce limit in `addLeg()`, add `atCapacity` getter |
| `phonegentic/lib/src/agent_config_service.dart` | Persist `agent_conf_max_participants` |
| `phonegentic/lib/src/settings_port_service.dart` | Export/import `max_participants` in conference JSON |
| `phonegentic/lib/src/register.dart` | Max participants dropdown in conference card (2-10 for onDevice, locked to 2 for basic) |
| `phonegentic/lib/src/callscreen.dart` | Disable "Add Call" when `conf.atCapacity` |
| `phonegentic/lib/src/agent_service.dart` | Return capacity error in `_handleAddConferenceParticipant` |
| `phonegentic/lib/src/widgets/agent_panel.dart` | Show "Conference (n/max)" in header |
| `phonegentic/lib/src/text_agent_service.dart` | Updated `add_conference_participant` and `merge_conference` descriptions |
| `phonegentic/lib/src/whisper_realtime_service.dart` | Updated `add_conference_participant` and `merge_conference` descriptions |
| `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` | N-slot counter-based mixer replacing 2-slot toggle; removed TTS snapshot mechanisms from both render and capture paths |
| `phonegentic/macos/Runner/AudioTapChannel.swift` | Accept `slotCount` in `setConferenceMode` method channel |
| `phonegentic/lib/src/dialpad.dart` | Pass `slotCount` from conference config when enabling conference mode |
