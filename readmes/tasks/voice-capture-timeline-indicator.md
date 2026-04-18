# Voice Capture Timeline Indicator

## Problem

When the agent captures voice for cloning, only a static "Voice sampling started" system message appeared in the timeline — and it showed up after the user talked, with no live feedback. There was no way to tell at a glance that capture was actively happening, how long it had been running, or when it ended. The timing in the timeline didn't reflect reality.

## Solution

Added a live voice capture bubble to the message timeline that shows a pulsing red recording dot and a running timer while sampling is active. When capture ends, the bubble finalizes to show the duration and result.

**Agent service changes:**
- Added `_agentSamplingStartTime` and `_samplingMessageId` fields to track the live capture state
- Exposed `agentSampling` and `agentSamplingStartTime` as public getters for the UI
- `_handleStartVoiceSample` now inserts a `ChatMessage` with `isStreaming = true` and `voice_capture: true` metadata instead of a plain system message
- Added `_finalizeSamplingMessage()` helper that updates the streaming message to its final state (showing captured duration or failure) when sampling stops
- `_handleStopAndCloneVoice` and `_disconnect` both call `_finalizeSamplingMessage()` to ensure the bubble is always finalized

**Agent panel changes:**
- `_MessageBubble` now checks for `voice_capture` metadata and routes to a dedicated `_VoiceCaptureBubble` widget
- `_VoiceCaptureBubble` is a `StatefulWidget` with:
  - A pulsing red dot (matching the voice clone modal's style) while live
  - A 1-second tick timer showing elapsed capture time (MM:SS)
  - Accent-colored border and label while active
  - Subdued mic icon and final text when capture completes
  - Automatic cleanup when the message transitions from streaming to finalized

## Files

- `phonegentic/lib/src/agent_service.dart` — sampling state tracking + finalization
- `phonegentic/lib/src/widgets/agent_panel.dart` — `_VoiceCaptureBubble` widget + routing
