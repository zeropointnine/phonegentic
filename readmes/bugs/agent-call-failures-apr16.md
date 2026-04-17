# Agent Call Failures — Apr 16 2026

## Problem

During a sequence of 5 inbound calls (records #239–#243), the agent exhibited multiple failure modes when switching between text agent providers (Claude → GPT-5.4-mini → custom/Gemini).

### Failure 1: GPT-5.4-mini gives lobotomized responses (Calls #240, #241)

Responses collapsed to single sentences like "Hello.", "I'm listening.", "I'm Phonegentic." despite receiving the full system prompt with role-playing instructions, tools, and conversation history. The model also called `stop_and_clone_voice` immediately after `start_voice_sample` (0.6s of audio vs the 3s+ that Claude captured).

### Failure 2: Truncated custom model ID (Call #242)

`google/gemini-3.1-flash-lite-previ` was saved in SharedPreferences (missing `ew`). The `_buildTextField` fires `onChanged` on every keystroke with no validation, so an incomplete string persisted. Caused 3x `400 Bad Request` errors — agent was completely silent.

### Failure 3: WhisperKit ANE timeout (Call #243)

CoreML ANE prediction timed out twice (`E5RT: Submit Async failed... ANE op async execution has timed out`). Killed the entire transcription pipeline — the agent spoke its greeting but never heard the user again.

## Solution

### Failure 3 fix: WhisperKit ANE timeout recovery (implemented)

The root cause was that ANE (Apple Neural Engine) timeouts killed transcription permanently — the error was caught, logged, and the audio window was dropped. No retry, no fallback.

**Three changes in `WhisperKitChannel.swift`:**

1. **Re-queue audio on failure** — when `transcribe()` throws, the audio chunk is pushed back to the front of the buffer (capped at ~3s to prevent unbounded growth). The next timer tick retries it.
2. **CPU fallback after 2 consecutive ANE timeouts** — a `consecutiveAneFailures` counter tracks ANE-specific errors. After `maxAneFailuresBeforeCpuFallback` (2), `rebuildWithCpuFallback()` tears down the current WhisperKit instance and rebuilds with `cpuOnly` compute for both encoder and decoder. Slower but avoids the ANE entirely.
3. **Warning propagated to Dart** — a `warning` key is sent via the EventChannel so the Dart side can log it. Empty text means no phantom transcription is injected into the conversation.

**Dart side (`whisperkit_stt_service.dart`):** Added `warning` field logging from native events.

### Failures 1 & 2: TBD
1. Validate custom model ID at save/use time
2. Simplify prompt or restrict model options for smaller models

## Files

- `phonegentic/macos/Runner/WhisperKitChannel.swift` — ANE timeout recovery + CPU fallback
- `phonegentic/lib/src/whisperkit_stt_service.dart` — warning logging from native events
- `phonegentic/lib/src/agent_config_service.dart` — TextAgentConfig, custom model storage
- `phonegentic/lib/src/text_agent_service.dart` — LLM caller routing
- `phonegentic/lib/src/llm/openai_caller.dart` — error handling for OpenAI-compatible APIs
- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — custom model text field
- `phonegentic/lib/src/agent_service.dart` — system prompt builder, WhisperKit integration
