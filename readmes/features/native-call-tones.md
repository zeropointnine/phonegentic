# Native Call Tones (DTMF, Call-Waiting, Call-Ended)

## Problem

The app had no audible feedback for telephony events that operators expect from a hardware phone:

- **Touchtones** — pressing a DTMF key on the in-call dialpad sent the digit
  via SIP but produced no local sound, so the operator had no confirmation
  the press was registered.
- **Call-waiting** — when a second inbound call arrived during an active
  call, only a visual toast appeared. The operator (and the optional AI
  manager-agent) had no audible cue.
- **Call-ended** — when the remote party hung up, the call simply went
  silent. There was no "they hung up" cue equivalent to a hardware phone's
  three-tone disconnect.

We also need a settings surface so the user can pick the touchtone style
(modern DTMF or vintage AT&T MF "Blue Box" tones), toggle each event tone
on or off, and optionally let the agent announce inbound/ended calls
audibly to the manager — which becomes important when the agent itself is
acting as the manager-facing voice.

## Solution

A small native tone synthesizer on macOS and iOS plays short PCM tone
bursts directly via `AVAudioEngine` so the operator hears them whether
or not a SIP call is active (e.g. typing on the dialer pre-call, in-call
DTMF, or call-waiting/ended events). On macOS the synthesizer also
copies tones into `WebRTCAudioProcessor.ttsRecordingRing` while a call
recording is in progress so the WAV captures the same cues the operator
heard. Tones are intentionally **not** written to the outbound capture
ring — DTMF for the remote party still travels via SIP signaling, and
local key feedback should not bleed into the remote's audio.

### Tone palette

| Event              | Pattern                                                 |
|--------------------|---------------------------------------------------------|
| Touch tone (DTMF)  | Standard 697/770/852/941 × 1209/1336/1477/1633 Hz pair  |
| Touch tone (Blue)  | AT&T MF Blue-Box pair (700/900/1100/1300/1500/1700 Hz)  |
| Call-waiting       | 2 × 220 ms beeps at 440 Hz, 200 ms gap                  |
| Call-ended         | 3 × 180 ms beeps at 480/620 Hz alternating, 80 ms gap   |

### Touchtone press behaviour

Per the spec: a DTMF key plays for **at least 300 ms**, or as long as the
key is depressed — whichever is longer. Implementation:

1. `tapDown` → native `playToneStart(key, style)` opens an indefinite tone.
2. `tapUp` (or cancel) → Flutter waits until at least 300 ms has elapsed
   since press, then calls `playToneStop`.
3. The native side keeps the oscillator running until `playToneStop` is
   received, so a long-press plays the entire press duration.

Touchtone playback is **only wired to the main pre-call dialer keypad**
in `dialpad.dart`. The in-call DTMF pad in `callscreen.dart` only sends
SIP DTMF — it does not invoke the local tone generator, so there is no
risk of the local tone leaking into the outbound mix or echoing the
remote PBX's own DTMF feedback.

### Settings (per-user, persisted via `SharedPreferences`)

The Tones section lives in **Settings → Phone → Tones** (alongside the
SIP, conference, HD-codec, and call-recording cards) and is also
surfaced as a shortcut in the long-press popover on the bell/ring icon
in the dialpad toolbar. Each setting persists via `SharedPreferences`
and **rides along with the rest of the phone settings on
export/import** via `SettingsPortService.exportSection(sipSettings, …)`:

- **Touchtone playback** — toggle + style picker (`DTMF` | `Blue Box`)
- **Call-waiting tone** — toggle + sub-checkbox "Allow Agent to announce"
- **Call-ended tone** — toggle + sub-checkbox "Allow Agent to announce"

When the active SIP call's remote party is the configured agent manager
(i.e. the agent is talking to the operator/manager rather than to a
third-party caller), the "Allow Agent to announce" behavior is
force-enabled at runtime regardless of the toggle, since the manager
needs to know about new inbound calls and call-ended events even when
not looking at the screen.

### Phase-continuous synthesis

Tones longer than one chunk (the held DTMF/MF press path) are
synthesised in 60 ms chunks, but each chunk starts at the cumulative
sample index of the previous chunk rather than at phase zero. Without
this the sine wave restarts at sample 0 on every chunk, which is
inaudible for the Blue-Box MF set (all multiples of 100 Hz happen to
fall on integer cycles per 60 ms at 24 kHz) but produces a click every
60 ms for DTMF — perceptually like the key rapidly retriggering.
Threading a `sampleOffset` through the synthesizer keeps the oscillators
phase-continuous across chunk boundaries.

### Native ↔ Flutter contract

`MethodChannel('com.agentic_ai/audio_tap_control')` adds:

| Method            | Args                            | Effect                          |
|-------------------|----------------------------------|---------------------------------|
| `playToneStart`   | `{key: String, style: String}` | Begin tone for a DTMF key       |
| `playToneStop`    | `{key: String}`                | Stop tone for a key             |
| `playToneEvent`   | `{event: String}`              | Fire fixed pattern (waiting/ended) |

`event` ∈ `{'callWaiting', 'callEnded'}`.

### Architecture

```
Flutter ToneService ─► MethodChannel ─► AudioTapChannel
                                          └► ToneGenerator (Float32 @ 24 kHz)
                                              ├► AVAudioEngine ─► local speaker
                                              └► WebRTCAudioProcessor.ttsRecordingRing
                                                    └► call recording WAV
                                                       (only when a recording is active)
```

The capture/outbound ring is intentionally bypassed so the remote does
not hear the local key feedback; DTMF for the remote party travels via
SIP signaling per the existing call flow.

## Files

- `readmes/features/native-call-tones.md` (this file)
- `phonegentic/macos/Runner/ToneGenerator.swift` (new)
- `phonegentic/ios/Runner/ToneGenerator.swift` (new)
- `phonegentic/macos/Runner/AudioTapChannel.swift` (extend)
- `phonegentic/ios/Runner/AudioTapChannel.swift` (extend)
- `phonegentic/macos/Runner.xcodeproj/project.pbxproj` (add ToneGenerator)
- `phonegentic/ios/Runner.xcodeproj/project.pbxproj` (add ToneGenerator)
- `phonegentic/lib/src/tone_service.dart` (new)
- `phonegentic/lib/main.dart` (register provider)
- `phonegentic/lib/src/widgets/action_button.dart` (onPressDown/onPressUp callbacks)
- `phonegentic/lib/src/dialpad.dart` (main dialer keypad press/hold/release, settings popover, call-waiting/ended triggers — this is the only keypad that drives the tone generator; in-call DTMF stays local-silent and only sends SIP signaling)
- `phonegentic/lib/src/register.dart` (Tones card in the Phone settings tab)
- `phonegentic/lib/src/settings_port_service.dart` (tone prefs round-trip with SIP settings)
- `phonegentic/lib/src/agent_service.dart` (`isCurrentRemoteAgentManager` getter so announcements force-on for manager calls)
