# Vocal Expressions for Human-Like Agent Speech

## Problem

The agent sounds robotic because it lacks the non-verbal vocal cues that make human conversation feel natural — laughing, sighing, gasping, thinking aloud with "hmm", expressing sympathy with "aww", etc. Real humans punctuate speech with these sounds constantly, and their absence is a dead giveaway that the voice is synthesized.

There is no mechanism for the LLM to express paralinguistic cues that translate into audible vocal sounds through the TTS pipeline. The existing `[bracket]` stripping suppresses stage directions entirely rather than converting them to speakable sounds.

## Solution

Introduce a **vocal expression system** using `{expression}` curly-brace markers that the agent embeds in its text output. A streaming-safe parser intercepts these markers before TTS and replaces them with phonetic text that ElevenLabs/Kokoro render as natural vocal sounds in the agent's own voice.

Key design decisions:
- **Curly braces** `{}` as a distinct namespace from the existing `[]` bracket stripping
- **TTS-native rendering** — phonetic text replacement instead of pre-recorded clips, so expressions match the agent's voice
- **Streaming-safe parser** — handles expression tags split across multiple LLM deltas
- **System prompt coaching** — teaches the agent when and how to use expressions naturally and sparingly

## Files

### Created
- `phonegentic/lib/src/vocal_expressions.dart` — expression registry, TTS mapping, streaming parser

### Modified
- `phonegentic/lib/src/models/agent_context.dart` — system prompt instructions for vocal expressions
- `phonegentic/lib/src/agent_service.dart` — wired expression processing into TTS pipeline and UI display
