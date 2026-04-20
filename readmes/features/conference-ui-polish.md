# Conference Call UI Polish

## Problem

After merging calls into a conference, several UI issues degrade the experience:

1. **Hold/Resume button shows stale state** — The main call screen action button still reads "Resume" after a merge because `_hold` tracks raw SIP `HOLD`/`UNHOLD` callbacks rather than conference state. The status label also shows "On Hold" instead of "In Conference".

2. **No visual link between merged legs** — Once merged, the `_MergeConnector` disappears and the leg rows in the agent panel appear as disconnected items with no indication they belong to the same conference.

3. **No names under conference identicons** — `_buildConferenceAvatars` shows identicons with tooltips only; participant names are invisible until hovered.

4. **No active-speaker visual cue** — There is no visual distinction between active and held participants in the identicon row on the call screen.

## Solution

1. **Hold/Resume override in conference mode** — When `conf.hasConference` is true, the action button always shows "Hold" (not "Resume") regardless of the raw SIP `_hold` flag. The status label shows "In Conference" instead of "On Hold by ...". This prevents stale hold state from persisting visually after the merge unholds all legs.

2. **Vertical conference bar** — When `hasConference`, the leg rows in `_ConferenceCallBar` are wrapped in an `IntrinsicHeight` + `Row` with a 2px-wide green vertical bar on the left, visually connecting all merged participants. When not yet merged, the existing `_MergeConnector` (vertical line + Merge button) still appears between legs.

3. **Names below identicons** — `_buildConferenceAvatars` now renders a `Column` per participant with the identicon on top and a constrained (72px max-width) name label below, replacing the tooltip-only approach.

4. **Speech-driven pulsing glow on identicons** — Added per-slot RMS tracking in `WebRTCAudioProcessor.confRenderStore`, exposed via a `getConferenceAudioLevels` method channel. The call screen polls every 150ms when in conference mode. Each participant's identicon gets an animated green `BoxShadow` glow only when their RMS exceeds the speech threshold (200), driven by a 1.5s ease-in-out `AnimationController`. Silent participants have no glow.

## Files

| File | Changes |
|------|---------|
| `phonegentic/lib/src/callscreen.dart` | Conference-aware status label and Hold button; names under identicons; conference audio level polling + speech-driven glow |
| `phonegentic/lib/src/widgets/agent_panel.dart` | Vertical green bar spanning merged legs in `_ConferenceCallBar` |
| `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` | Per-slot RMS computation in `confRenderStore`; `confSlotRMS` array |
| `phonegentic/macos/Runner/AudioTapChannel.swift` | `getConferenceAudioLevels` method channel handler |
