# Turn-Taking UI Indicators

## Problem

The agent panel status label switches instantly between "Speaking" and "Listening" with no visual buffer, making it hard for the user to tell when the mic is actually active. There's also no visual feedback in the conversation when the agent is processing (between receiving user speech and starting its response), leaving the user uncertain whether the agent heard them.

## Solution

### 1. Delayed status transition (0.5s)

Converted `_AgentHeader` from `StatelessWidget` to `StatefulWidget` with a `_showSpeaking` flag. When `agent.speaking` transitions from `true` to `false`, a 500ms timer delays the status label switch. This gives the user a clear visual cue that the mic is about to become active, matching the actual ~0.5s echo guard buffer in the audio pipeline. Immediate transition in the opposite direction (Listening → Speaking).

Added a new "Thinking..." status (with amber color) that shows when the agent has received a transcript and is waiting for the LLM to start responding.

### 2. Three-dot typing indicator in conversation

Added a `_ThinkingBubble` widget — a left-aligned bubble with three animated bouncing dots that appears at the bottom of the message list when `agent.thinking` is true. The animation uses staggered sine-wave offsets with opacity fading for a polished feel.

### 3. Thinking state in AgentService

Added `bool _thinking` field that is:
- Set `true` when `_textAgent?.addTranscript()` sends user speech to the LLM
- Set `false` when the first streaming response token creates a new message, or when any TTS engine reports `speaking = true`

## Files

- `phonegentic/lib/src/agent_service.dart` — Added `_thinking` field, getter, and state transitions
- `phonegentic/lib/src/widgets/agent_panel.dart` — Converted `_AgentHeader` to StatefulWidget with delayed transition, added `_ThinkingBubble`, passed `thinking` to `_MessageList`
