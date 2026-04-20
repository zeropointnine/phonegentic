# STT Echo Test Command

## Problem

There's no quick way to verify that the speech-to-text pipeline is working correctly end-to-end. When STT issues arise (echo leaks, hallucinations, garbled text), diagnosing requires reviewing logs and guessing what went wrong. A simple call-and-response test where the agent says something known, the caller repeats it, and the agent reads back what the STT heard would make problems immediately obvious.

## Solution

Add a `/stttest` slash command in the agent panel. When triggered, the agent:

1. Says a short nursery rhyme clearly
2. Asks the caller to repeat it back word-for-word
3. Repeats back exactly what the STT transcribed

This creates an easy A/B comparison: the known source text vs what the STT actually captured.

## Files

- `phonegentic/lib/src/widgets/agent_panel.dart` — added `/stttest` to `_expandCommand`
