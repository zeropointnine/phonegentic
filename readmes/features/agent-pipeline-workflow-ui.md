# Agent Pipeline Workflow UI

## Problem

The agent settings tab (`agent_settings_tab.dart`) presents Voice Agent, Text Agent, TTS, STT, Mute Policy, Comfort Noise, and Export/Import as a flat vertical list of cards. This makes the audio pipeline hard to visualize — users can't see how STT → LLM → TTS flow together, and there's duplicative configuration between the Voice Agent and STT sections. The UI also doesn't communicate the distinction between "voice-agent-only" mode (OpenAI Realtime handles everything) and the separate text-agent pipeline (STT + LLM + TTS as discrete steps).

## Solution

Replace the flat card list with a visual **pipeline workflow** showing three connected stages — STT, LLM, TTS — each with a flip-to-edit interaction. Clicking a pipeline card triggers a 3D flip animation and reveals the relevant settings panel below. Voice Agent settings are consolidated into the STT card. When only the Voice Agent is enabled (Text Agent off), the LLM and TTS cards are grayed out. The layout is responsive: horizontal with chevron arrows on desktop, vertical with down arrows on mobile. Mute Policy and Comfort Noise appear as side-by-side sections below the pipeline on desktop, stacked on mobile. The Export/Import card is removed (to be consolidated under User settings later).

## Files

- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — major UI rewrite
- `phonegentic/assets/brain.svg` — Lucide brain icon (ISC license)
- `phonegentic/pubspec.yaml` — register brain.svg asset
