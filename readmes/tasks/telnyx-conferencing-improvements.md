# Telnyx Conferencing — Feature & Infrastructure Changes

**Branch**: `improve-tts-overalll`
**Date**: 2026-04-11

## Goal

Enable three-way calling (conference merge) for Telnyx connections. This required building the conference service layer, a webhook relay for B-leg discovery, SIP header extraction for reliable call correlation, and migration from Credential Connections to a Call Control App.

## Status

**Closed** — server-side conferencing abandoned and code removed. On-device mixing implemented separately in `readmes/features/on-device-conference-mixing.md`.

Phase 1 built the full conference service layer but hit a fundamental blocker: Telnyx's Conference API does not support Credential Connections (no media redirection, no REST call control actions, identical A/B-leg CCIDs). Telnyx support confirmed this and recommended migrating to a Call Control App.

Phase 2 refactored the provider and service to use a Call Control App connection. However, testing revealed that linking a credential connection to a Call Control App in the Telnyx portal would **reassign the connection away from SIP Trunking to the Voice API**, breaking SIP registration and normal calling. There is no way to keep the credential connection as a SIP Trunk while also routing its calls through a Call Control App. The Telnyx Conference API is effectively unusable with our SIP credential connection architecture.

All Telnyx conference code (`TelnyxConferenceProvider`, `ConferenceProvider` abstract interface, REST merge path, WebSocket B-leg relay, webhook wiring, settings UI fields) has been removed. Only Basic (SIP REFER) and On Device conference modes remain.

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

## Issues History

### Phase 1 — Conference service layer built, Telnyx API blockers discovered

1. Conference API does not redirect media for credential connections
2. Call Control REST actions return 404 for credential connection CCIDs
3. B-leg CCIDs identical to A-leg CCIDs

### Phase 2 — Call Control App migration attempted, portal blocker discovered

4. Linking credential connection to a Call Control App in the Telnyx portal reassigns the connection from SIP Trunking to Voice API, breaking SIP registration and normal calling. No dropdown or option exists to keep both.
5. Active calls API returns stale records and `from=null to=null` for credential connection calls

## Phase 3: On-Device Audio Mixing

Moved to its own feature doc: [`readmes/features/on-device-conference-mixing.md`](../features/on-device-conference-mixing.md)

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

---

## Phase 4: Add Call Modal — Remote Identity Display

### Problem

When the "Add Call" modal transitions to its connected state, it only showed the raw dialed phone number with a plain green circle avatar. The main call screen shows the full remote identity (contact name, identicon avatar, formatted number via demo mode masking), but the add-call modal didn't match.

### Solution

Updated `_buildConnectedView()` in `AddCallModal` to mirror the call screen's identity display:

- Looks up the dialed number in `ContactService` to resolve a contact name
- Filters out "name is just a phone number" cases (same heuristic as the call screen)
- Applies `DemoModeService` masking for both name and phone
- Replaces the plain green circle with `ContactIdenticon` (same deterministic avatar used on the call screen)
- Shows contact name (24px bold) + formatted phone below when a contact matches, or just the formatted phone when no contact exists
- Status row ("Connected" + timer) moved to top to match call screen layout

### Files

| File | Changes |
|------|---------|
| `phonegentic/lib/src/widgets/add_call_modal.dart` | Added `ContactService`, `DemoModeService`, `ContactIdenticon` imports. Rewrote `_buildConnectedView()` with contact lookup, identicon, and two-line name+phone display. |