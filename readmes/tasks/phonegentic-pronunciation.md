# Phonegentic TTS pronunciation fix

## Problem

The agent was mispronouncing "Phonegentic" as "phonagentic" or similar. The LLM rule (Rule #12 in `agent_context.dart`) told the model how to pronounce it, but ElevenLabs TTS reads raw text and applies its own phonetic interpretation — it ignores LLM instructions.

## Solution

Two-layer fix:

1. **LLM rule updated** (`agent_context.dart` Rule #12): Clarified the pronunciation as two syllable groups — PHONE + GENTIC ("Phone-JEN-tick"). Lists common mispronunciations to avoid.

2. **TTS-level substitution** (`agent_service.dart`): Added a regex replacement in `_activeTtsSendText()` — the single funnel point for all TTS output. Every occurrence of "Phonegentic" (case-insensitive) is replaced with "Phone-Jentic" before being sent to ElevenLabs/Kokoro. The chat UI still displays "Phonegentic" since the substitution only happens in the TTS path.

## Files

- `phonegentic/lib/src/models/agent_context.dart` — updated Rule #12 pronunciation guide
- `phonegentic/lib/src/agent_service.dart` — added `_phonegenticRe` regex and substitution in `_activeTtsSendText()`
