# Inbound calls show video-call UI despite being voice-only

## Problem

Telnyx always includes a `video` m-line in inbound INVITEs (`m=video 31092 RTP/SAVPF 103`). Even though the local answer rejects video (port 0), the callscreen's `voiceOnly` getter checked `call!.remote_has_video` against the *offer* SDP, which always returned `true`. This made every inbound call appear as a video call:

- Centered caller-info overlay (avatar, name, "Connected" status) disappeared on confirmation
- Action buttons showed "Cam Off" / "Flip" instead of "Record" / "Keypad"
- Connected call screen was an empty black area with only a timer pill

Outbound calls worked correctly because they set `call!.voiceOnly = true` at initiation and the remote never offers video.

## Solution

Changed the `voiceOnly` getter from checking the SDP offer (`!call!.remote_has_video`) to checking whether the remote stream actually has video tracks at runtime. The new condition:

```dart
bool get voiceOnly =>
    call!.voiceOnly &&
    (_remoteStream == null || _remoteStream!.getVideoTracks().isEmpty);
```

This correctly returns `true` for:
- Outbound voice calls (no video negotiated)
- Inbound Telnyx calls where video was offered but rejected (no video tracks)

And correctly returns `false` for:
- Outbound video calls (`call!.voiceOnly = false`)
- Any call where video tracks are actually flowing
- Mid-call video upgrades (where `call!.voiceOnly` is set to `false` on accept)

The `_handleAccept` flow is unaffected since it reads `call!.remote_has_video` directly for SDP negotiation.

## Files

- `phonegentic/lib/src/callscreen.dart` — fixed `voiceOnly` getter to check actual video tracks instead of SDP offer
