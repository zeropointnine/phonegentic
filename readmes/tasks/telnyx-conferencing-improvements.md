# Telnyx Conferencing — Feature & Infrastructure Changes

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-11

## Goal

Enable three-way calling (conference merge) for Telnyx Credential Connections. This required building the conference service layer, a webhook relay for B-leg discovery, SIP header extraction for reliable call correlation, and extensive SDP/hold-state handling.

## Status

The client-side implementation is complete and mechanically correct. However, Telnyx's Conference API does not redirect media for Credential Connection A-legs — the conference bridge acknowledges participants (`;isfocus`) but the SDP media address remains pointed at the original FreeSWITCH server, resulting in silence for remote parties. A detailed support ticket has been filed: `readmes/bugs/telnyx-conference-credential-connection-ticket.md`.

---

## Files Changed

### New Files

| File | Purpose |
|------|---------|
| `phonegentic/lib/src/conference/conference_provider.dart` | Abstract interface + data models (`ActiveCallInfo`, `ConferenceBridge`, `ConferenceParticipant`) for conference providers |
| `phonegentic/lib/src/conference/conference_service.dart` | Core conference orchestration — leg tracking, hold/unhold, merge logic, WebSocket B-leg relay client |
| `phonegentic/lib/src/conference/telnyx_conference_provider.dart` | Telnyx-specific implementation — REST API calls for conference CRUD, call parking, active call lookup |
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
5. **Join remaining legs** with 1.5s stagger
6. **Join B-legs** — webhook-captured B-leg ccids (for credential connections these are the same as A-leg ccids, so they're skipped as duplicates)
7. **Renegotiate media** — force re-INVITE on each SIP leg to prompt Telnyx to return updated SDP with conference bridge media address
8. **Verify participants** via `GET /conferences/{id}/participants`

### 3. WebSocket B-Leg Relay (`static_server/src/main.rs`)

The Rust server receives Telnyx webhook POSTs at `/web_hooks/telnyx`, extracts `call.initiated` events with `direction=outgoing` (B-legs), and broadcasts the `call_control_id` to all connected WebSocket clients at `/ws/call_control`. The Flutter app's `ConferenceService` maintains a persistent WebSocket connection with auto-reconnect.

### 4. Call Parking

On startup, `TelnyxConferenceProvider.enableCallParking()` calls `PATCH /v2/credential_connections/{id}` to set `call_parking_enabled: true` and configure the `webhook_event_url`. This makes Telnyx surface B-leg events via webhooks, which is required for credential connections since the active_calls API only returns A-legs.

---

## Known Issues / Blockers

1. **Conference API does not redirect media for credential connections** — The core blocker. Telnyx adds `;isfocus` to the SIP Contact but the SDP `c=`/`m=` lines remain pointed at the original FreeSWITCH. Remote parties hear silence. See the detailed ticket in `readmes/bugs/`.

2. **Call Control REST actions return 404 for credential connection CCIDs** — `PUT /calls/{ccid}/actions/unhold` and similar endpoints are not available for credential connection call_control_ids.

3. **Active calls API returns stale records** — `GET /connections/{id}/active_calls` includes calls from sessions terminated 30+ minutes ago. The three-pass leg matching works around this by preferring SIP-header ccids and skipping stale entries by creation time.

## Next Steps

- **Await Telnyx support response** on whether conferencing is supported for credential connections
- **Evaluate Call Control App migration** — Call Control Apps provide distinct A/B-leg ccids, full REST API control, and proper conference bridge media redirection
- **Consider client-side audio mixing** as a fallback — the `conf=YES` audio pipeline already exists; it would require injecting each remote party's audio into the other call's outgoing stream
