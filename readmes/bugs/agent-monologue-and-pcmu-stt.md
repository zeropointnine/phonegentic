# Agent Monologues and Premature Greeting on PCMU Calls

## Problem

During outbound calls (especially on PCMU/8kHz routes), three interrelated issues:

1. **Premature greeting text** — "Hi Lee, this is Alice..." appears in the UI during the ringing phase, before the call connects. This happens because the LLM tool chain (search_contacts → make_call → list_voices) completes and generates a greeting response while the call is still ringing. TTS is correctly suppressed but text display is not.

2. **Agent monologues** — after speaking, the agent responds again within 1-2 seconds to garbled PCMU transcripts, interrupting the remote party mid-sentence. The 1500ms debounce is too short for degraded-quality STT.

3. **False beep detections** — on PCMU (8kHz), the coarse frequency resolution causes male-voice harmonics near 440/480Hz to pass the Goertzel filter's 80% energy-concentration threshold and 800ms sustain, triggering 3+ false "Beep tone DETECTED" events per call. These are correctly ignored by AgentService but add log noise.

### Root causes

- **PCMU codec** — Telnyx intermittently routes calls through media gateways that only offer PCMU/8kHz. The limited 4kHz Nyquist bandwidth degrades STT quality significantly.
- **No pre-connect text suppression** — `_appendStreamingResponse` suppressed TTS during ringing/settling but still displayed text in the chat UI.
- **Short debounce** — 1500ms TextAgent debounce is not enough time for garbled PCMU transcripts to accumulate into meaningful sentences.
- **Loose beep thresholds** — 80% energy concentration and 800ms sustain were too permissive for 8kHz audio.

## Solution

### Phase 1: `_hasTranscriptPending` guard (previous fix)

Added flag in `TextAgentService._respond()` finally block — auto-flush only fires when a real `addTranscript()` call occurred, preventing system-context-only monologues.

### Phase 2: Three additional fixes

**1. Pre-connect text suppression (`agent_service.dart`)**

Added a check in `_appendStreamingResponse` (after the `_preGreetInFlight` buffer) that drops all responses during pre-connect phases (ringing, answered, settling) — both text AND TTS are suppressed. The pre-greeting mechanism handles what to display and when.

**2. In-call debounce increase (`text_agent_service.dart`)**

Made `_debounceMs` dynamic with an `inCallMode` setter:
- Default (idle): 1500ms — responsive for text-based interaction
- In-call: 3500ms — gives remote party time to finish speaking before the agent responds

Combined with the 2s echo guard, the agent now waits ~5.5s of silence after speaking before generating a new response.

**3. Stricter beep detection thresholds (`WebRTCAudioProcessor.swift`)**

- Energy concentration: 80% → 92% — eliminates speech harmonics on 8kHz
- Sustain requirement: 800ms → 1200ms — real voicemail beeps are 0.8–2s, speech rarely sustains a pure tone that long

## Files

| File | Change |
|------|--------|
| `phonegentic/lib/src/agent_service.dart` | Pre-connect response suppression; wire `textAgent.inCallMode` on settling/end |
| `phonegentic/lib/src/text_agent_service.dart` | Dynamic `_debounceMs` (1500ms idle / 3500ms in-call); `inCallMode` setter |
| `phonegentic/macos/Runner/WebRTCAudioProcessor.swift` | Goertzel threshold 80% → 92%, sustain 800ms → 1200ms |
