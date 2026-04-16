# Claude API tool_result Ordering, Voicemail Detection & Transcript Collapsing

## Problem

### Phase 1 — API errors and UI issues

1. **Claude API 400: tool_result ordering** — The `TextAgentService.addToolResult` method placed `LlmTextBlock` (from `_pendingContext`) *before* the `LlmToolResultBlock` in the user message. Claude's API requires `tool_result` blocks to appear immediately after the preceding assistant `tool_use`, so any text before the result caused: `messages.22: tool_use ids were found without tool_result blocks immediately after`.

2. **Multiple transcript rows for same speaker** — Each STT chunk (arriving every ~1.5s from WhisperKit or cloud STT) created a new `ChatMessage.transcript`, resulting in many tiny bubbles for a single continuous utterance. The user expected consecutive lines from the same speaker to be collapsed into one message.

3. **pubspec.yaml whisper-ggml directory error** — `flutter: assets: - models/whisper-ggml/` referenced a directory that doesn't exist, causing build errors on restart.

4. **Missing Whisper hallucination tags** — Bracketed tags like `[CLICK]`, `[clicking]`, `[typing]`, `[COUGH]`, `[Sighs]` were not in the filter and appeared in the transcript.

### Phase 2 — Voicemail false-positive and orphaned tool_result

5. **Agent talked over voicemail greeting** — "Your call." was classified as human (score=0.90) during settle, prematurely promoting to connected. Root cause: IVR detector used substring matching (`String.contains`), so the human greeting "yo" matched inside "your". After promotion, the agent's pre-greeting played over the voicemail announcement ("has been forwarded to an automated voice messaging system... or press 1 for more").

6. **Beep tone ignored** — Native Goertzel filter correctly detected a 400ms beep tone (voicemail recording beep), but the beep was ignored because `_ivrHeard` was `false` — the transcript was misclassified as human before the beep arrived.

7. **Claude API 400: orphaned tool_result** — After the `end_call` tool, SIP hangup triggered call phase → ended, which called `_textAgent?.reset()` (clearing all history). The tool result for `end_call` was delivered *after* the reset, creating a user message with `tool_result` but no preceding assistant `tool_use`.

## Solution

### 1. tool_result ordering (text_agent_service.dart)

- Swapped the order in `addToolResult`: `LlmToolResultBlock` is now always the first content block, with any pending text appended *after* it.
- Added `_reorderUserToolResults` in `_mergedHistory()` — a post-merge pass that moves all `LlmToolResultBlock`s before `LlmTextBlock`s in every user message. This is defense-in-depth against the merge of consecutive user messages reintroducing text-before-result ordering.

### 2. Transcript collapsing (agent_service.dart)

- Added `_addOrMergeTranscript` helper with a 12-second merge window. If the last message in `_messages` is a transcript from the same `ChatRole`, not from a previous call, and within the window, the new text is appended to the existing bubble instead of creating a new one.
- Updated all 3 transcript insertion paths (main `_processTranscript`, pre-greeting settle drain, and `_drainSettleTranscripts`) to use the helper.

### 3. pubspec.yaml fix

- Removed the `models/whisper-ggml/` asset entry since the directory doesn't exist. WhisperKit models are loaded from a separate native path, not Flutter assets.

### 4. Hallucination filter expansion (agent_service.dart)

- Extended `_whisperBracketedTagRe` to cover: `CLICK`, `click`, `clicking`, `typing`, `COUGH`, `cough`, `Sighs`, `sighs`, `breathing`, `sneezing`, `clearing throat`.

### 5. IVR detector word-boundary matching (ivr_detector.dart)

- Replaced `String.contains` with `_containsPhrase` which checks word boundaries before and after the match position. Prevents "yo" from matching inside "your", "hi" inside "this", etc.
- With this fix, "Your call." is classified as `human, score=0.6` (below the 0.7 promotion threshold) instead of `human, score=0.9`. The settle phase continues until the next transcript fragment ("has been forwarded to an automated") which correctly triggers IVR detection.

### 6. Beep detection independence (agent_service.dart)

- Removed the `_ivrHeard` requirement from `onBeepDetected`. A beep tone during the settle/early-connected window is now a standalone voicemail signal — it sets `_ivrHeard = true` and proceeds to the voicemail prompt flow.
- This is defense-in-depth: even if the IVR detector misclassifies the greeting text, the beep tone still triggers correct voicemail handling.

### 7. Orphaned tool_result guard (text_agent_service.dart)

- `addToolResult` now checks that the history contains an assistant message with a matching `tool_use` ID before adding the result. If no match is found (history was reset), the orphaned result is dropped with a debug log instead of triggering a 400 error.

## Files

| File | Change |
|------|--------|
| `phonegentic/lib/src/text_agent_service.dart` | Reordered tool_result before text; added `_reorderUserToolResults` to merged history; added orphaned tool_result guard |
| `phonegentic/lib/src/agent_service.dart` | Transcript collapsing via `_addOrMergeTranscript`; expanded hallucination filter; beep detection no longer requires `_ivrHeard` |
| `phonegentic/lib/src/ivr_detector.dart` | Word-boundary-aware phrase matching in `_containsPhrase` |
| `phonegentic/pubspec.yaml` | Removed non-existent `models/whisper-ggml/` asset entry |
