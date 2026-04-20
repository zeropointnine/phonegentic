# Conference avatar speaking pulse & phone number

## Problem

Two issues in the conference call screen's party avatars:

1. **No speaking pulse**: The green pulsing glow behind a party's identicon never appears, even when the party is clearly speaking (remoteRMS > 0 in logs). Root cause: the audio level polling at `_startConfLevelPolling()` was gated on `isConference && conf.hasConference`, but `hasConference` requires `_conferenceId` to be set (i.e. a formal merge). The native `WebRTCAudioProcessor` enters conference mode and allocates slots as soon as a second leg is created — well before a merge — so the polling condition was too strict.

2. **No phone number under identicon**: When a contact name resolved, only the name was shown as the label. The phone number was not visible, making it hard to identify which line is which in a multi-party call.

## Solution

### Phase 1 — Fix polling + add phone number

1. Changed the polling guard from `isConference && conf.hasConference` to just `isConference` (which is `conf.hasConference || conf.legCount >= 2`). This starts level polling as soon as there are ≥ 2 legs, matching when the native audio processor actually begins tracking per-slot RMS.

2. Added a second `Text` widget beneath the name label showing the formatted phone number (via `demoMode.maskPhone`). Only appears when the label is a real contact name (not already a phone number).

### Phase 2 — Bigger identicons, full text, Apple-style pulse

1. **Identicon size**: 56 → 76, padding between avatars 8 → 14.

2. **Text truncation removed**: Dropped the `ConstrainedBox(maxWidth)` wrapper and `TextOverflow.ellipsis` so names and phone numbers render in full.

3. **Smoothed RMS levels**: Added `_smoothedLevels` with exponential decay interpolation (attack k=0.35, release k=0.15) polled at 80ms. This prevents jittery snapping between frames.

4. **Layered glow animation**: Replaced single `BoxShadow` with three concentric layers that pulse out of phase:
   - Inner: tight ambient glow proportional to RMS intensity
   - Mid: pulses with animation value `v`, expanding with the beat
   - Outer: pulses with inverse `(1−v)`, creating a counter-phase ripple effect

   Intensity is continuous (0–1 normalized from RMS) rather than boolean, so the glow scales smoothly with voice volume.

5. **Faster animation cycle**: 1500ms → 900ms with `easeInOutSine` curve for a smoother, more organic breathing rhythm.

### Phase 3 — Revert to single-call view when a party drops

When a leg dropped from a 2-party conference, the UI stayed in conference mode showing "In Conference" with a single avatar. Two root causes:

1. `ConferenceService.removeLeg` only cleared `_conferenceId` when `_legs.isEmpty`. With 1 leg remaining, `hasConference` stayed `true`.
2. `callscreen.dart` defined `isConference = conf.hasConference || conf.legCount >= 2`. The stale `hasConference` kept the conference view alive.

Fixes:
- `removeLeg` now clears `_conferenceId` / `_conferenceName` when `_legs.length < 2`
- `isConference` simplified to `conf.legCount >= 2` — only shows conference view when there are actually 2+ active legs

### Phase 4 — Speaking pulse on single-call identicon

Extended the speaking pulse to the non-conference single-call view:

1. **Native**: Added `lastRemoteRMS` property to `AudioTapChannel.swift`, stored during each flush cycle. Exposed via new `getRemoteAudioLevel` method channel handler.

2. **Flutter**: Added `_singleLevelTimer` polling at 80ms with the same smoothed exponential decay. `_buildSingleCallAvatar` wraps the 88px identicon with the same three-layer glow animation used in conference mode (scaled up slightly for the larger avatar). Polling starts when a call is confirmed and not on hold; stops when entering conference mode or when the call is on hold.

## Files

- `phonegentic/lib/src/callscreen.dart` — fixed polling condition, updated `_buildConferenceAvatars`, simplified `isConference` check, added `_buildSingleCallAvatar` with pulse
- `phonegentic/lib/src/conference/conference_service.dart` — dissolve conference when legs drop below 2
- `phonegentic/macos/Runner/AudioTapChannel.swift` — added `lastRemoteRMS` property and `getRemoteAudioLevel` method channel
