# Agent voice listing and selection

## Problem

The agent had a `set_agent_voice` tool but it required knowing the raw ElevenLabs voice ID upfront. There was no way for the agent to discover available voices at runtime, so callers couldn't ask "what voices do you have?" or "switch to a different voice" without the ID.

## Solution

Added a `list_voices` tool and enhanced `set_agent_voice` to accept a voice name in addition to a voice ID.

**`list_voices`** — Calls `ElevenLabsApiService.listVoices` and returns all available voices with their name, category, ID, and marks the currently active voice. The agent can present this list to the caller conversationally.

**`set_agent_voice` (enhanced)** — Now accepts an optional `voice_name` parameter. If provided (and `voice_id` is not), it resolves the name to a voice ID via a case-insensitive lookup against the ElevenLabs account's voice list. Supports both exact and partial name matching.

Typical flow: caller asks to change voice -> agent calls `list_voices` -> presents options -> caller picks one -> agent calls `set_agent_voice(voice_name: "Rachel")`.

To enable this for a specific persona, mention voice selection in the job function's description (e.g., "You can list and change your speaking voice when asked").

## Files

- `phonegentic/lib/src/whisper_realtime_service.dart` — added `list_voices` tool schema; added `voice_name` param to `set_agent_voice`
- `phonegentic/lib/src/text_agent_service.dart` — same (LlmTool format)
- `phonegentic/lib/src/agent_service.dart` — added `_handleListVoices` handler; enhanced `_handleSetAgentVoice` with name-to-ID resolution; added dispatch cases in both `_onFunctionCall` and `_onTextAgentToolCall`
