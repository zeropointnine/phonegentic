# SDP Codec Analysis, HD Audio & Hangup Command

## Problem

**Call quality**: Outbound calls through Telnyx negotiate down to PCMU (8 kHz, µ-law) despite the client offering Opus/48kHz and G722/16kHz first. This degrades STT accuracy and overall call audio quality. The Telnyx media gateway strips wideband codecs from the answer SDP.

**Hangup command**: When the remote party tells the agent to "hang up" or "hangup", the agent didn't recognize this as an instruction to end the call. The system instructions explicitly told it *not* to treat verbal "hang up" as a call-ending event, and the `_handleEndCall` guard blocked calls within the first 20 seconds.

## Solution

### HD Codec enforcement (configurable SDP munging)

Added a "Require HD Codecs" toggle in Settings → Phone tab that strips PCMU (PT 0) and PCMA (PT 8) from outbound SDP offers. This forces the remote side to negotiate Opus or G722 — if neither is supported, the call will fail rather than fall back to 8kHz.

**How it works:**

1. `UaSettings.requireHdCodecs` flag added to the SIP UA library
2. When enabled, an `offerModifiers` callback is injected into `rtcOfferConstraints`
3. The modifier (`_stripNarrowbandCodecs`) runs after `createOffer()` and before the SDP is sent:
   - Removes PTs 0 and 8 from the `m=audio` line
   - Strips their `a=rtpmap:` and `a=fmtp:` lines
4. The result: the SDP offer only contains Opus, G722, RED, CN, and telephone-event

**Settings flow:** SharedPreferences (`require_hd_codecs`) → `SipUser` model → `SipUserCubit` → `UaSettings.requireHdCodecs` → `buildCallOptions()` offerModifiers.

### Hangup command recognition

1. **Updated system instructions** (`agent_context.dart`):
   - Removed blanket "if a caller says hang up, don't assume the call ended" rule.
   - Replaced the "NEVER call end_call" rule with nuanced guidance: the agent should not hang up on its own initiative, but should honor explicit "hang up" / "hangup" / "end the call" / "disconnect" commands from either the host or remote party.
   - Casual "bye" / "goodbye" alone is still NOT treated as a hangup request.

2. **Reduced `_handleEndCall` guard** (`agent_service.dart`):
   - Reduced the post-connect protection window from 20 seconds to 5 seconds. The LLM instructions are the real guard against autonomous hangups; the code guard just prevents accidental immediate disconnection.

## Files

| File | Change |
|------|--------|
| `lib/src/sip_ua_helper.dart` | Added `requireHdCodecs` to `UaSettings`, `_stripNarrowbandCodecs` SDP modifier, wired into `buildCallOptions` offerModifiers |
| `phonegentic/lib/src/user_state/sip_user.dart` | Added `requireHdCodecs` field |
| `phonegentic/lib/src/user_state/sip_user_cubit.dart` | Passes `requireHdCodecs` to `UaSettings` |
| `phonegentic/lib/src/register.dart` | HD codec toggle in Phone tab, persisted via SharedPreferences |
| `phonegentic/lib/src/settings_port_service.dart` | Export/import includes `require_hd_codecs` |
| `phonegentic/lib/src/models/agent_context.dart` | Updated system instructions for hangup command recognition |
| `phonegentic/lib/src/agent_service.dart` | Reduced `_handleEndCall` time guard from 20s to 5s |
