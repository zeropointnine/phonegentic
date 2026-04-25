# Idle-Mode Phantom Call

## Problem

The AI agent initiated a `make_call` to an arbitrary number (303-898-2988) without user intent. Root cause:

1. **SpeakerID "ignoring" doesn't gate transcription** — the Swift-layer SpeakerID logs "ignoring unknown mic user" but WhisperKit transcribes all mic audio regardless.
2. **No transcript logging before LLM** — we couldn't see what text triggered the `make_call` because transcripts forwarded to the TextAgent weren't logged at the point of delivery.
3. **No confirmation for dangerous tools when idle** — `make_call` executes immediately even when triggered from ambient/idle mode with no active call.

## Solution

Three layered fixes:

1. **Log transcript text on delivery to TextAgent** — add a `debugPrint` in `_processTranscript` right before `addTranscript` so we can always see what the LLM received.
2. **Guard `make_call` when idle** — in `_onTextAgentToolCall`, when `_callPhase == CallPhase.idle` and there is no manager authorization, return a `BLOCKED` error result instead of placing the call. The agent must ask the user to confirm, and only proceed when the user explicitly confirms via a follow-up transcript.
3. **Manager-auth bypass (`_managerAuthActive`)** — the manager (configured phone in Settings) does not need a separate confirmation hop; their own request *is* the authorization:
   - `_managerAuthActive` flips **true** when the manager speaks at idle (`_processTranscript`) or sends inbound SMS (`_handleInboundSms`).
   - It flips **false** when a third party sends inbound SMS, so a stranger texting in shortly after the manager cannot ride on the manager's prior auth to coerce the LLM into placing a call.
   - It is sticky (no time expiry) — once the manager has interacted, LLM round-trips, calendar syncs, and other state churn cannot strip the authorization between the request and the eventual `make_call` tool invocation.
   - The guard becomes `_idleCallConfirmed || _managerAuthActive`. Hallucinated calls with no manager-driven context remain blocked.

## Threat model preserved

- **LLM hallucination** (`make_call` with no user input) → blocked: `_managerAuthActive` is `false` at startup until a real interaction grants it.
- **Third-party jailbreak via SMS** → blocked: third-party inbound SMS revokes any prior manager auth, so the LLM's reply to the stranger cannot trigger an autonomous call on the manager's account.
- **Manager request via SMS or voice** → flows through with no extra confirmation prompt.

## Files

- `phonegentic/lib/src/agent_service.dart` — transcript logging, idle call guard, manager-auth bypass
