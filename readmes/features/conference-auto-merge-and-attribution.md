# Conference Auto-Merge & Per-Leg Speaker Attribution

## Problem

The conference-call flow had a chain of issues that made multi-party calls
unreliable and confusing for both the manager and the agent:

1. **Manual `merge_conference` step required.** After
   `add_conference_participant` dialed the new leg, the LLM had to follow up
   with `merge_conference` to actually bridge the parties. Frequently it
   forgot or asked the manager to confirm — leaving the manager stranded
   on hold while the agent waited for instructions.

2. **Auto-unhold skipped after the new leg connected.** Even when the
   merge logic was wired up, the dart_sip_ua library emits a spurious
   `STREAM` callback right after a hold re-INVITE completes. That flips
   `Call.state` away from `HOLD` even though the negotiated SDP still has
   us as `sendonly` / `recvonly`. Driving the auto-unhold off
   `Call.state == HOLD` therefore mis-skipped the `unhold()` call and the
   manager remained muted.

3. **Premature connection trigger from `STREAM`.** `_AgentSipListener`
   treated `CallStateEnum.STREAM` as "connected" and called
   `_handleConferenceLegConnected`, which cleared `_pendingConferenceLegCallId`
   *before* SIP signaling actually completed. When a `404 Invalid number`
   later landed, `_handleConferenceLegDropped` had nothing to match against
   and the failure went unhandled.

4. **`unhold()` dropped the call entirely.** A regression in SDP parsing
   meant remote answers to hold/unhold re-INVITEs that lacked an explicit
   `a=group:BUNDLE` line failed `setRemoteDescription` with a bundle-group
   mismatch, killing the call instead of toggling hold.

5. **Echo on conference legs.** `setAPMConferenceMode` was disabling AEC
   wholesale when a second leg joined, causing the manager's voice to echo
   back through the secondary leg.

6. **Wrong speaker on conference transcripts.** WebRTC delivers the *mixed*
   remote bus to Whisper, so any audio from the secondary leg's IVR /
   agent / human transcribed through the same "remote" channel as the
   primary caller. The transcript engine then tagged it with
   `remoteSpeaker.name` (e.g. "Patrick"), so the LLM saw the Delta IVR
   say *"Hi, I'm Delta's AI assistant"* attributed to the manager — and
   tried to respond on the manager's behalf.

   An interim fix suppressed those transcripts, but suppression hid real
   speech the model needed to hear and respond to. The user explicitly
   rejected suppression in favor of correct attribution.

## Solution

### P1: Auto-merge on leg connection
- `_handleConferenceLegConnected(Call newLeg)` is invoked by
  `_AgentSipListener` when the new leg reaches a connected SIP state. It
  takes the primary call off hold, registers both legs with
  `ConferenceService` (so the UI sees them), and tells the LLM the merge
  succeeded — no follow-up `merge_conference` tool call required.
- The tool-result string returned by `_handleAddConferenceParticipant` was
  rewritten to instruct the LLM explicitly *not* to call `merge_conference`
  and to wait silently while the dial completes.

### P2: Reliable auto-unhold via `_primaryHeldForConference`
- New boolean field tracks whether *we* placed the primary on hold for a
  conference, independent of `Call.state`.
- `_handleAddConferenceParticipant` sets the flag when issuing
  `active.hold()` (or detecting an existing hold).
- `_handleConferenceLegConnected` calls `primary.unhold()` unconditionally
  if the flag is true, ignoring the lying `Call.state` enum.
- The flag resets on success, on leg drop, and on dial-failure exception.

### P3: Connection trigger restricted to `CONFIRMED` / `ACCEPTED`
- Removed `CallStateEnum.STREAM` from the list of states that trigger
  `_handleConferenceLegConnected` in `_AgentSipListener.callStateChanged`.
- Late-capture fallback in the listener still picks up the new leg's
  `call.id` if the dial-time diff in `_handleAddConferenceParticipant`
  missed it.

### P4: SDP bundle-group / RTCP-mux handling
- `_extractBundleMidsFromSdp()` and `_ensureRtcpMux()` in
  `rtc_session.dart` now correctly parse `a=mid:` lines and synthesize a
  matching `a=group:BUNDLE` when the remote answer omits one. Hold/unhold
  re-INVITEs no longer fail `setRemoteDescription`.

### P5: AEC stays on in conference mode
- `setAPMConferenceMode` in `AudioTapChannel.swift` now disables only NS
  and AGC when a second leg joins. AEC and HPF remain active so the
  manager's voice is still cancelled out of the secondary leg's audio.
- `enterCallMode` / `exitCallMode` reference-count properly so flipping
  conference mode on/off doesn't tear down the APM.

### P6: Per-transcript speaker reattribution (no suppression)
- New field `_pendingConferenceLegLabel` is populated up-front in
  `_handleAddConferenceParticipant` via a contact-directory lookup on the
  dialed number (e.g. `"Delta Airlines"`), with a fallback to the raw
  number.
- New helper `_resolveSecondaryLegLabel()` returns a friendly label for
  the non-primary leg, in priority order:
  1. `_pendingConferenceLegLabel` (covers the ringing / IVR-greeting
     window before the leg answers).
  2. The `ConferenceCallLeg.displayName` of any registered leg whose id
     ≠ `_primaryConferenceCallId`.
  3. Any `sipHelper.calls` entry whose `remote_identity` differs from
     `_remoteIdentity`.
- New helper `_lookupContactName(phone)` centralizes contact-by-phone
  resolution with name-equals-number rejection.
- `_handleConferenceLegConnected` migrates `_pendingConferenceLegLabel`
  into `ConferenceCallLeg.displayName` when calling
  `conferenceService.addLeg(...)`, so durable attribution survives
  after the pending fields clear.
- In `_onTranscript`, when `isRemote && (_callPhase == onHold ||
  sipHelper.calls.length > 1)`, the transcript is reattributed:
  - **Manager held** → unambiguous: only the secondary leg is producing
    audio. Use the resolved secondary label.
  - **Both legs bridged** → ambiguous on audio alone. Use voiceprint
    diarization (high-confidence only) as a per-utterance hint; otherwise
    fall back to the secondary label. If neither resolves, use
    `"Other party"` rather than ever falsely attributing to the primary.
- The persistent `remoteSpeaker.name = voiceprintName` claim is now
  skipped while conference is active so a secondary-leg voiceprint match
  can't permanently overwrite the primary caller's name.
- The reattributed label flows through `_addOrMergeTranscript`,
  `callHistory.addTranscript`, and the LLM context line
  (`[Delta Airlines]: ...` instead of `[Patrick]: ...`).

### P7: One-shot system context for the bridged conference
- When a leg starts ringing, the LLM gets `[system]: Dialing <Label>
  (<E164>) ...` so it knows who is being added.
- When the leg connects, the LLM gets `[system]: Conference is now
  bridged. <Primary> (primary) and <Secondary> (<E164>, secondary)
  are both on the line.` so it has unambiguous context for the
  multi-party transcripts that follow.

### P8: Spoken hold announcement to the primary caller
- Before placing the primary leg on hold, the agent now speaks a brief
  natural-language announcement to the caller — e.g. *"One moment — I'm
  going to put you on a brief hold while I connect Delta Airlines"* —
  resolved using the same friendly label that drives transcript
  attribution. They're never dropped into dead silence unannounced.
- The announcement uses `speakToCurrentCaller(text, timeout: 5s)`, which
  was upgraded as part of this change to also work in the split
  pipeline:
  - **Realtime pipeline** → `_whisper.sendSystemDirective(...)` (existing
    behavior).
  - **Split pipeline** → `_textAgent.sendUserMessage(...)` with a
    `[HOLD TRANSITION]` directive prefix that forces an immediate Claude
    response, which then flows out through the configured TTS provider
    (ElevenLabs / Kokoro / Pocket).
- The call awaits TTS drain before issuing the SIP `hold()` re-INVITE so
  the announcement isn't clipped mid-sentence by the resulting media
  pause. The announcement is best-effort — TTS failures are caught and
  logged; the dial proceeds either way so a flaky pipeline never blocks
  conferencing.

## Files

### Modified
- `phonegentic/lib/src/agent_service.dart`
  - `_primaryHeldForConference` flag and lifecycle
  - `_pendingConferenceLegLabel` field
  - `_handleAddConferenceParticipant` — up-front label resolution,
    spoken hold announcement (awaits TTS drain), hold flag set, system
    context line
  - `speakToCurrentCaller` — now routes through `_textAgent` in split
    pipeline mode in addition to the realtime pipeline
  - `_handleConferenceLegConnected` — auto-unhold via flag, addLeg with
    displayName, post-merge system context
  - `_handleConferenceLegDropped` — flag reset, primary restore
  - `_AgentSipListener.callStateChanged` — restricted connection trigger
    to `CONFIRMED` / `ACCEPTED`, late-capture fallback for pending leg id
  - `_onTranscript` — per-utterance reattribution (replacing prior
    suppression block); voiceprint hint as primary disambiguator in the
    bridged case
  - `_resolveSecondaryLegLabel()` — new helper
  - `_lookupContactName()` — new helper
  - voiceprint persistence guard now skips conference state

- `lib/src/rtc_session.dart` — SDP `a=mid:` / `a=group:BUNDLE` /
  `a=rtcp-mux` handling for hold/unhold re-INVITEs

- `phonegentic/macos/Runner/AudioTapChannel.swift` —
  `setAPMConferenceMode` keeps AEC + HPF enabled, disables only NS / AGC;
  `enterCallMode` / `exitCallMode` ref-counted

- `phonegentic/lib/src/conference/conference_service.dart` —
  `addLeg(displayName:)` is honored end-to-end so attribution helpers can
  read it back

## Notes

- Reattribution is intentionally per-transcript and never mutates
  `remoteSpeaker.name`. The primary caller's identity remains the
  authoritative label for the primary leg across the life of the call.
- In a fully bridged 3-way conference both parties share the remote bus,
  so attribution can't be perfect from audio alone. We bias toward the
  secondary leg (the more common talker after the manager initiates a
  conference) and let voiceprint refine per-utterance when it has a
  confident match.
- "Other party" is a deliberate last-resort label — it's better to be
  vague than to falsely attribute speech to the primary caller and have
  the LLM act on it as if the manager had said it.
