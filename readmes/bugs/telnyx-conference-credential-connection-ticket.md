# Telnyx Support Ticket: Conference API Does Not Route Audio for Credential (SIP) Connections

## Summary

The Telnyx Conference API (`POST /v2/conferences`, `POST /v2/conferences/{id}/actions/join`) successfully creates conferences and joins participants when using a **Credential Connection** (SIP registration via `sip.telnyx.com:7443` over WSS), but **remote parties lose all audio** after the conference is created. The PSTN-side callers hear silence and eventually disconnect.

This issue does **not** appear to be a client-side problem — we have exhaustively verified SDP negotiation, hold/unhold state, re-INVITE behavior, and media direction. The evidence points to the Conference API not properly redirecting the media path for A-legs originating from credential connections.

## Environment

- **Connection type**: Credential Connection (SIP username/password auth)
- **Connection ID**: `2898336005079696991`
- **Transport**: WSS to `sip.telnyx.com:7443`
- **Client**: WebRTC-based SIP UA (Dart/Flutter) using SRTP over DTLS
- **Call parking**: Enabled on the credential connection (`call_parking_enabled: true`)
- **Webhook URL**: Configured and receiving events (B-leg `call.initiated` events arrive correctly)

## Steps to Reproduce

1. Register a SIP UA via credential connection over WSS
2. Place **Call A** to a PSTN number (e.g., +14155331352) — call connects with full bidirectional audio
3. Put **Call A** on hold (SIP re-INVITE with `a=sendonly`)
4. Place **Call B** to a second PSTN number (e.g., +15039971854) — call connects with full bidirectional audio
5. **Unhold Call A** via SIP re-INVITE (`a=sendrecv`) — confirmed by 200 OK with `a=sendrecv`
6. Wait for unhold to settle (~2 seconds)
7. Call `POST /v2/conferences` with Call A's `call_control_id` — conference created successfully
8. Call `POST /v2/conferences/{id}/actions/join` with Call B's `call_control_id` — join succeeds
9. **Result**: Both PSTN remote parties immediately lose audio. `remoteRMS` drops to 0.0 on the client. Remote parties hear silence and disconnect after ~30 seconds.

## Detailed Observations

### 1. Conference creation and join succeed — participants show correct state

```
Conference ID: 7ea0d603-d357-41c9-9f64-82aea72a85eb
Participant 1: ccid=v3:KjptXGYQ... status=joined muted=false hold=false
Participant 2: ccid=v3:w1-oKKuh... status=joined muted=false hold=false
```

The `GET /v2/conferences/{id}/participants` endpoint confirms both participants are `joined`, not muted, and not on hold. The conference appears healthy from the API's perspective.

### 2. SDP media addresses do NOT change after conference join

This is the core issue. Before the conference, Call A's media endpoint (from Telnyx's FreeSWITCH) is:

```
c=IN IP4 50.114.150.6
m=audio 26400 UDP/TLS/RTP/SAVPF 0 126 13
a=sendrecv
```

After the conference is created and we send a re-INVITE to renegotiate media, Telnyx responds with:

```
c=IN IP4 50.114.150.6          ← SAME IP
m=audio 26400 UDP/TLS/RTP/SAVPF 0 126 13   ← SAME PORT
a=sendrecv
Contact: <sip:+14155331352@10.239.40.224:5070;transport=tcp>;isfocus  ← isfocus flag added
```

The Contact header gains `;isfocus` (RFC 4579 conference indicator), proving Telnyx knows the call is conferenced. But the **media address is unchanged** — our RTP is still directed at the original FreeSWITCH server, not a conference bridge/mixer.

Similarly, Call B's media stays at its original FreeSWITCH (`50.114.150.15:25960`).

For a conference to work, either:
- Telnyx should send a re-INVITE redirecting our media to the conference mixer IP, **or**
- The original FreeSWITCH instances should internally mix/bridge the audio

Neither appears to be happening — the PSTN parties hear silence immediately after the conference join.

### 3. Telnyx does NOT send re-INVITEs to the SIP client after conference join

After calling the Conference API, we monitored all incoming SIP messages. **No incoming re-INVITE was received** from Telnyx to redirect media. This is unlike what we'd expect from a conference bridge that needs to redirect RTP to a mixer.

With Call Control App connections, we'd expect Telnyx to send a re-INVITE with new media parameters pointing to the conference bridge. This never happens for credential connections.

### 4. Call Control API actions fail with 404 for credential connection CCIDs

Attempting to use Call Control actions on these call_control_ids fails:

```
PUT /v2/calls/{ccid}/actions/unhold → 404 Resource not found
```

This suggests that credential connection call_control_ids are not fully controllable via the Call Control REST API, which may be related to why the Conference API also doesn't properly manage media for these calls.

### 5. The active_calls endpoint returns stale calls from previous sessions

`GET /v2/connections/{id}/active_calls` consistently returns calls from sessions that ended 30+ minutes ago. In this test, 5 "active" calls were returned, but only 2 were from the current session. The stale entries have different `call_session_id` values from sessions that were terminated long ago.

### 6. B-leg CCIDs are identical to A-leg CCIDs for credential connections

For credential connections, the webhook-delivered B-leg `call_control_id` is the **same** as the A-leg `call_control_id` captured from the `X-Telnyx-Call-Control-ID` SIP header. This means there is no distinct B-leg entity to join to the conference — a fundamental difference from Call Control App connections where A-leg and B-leg have separate CCIDs.

## What We've Tried

| Approach | Result |
|----------|--------|
| Create conference with held call, join active call | Remote audio lost immediately |
| Create conference with active call, join held call | Remote audio lost immediately |
| Unhold all calls before conference creation | Remote audio lost immediately |
| Explicit `PUT /calls/{ccid}/actions/unhold` after join | 404 Resource not found |
| Client-initiated re-INVITE (renegotiate) after conference join | 200 OK returns same media address; no audio |
| Wait various delays (1.5s, 2s, 3s) between operations | No change |
| Join B-leg CCIDs to conference | B-leg CCID = A-leg CCID, already joined |

## SIP Trace Summary (Abridged)

### Call A setup
```
→ INVITE sip:+14155331352@sip.telnyx.com  (a=sendrecv)
← 200 OK  c=IN IP4 50.114.150.6  m=audio 26400  a=sendrecv
  X-Telnyx-Call-Control-ID: v3:KjptXGYQ...
```

### Call A put on hold
```
→ re-INVITE  (a=sendonly, CSeq 8147)
← 200 OK     (a=recvonly)     ← hold confirmed
```

### Call A unhold (pre-conference)
```
→ re-INVITE  (a=sendrecv, CSeq 8148)
← 200 OK     (a=sendrecv)     ← unhold confirmed, same media IP
```

### Conference created + joined
```
POST /v2/conferences → 201  (conference_id: 7ea0d603-...)
POST /v2/conferences/7ea0d603-.../actions/join (v3:w1-oKKuh...) → 200
```

### Post-conference renegotiation (client-initiated)
```
→ re-INVITE sip:+14155331352  (a=sendrecv, CSeq 8149)
← 200 OK
   Contact: <...>;isfocus          ← Telnyx KNOWS it's conferenced
   c=IN IP4 50.114.150.6          ← SAME media IP as before
   m=audio 26400                   ← SAME port as before
   a=sendrecv
```

**Audio state**: `remoteRMS=0.0` — complete silence from remote parties.

## Questions for Telnyx

1. **Is the Conference API supported for Credential Connections?** The documentation doesn't explicitly state this limitation, but all evidence suggests the conference bridge does not redirect media for credential connection A-legs.

2. **Why does the media address remain unchanged after conference join?** The `;isfocus` Contact parameter indicates Telnyx recognizes the conference state, but the `c=` and `m=` lines in the SDP are identical to pre-conference. Shouldn't the conference bridge send a re-INVITE with the mixer's media address?

3. **Why do Call Control actions (e.g., `unhold`) return 404 for credential connection CCIDs?** If these CCIDs are not controllable via the REST API, this should be documented.

4. **Is there a recommended approach for conferencing with credential connections?** Should we be using a Call Control App instead? If so, can credential connections be upgraded or configured to support full Call Control API actions?

5. **Why does `active_calls` return stale call records from terminated sessions?** Calls from 30+ minutes ago still appear in the active_calls list for the connection.

## Connection Details for Investigation

- **Connection ID**: `2898336005079696991`
- **Conference ID**: `7ea0d603-d357-41c9-9f64-82aea72a85eb` (created 2026-04-11 ~21:09:31 UTC)
- **Call A CCID**: `v3:KjptXGYQofdcRnp091_Qtpzmb3ErJBsICNxs48uHO0aRRLyUcJDX6Q`
- **Call A Session**: `aa2ea690-35ea-11f1-82c1-02420aef26a1`
- **Call B CCID**: `v3:w1-oKKuhNawR-9-Pj2vNVZggZD_lAzFGRDQL7gmvf3me0Dz6wwOWjQ`
- **Call B Session**: `b3925538-35ea-11f1-b8f1-02420aef29a1`
- **Timestamp window**: 2026-04-11 21:08:52 UTC to 21:09:40 UTC
- **FreeSWITCH servers involved**: `50.114.150.6` (Call A), `50.114.150.15` (Call B)
