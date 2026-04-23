# `/search` recap not spoken aloud

## Problem

Completing a `/search` populated the inline result card correctly but
the agent never announced the recap out loud. Even with TTS unmuted
and the voice pipeline connected, nothing was spoken.

Root cause was a combination of two things:

1. **Brief wording** — the previous directive said
   `"Brief them concisely: what happened recently, what needs
   follow-up. Do NOT read the raw lists back verbatim."`. With the
   `[SEARCH RECAP]` bracket tag and no explicit "speak this aloud"
   instruction, Claude (text agent) and the Realtime voice model
   often treated the payload as passive context and produced no
   spoken reply.

2. **Dispatch path** — `sendSystemEvent(..., requireResponse: true)`
   double-dispatches: it sends a whisper directive *and* pushes
   `[SYSTEM EVENT]: [SEARCH RECAP] …` into the text agent as a host
   message. The `[SYSTEM EVENT]:` prefix pushed the content further
   toward "metadata" in the model's mental model, and in
   split-pipeline mode (text agent + TTS) the whisper branch bails
   early because `_active` is false, so only the text-agent prefix
   path ran — often yielding no audible reply.

## Solution

Added a dedicated "speak this now" dispatch helper and rewrote the
`/search` brief as an explicit imperative directive.

### `AgentService.announceToManager(String directive)`

Best-effort routing that hits the one live speaking pipeline:

- **Split pipeline** (Claude text agent + local TTS): calls
  `_textAgent.sendUserMessage(directive)` which flushes pending
  context and triggers `_respond()` → streamed response → TTS.
- **Whisper-only** (OpenAI Realtime voice): calls
  `_whisper.sendSystemDirective(directive)` which issues
  `response.create` so the model speaks.
- **Neither live**: logs and bails — the inline card is still on
  screen, so the manager isn't blocked.

This replaces the ambiguous `sendSystemEvent` double-dispatch for
one-off "speak this aloud" moments. It also adds `debugPrint` traces
so we can see which pipeline handled the announcement.

### Rewritten recap directive

`executeSearchGuide` now emits a structured directive that:

1. Opens with a plain-English "the manager just ran /search for X"
   framing (no `[SEARCH RECAP]` tag — that was tripping up the model).
2. Explicitly tells the agent **"Give a short, warm spoken recap
   (1–3 sentences, ~15 seconds)"** — an imperative it can act on.
3. Reminds the agent the card is already on screen so it doesn't
   read rows verbatim.
4. Includes the counts line (e.g. `"3 calls · 2 messages · 1 note"`)
   and the full structured payload after `Here is what was found:`
   so the agent has facts to cite.
5. Ends by asking the agent to offer to dig deeper ("want me to dig
   into any of these?") so the interaction feels collaborative, not
   one-shot.

### Behaviour matrix

| Pipeline state                        | Before           | After                  |
|---------------------------------------|------------------|------------------------|
| Split pipeline, TTS unmuted           | Usually silent   | Announces aloud        |
| Split pipeline, TTS muted             | Silent           | Still silent (TTS gate) |
| Whisper voice active                  | Sometimes spoke  | Announces aloud        |
| No live pipeline (pre-connect)        | Silent           | Logged, silent         |

## Files

- `phonegentic/lib/src/agent_service.dart`
  - New `announceToManager(String directive)` helper.
  - `executeSearchGuide` now builds a plain-English imperative
    directive and dispatches via `announceToManager` instead of
    `sendSystemEvent(..., silent: true, requireResponse: true)`.
