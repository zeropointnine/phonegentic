# INVITE 2xx retransmission drops Session-Expires header

## Problem

When the UAS retransmits a `200 OK` for an incoming INVITE (per RFC 3261 §13.3.1.4), the retransmitted response only includes a bare `Contact` header. The original response's `Session-Expires`, `Supported`, and any other extra headers are lost because `_setInvite2xxTimer` hardcoded its own header list instead of reusing the one built for the initial reply.

This causes the remote side to see two different 200 OK responses for the same INVITE — the first with `Session-Expires: 120;refresher=uas` and the second without it — which can confuse session-timer negotiation and looks like the agent is "repeating itself" with a slightly different answer.

## Solution

Pass the original `extraHeaders` list through to `_setInvite2xxTimer` so retransmissions are byte-identical to the original 200 OK (minus the callback hooks which are only for the first send).

## Files

- `lib/src/rtc_session.dart` — changed `_setInvite2xxTimer` signature to accept `extraHeaders`; updated both call sites (initial INVITE answer and re-INVITE handler).
