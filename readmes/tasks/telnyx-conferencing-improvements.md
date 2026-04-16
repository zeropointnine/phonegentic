# Telnyx Conferencing — Feature & Infrastructure Changes

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-11

## Goal

Enable three-way calling (conference merge) for Telnyx connections. This required building the conference service layer, a webhook relay for B-leg discovery, SIP header extraction for reliable call correlation, and migration from Credential Connections to a Call Control App.

## Status

**Phase 3 planned** — local audio mixing (app-side conference bridge).

Phase 1 built the full conference service layer but hit a fundamental blocker: Telnyx's Conference API does not support Credential Connections (no media redirection, no REST call control actions, identical A/B-leg CCIDs). Telnyx support confirmed this and recommended migrating to a Call Control App.

Phase 2 refactored the provider and service to use a Call Control App connection. However, testing revealed that linking a credential connection to a Call Control App in the Telnyx portal would **reassign the connection away from SIP Trunking to the Voice API**, breaking SIP registration and normal calling. There is no way to keep the credential connection as a SIP Trunk while also routing its calls through a Call Control App. The Telnyx Conference API is effectively unusable with our SIP credential connection architecture.

Phase 3 will abandon the Telnyx Conference API entirely and implement **local audio mixing** in the app. The Flutter app becomes the conference bridge: audio from Call A's WebRTC render stream is injected into Call B's capture stream, and vice versa. No server-side conference bridge is needed.

---

## Files Changed

### New Files

| File | Purpose |
|------|---------|
| `phonegentic/lib/src/conference/conference_provider.dart` | Abstract interface + data models (`ActiveCallInfo`, `ConferenceBridge`, `ConferenceParticipant`) for conference providers |
| `phonegentic/lib/src/conference/conference_service.dart` | Core conference orchestration — leg tracking, hold/unhold, merge logic, WebSocket B-leg relay client |
| `phonegentic/lib/src/conference/telnyx_conference_provider.dart` | Telnyx-specific implementation — REST API calls for conference CRUD, active call lookup (Call Control App) |
| `static/DEPLOY.md` | Deployment guide for the Rust relay server (SCP, Nginx, systemd) |
| `readmes/bugs/telnyx-conference-credential-connection-ticket.md` | Detailed Telnyx support ticket with SDP traces |

### Modified Files

| File | Changes |
|------|---------|
| `lib/src/sip_ua_helper.dart` | Added `telnyxCallControlId`, `telnyxSessionId`, `telnyxLegId` fields to `Call` class. Implemented `_extractTelnyxHeaders()` to capture `X-Telnyx-*` headers from SIP 180/200 responses for reliable A-leg correlation. |
| `lib/src/rtc_session.dart` | Fixed `peerconnection:setlocaldescriptionfailed` by synthesizing missing `a=group:BUNDLE` in SDP offers. Added guard against double-completing a `Completer` in `_createLocalDescription`. |
| `phonegentic/lib/src/callscreen.dart` | Integrated `ConferenceService` — conference leg initiation, merge button, hold/unhold per-leg controls, conference mode audio pipeline toggle. |
| `phonegentic/lib/src/dialpad.dart` | Wired `MessagingService.callControlHandler` to `TelnyxConferenceProvider.extractBLegFromWebhook` as a fallback B-leg discovery path. |
| `phonegentic/lib/src/register.dart` | Added `Webhook Relay URL` configuration field under conference settings with hint text and helper label. |
| `phonegentic/lib/src/agent_service.dart` | Conference-aware call phase management — `onHold` state, multi-party tracking. |
| `phonegentic/lib/src/messaging/messaging_service.dart` | Exposed `callControlHandler` stream for routing call control webhook payloads to the conference provider. |
| `phonegentic/lib/src/messaging/webhook_listener.dart` | Local HTTP server (port 4190) for webhook reception. |
| `phonegentic/lib/src/widgets/agent_panel.dart` | UI adjustments for conference state display. |
| `phonegentic/lib/src/whisperkit_stt_service.dart` | Minor adjustments. |
| `static/static_server/src/main.rs` | Added WebSocket endpoint (`/ws/call_control`) and Telnyx webhook handler. Parses incoming `call.initiated` events and broadcasts B-leg `call_control_id`s to connected Flutter clients via WebSocket. |
| `static/static_server/Cargo.toml` | Added `ws` feature to axum, added `futures-util` dependency for WebSocket stream handling. |

---

## Architecture

```
┌─────────────┐     SIP/WSS      ┌───────────────┐    PSTN
│ Flutter App  │◄───────────────►│ Telnyx         │◄────────► Remote Party
│ (SIP UA)     │                 │ FreeSWITCH     │
└──────┬───────┘                 └───────┬────────┘
       │                                 │
       │ REST API                        │ Webhook POST
       │ (conference CRUD)               │ (call.initiated)
       │                                 │
       ▼                                 ▼
┌──────────────┐              ┌─────────────────────┐
│ Telnyx       │              │ Rust Static Server   │
│ Conference   │              │ (phonegentic.ai)     │
│ API          │              │                      │
└──────────────┘              │ /web_hooks/telnyx    │
                              │   → parse B-leg ccid │
                              │   → broadcast via WS │
                              │                      │
                              │ /ws/call_control     │
                              │   ← Flutter connects │
                              └─────────────────────┘
```

## Key Implementation Details

### 1. SIP Header Extraction (`sip_ua_helper.dart`)

Telnyx embeds `X-Telnyx-Call-Control-ID`, `X-Telnyx-Session-ID`, and `X-Telnyx-Leg-ID` in SIP 180 Ringing and 200 OK responses. These are captured directly from the SIP signaling and stored on the `Call` object, providing the most reliable A-leg correlation (more reliable than phone number matching against the active_calls API).

### 2. Conference Merge Flow (`conference_service.dart`)

The `_mergeTelnyx()` method follows this sequence:

1. **Pre-unhold** — any held SIP legs are unheld via re-INVITE (`a=sendrecv`) before touching the Conference API, ensuring B-legs have an active media path
2. **Wait 2s** — for the SIP re-INVITE round-trip to complete
3. **Resolve legs** — three-pass matching (SIP header ccid → phone number → elimination) against the active_calls API
4. **Create conference** with the first leg's `call_control_id`
5. **Join remaining A-legs** with 1.5s stagger
6. **Join B-legs** — webhook-captured B-leg ccids (with Call Control App these are distinct from A-leg ccids and must be explicitly joined)
7. **Wait 2s** — Call Control App conferences handle media redirection server-side (Telnyx sends re-INVITEs to redirect RTP to the conference bridge)
8. **Verify participants** via `GET /conferences/{id}/participants`

### 3. WebSocket B-Leg Relay (`static_server/src/main.rs`)

The Rust server receives Telnyx webhook POSTs at `/web_hooks/telnyx`, extracts `call.initiated` events with `direction=outgoing` (B-legs), and broadcasts the `call_control_id` to all connected WebSocket clients at `/ws/call_control`. The Flutter app's `ConferenceService` maintains a persistent WebSocket connection with auto-reconnect.

### 4. Call Control App Setup

The credential connection must be linked to a Call Control App in the Telnyx Mission Control Portal. The Call Control App's webhook URL points to the Rust relay server, which broadcasts events to the Flutter client via WebSocket. Call parking is no longer needed — Call Control Apps natively surface B-leg events with distinct `call_control_id`s.

---

## Resolved Issues (Phase 2)

1. **~~Conference API does not redirect media for credential connections~~** — Resolved by migrating to Call Control App. The conference bridge now properly redirects media via server-side re-INVITEs.

2. **~~Call Control REST actions return 404 for credential connection CCIDs~~** — Resolved. Call Control App CCIDs support all REST API actions (hold, unhold, transfer, etc.).

3. **~~B-leg CCIDs identical to A-leg CCIDs~~** — Resolved. Call Control Apps provide distinct A-leg and B-leg `call_control_id`s.

## Remaining Concerns

1. **Active calls API may return stale records** — Telnyx flagged this as a possible data sync bug. The three-pass leg matching works around it by preferring SIP-header ccids and skipping stale entries by creation time. Monitor after migration.

2. **SIP header availability** — Verify that `X-Telnyx-Call-Control-ID` headers are still present in SIP 180/200 responses when the credential connection is linked to a Call Control App. If not, leg resolution falls back to phone number matching.

## Phase 3: Local Audio Mixing (Planned)

### Problem

The Telnyx Conference API requires a Call Control App connection, but linking our SIP credential connection to a Call Control App reassigns it away from SIP Trunking — breaking registration and normal calling. There is no portal option to keep both. The Conference API's `createConference` and `joinConference` calls succeed on credential connection CCIDs, but Telnyx never redirects media to the conference bridge (RTP stays on the original path, `remoteRMS=0.0` after merge).

### Approach: App-side conference bridge

Instead of relying on Telnyx to mix audio server-side, the app mixes audio locally across its two concurrent WebRTC sessions. The native `AudioTap` layer (macOS Swift) already supports conference mode (`APM conference mode ON`) and manages separate capture/render audio processing chains per call.

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

### Key design questions to resolve

1. **Multi-PeerConnection audio routing**: Currently WebRTC uses a single PeerConnection per call. With two concurrent calls, macOS will have two sets of capture/render audio processors. Need to confirm the AudioTap layer can distinguish and cross-route between them.

2. **Capture injection**: The `CapturePostProc` already injects TTS audio into the outbound stream. For conferencing, it needs to also inject the *other call's render audio* into each call's capture stream. This means Call A's `RenderPreProc` output must be readable by Call B's `CapturePostProc`, and vice versa.

3. **Echo / feedback prevention**: When Call A's remote audio is injected into Call B's capture, and Call B's remote audio is injected into Call A's capture, there's a risk of audio feedback loops. AEC is currently disabled in conference mode — may need a simple "don't re-inject what you just received" guard, or a short mixing buffer with origin tagging.

4. **Mic sharing**: The mic signal needs to go into both calls' capture streams. Currently the mic IOProc feeds one ring buffer. Both `CapturePostProc` instances would need to read from the same mic source without contention.

5. **Merge trigger**: The existing `_mergeTelnyx()` flow in `ConferenceService` would be replaced (or a new `_mergeLocal()` path added) that simply activates cross-injection in the AudioTap layer and unholds both SIP legs. No Telnyx REST API calls needed.

6. **TTS routing in conference**: When the AI agent speaks (ElevenLabs TTS), the audio currently goes into the capture stream. In conference mode, TTS output should be injected into both calls' capture streams so all parties hear the agent.

### Existing infrastructure to leverage

- **`AudioTap` (Swift, macOS)**: Already has `enterCallMode`/`exitCallMode`, conference mode flag, `setConferenceMode`, separate `CapturePostProc`/`RenderPreProc` per PeerConnection, ring buffers for mic and TTS injection.
- **`ConferenceService` (Dart)**: Leg tracking, hold/unhold, merge orchestration — the Dart-side coordination is already built. Just needs a `_mergeLocal()` path.
- **`CallScreen`**: Conference UI (add call, merge button, per-leg hold) is already implemented.

### What can be removed (Phase 3 cleanup)

- Telnyx Conference REST API calls (`createConference`, `joinConference`, `listParticipants`, hold/unhold participant)
- B-leg webhook discovery (WebSocket relay, `extractBLegFromWebhook`)
- `TelnyxConferenceProvider` class (or gut it to just `lookupActiveCalls` if still useful)
- Rust server webhook broadcast (`/ws/call_control` endpoint)
- Call Control App in Telnyx portal (can be deleted)

---

## Appendix: Telnyx Support Response (2026-04-15)

Telnyx confirmed the Conference API is **not supported for Credential Connections** — it requires a Call Control App connection. Key points:

- Conference API media redirection only works with Call Control App connections
- `call_control_id` from `X-Telnyx-Call-Control-ID` SIP headers on credential connections is for identification/tracking only, not full API control
- Call Control Apps provide: full Conference API, all REST call control actions, separate A/B-leg CCIDs
- Stale active_calls records may be a Telnyx data sync bug — report with connection ID and timestamps

**Solution applied**: Link existing credential connection to a new Call Control App in Mission Control Portal. SIP registration/calling unchanged; conference operations now use Call Control App's connection ID.

**Reference docs**:
- [Voice API Commands](https://developers.telnyx.com/docs/voice/programmable-voice/)
- [SIP Connections Overview](https://developers.telnyx.com/docs/voice/connections)
- [List Active Calls API](https://developers.telnyx.com/api/call-control/list-connection-active-calls)