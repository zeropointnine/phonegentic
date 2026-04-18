# Agent falsely believes call ended after hearing "Bye"

## Problem

During an active inbound call, Whisper transcribed a short fragment "Bye." while TTS was playing. The barge-in logic correctly suppressed it (< 3 words during speak), but queued it in `_pendingTranscripts`. After TTS finished and the echo guard window passed, the fragment was flushed and sent to the LLM as user speech. The LLM interpreted it as the caller saying goodbye and hallucinated a `[CALL_STATE: Ended]` response — a system-only tag that only the system should generate. This poisoned all subsequent LLM turns: the agent kept insisting "the host hung up" even though the SIP call was still active (BYE didn't arrive for another 45 seconds).

## Solution

Three-layer fix:

1. **Drop single-word fragments during flush** — In `_flushPendingTranscripts`, fragments buffered during TTS playback that contain fewer than 2 words are now dropped. Single-word fragments like "Bye.", "Yeah.", "Call." are almost always echo residue or Whisper hallucinations from TTS audio bleed.

2. **Strip hallucinated `[CALL_STATE]` from LLM output** — Added a regex check in `_appendStreamingResponse` that detects `[CALL_STATE: ...]` patterns in the LLM's final response text. If found, the tags are stripped. If the entire response was just a hallucinated state tag, the response is discarded entirely. This prevents the LLM from injecting fake state transitions into its own conversation history.

3. **System prompt rule** — Added explicit instruction in `## Call State Awareness` telling the LLM it must NEVER generate `[CALL_STATE: ...]` tags (system-only), and that a caller saying "bye" does NOT mean the call has ended — only the system `[CALL_STATE: Ended]` determines that.

## Files

- `phonegentic/lib/src/agent_service.dart` — Added minimum word filter in `_flushPendingTranscripts`; added `_hallucinatedCallStateRe` regex + stripping logic in `_appendStreamingResponse`
- `phonegentic/lib/src/models/agent_context.dart` — Added CALL_STATE generation prohibition rule in Call State Awareness section
