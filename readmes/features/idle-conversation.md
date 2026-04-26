# Idle Conversation (Wake-Word + Session)

## Problem

The agent's mic is always capturing audio even when there's no active call, but on-device WhisperKit transcription is paused at idle to save CPU and stop hallucinated transcripts from silence. That keeps things efficient, but it also means the agent is fully deaf between calls — you can't ask it to do anything (look up a contact, kick off an outbound, summarize the last call) without first dialing into yourself.

The user wanted assistant-style behavior: say a wake phrase from across the room, have a normal back-and-forth conversation, and have the session quietly close when the conversation is over — without having to repeat the wake phrase before every reply.

## Solution

A single new feature, gated by an opt-in `IdleConversationConfig`, layers a wake-word + open-session state machine on top of the existing on-device STT pipeline. None of the in-call code paths change; this purely controls whether idle-phase transcripts are *routed* to the LLM (and answered through Pocket TTS) or dropped as background chatter.

**State machine.** Two states inside `_callPhase == idle`:

- **Sleeping** — `_idleSessionActive == false`. Whisper inference is running (the wake word can't be detected if it isn't), but every transcript that doesn't start with a wake alias is dropped as background chatter.
- **Listening (session open)** — `_idleSessionActive == true`. Every transcript routes to `TextAgentService.addTranscript()` with the wake-word prefix stripped; agent replies stream out through Pocket TTS just like an in-call turn. A rolling silence timer is reset on every user transcript and every agent final, so back-and-forth conversation keeps the window open indefinitely.

**Wake-phrase resolution.** Aliases are derived dynamically from `AgentBootContext.name` (the active persona's name) plus the universal "agent" / "hey agent" / "ok agent" fallbacks. The full set is sorted longest-first and compiled into a single anchored regex with optional comma/colon/dash separator after the alias, so `"Hey Alice, what time is it?"` matches the longer `"Hey Alice"` alias before the shorter `"Alice"` alias and the body — `"what time is it?"` — is what the LLM actually sees. Saying just `"Alice"` opens the session without dispatching anything; the next utterance is the real ask.

**Session lifecycle.** A session ends on any of:

1. The configurable silence timeout (default 60 s, slider in Settings goes 15–180 s) — `Timer` armed in `_resetIdleSessionTimer`, fired in `_endIdleSession(reason: 'silence timeout')`.
2. A close phrase — `_idleSessionCloseRe` matches short utterances that *only* contain `thanks`, `goodbye`, `bye`, `stop listening`, `never mind`, `that's all`, etc. It deliberately does not match `"thanks for that, also..."` so the session can't be dropped mid-thought.
3. A real call starting — `notifyCallPhase` calls `_endIdleSession(reason: 'call started: <phase>')` the moment phase moves off idle, so call audio doesn't bleed into the wake-word pipeline.
4. The user disabling the feature in Settings — `applyIdleConversationConfig` collapses any open session immediately.

When the session closes, `TextAgentService.reset()` clears the conversational scratch so the next wake doesn't re-reference yesterday's questions.

**Audio pipeline plumbing.** The two existing idle-mode gates — the Dart-side `_localAudioSub` guard and the native `_applyIdleAudioProcessing(paused: true)` path — both consult the new `_idleListenActive` predicate, which is just `_idleConfig.enabled`. With wake-word listening on, audio flows through and Whisper inference stays running continuously so the wake phrase can be heard. With the feature off, the original behavior is unchanged: audio gated, Whisper paused, no idle transcripts.

> **Why no "pause between sessions" toggle?** Catching a wake phrase requires an active speech-to-text path. We don't have a low-power dedicated wake engine yet, so "save CPU between sessions" and "reliably detect the wake word" are mutually exclusive. We deliberately removed that option to avoid silently breaking the feature.

## Configuration

`Settings > Agents > Voice Agent & STT Configuration > ADVANCED ▾ > IDLE CONVERSATION` exposes:

The block lives under a collapsed "Advanced" disclosure inside the STT panel because it's an STT-pipeline behaviour (it gates whether on-device WhisperKit transcription stays warm at idle), and because most users won't ever flip it on. The disclosure header shows a `Wake word: on` accent hint when the feature is enabled so the state is visible without expanding.

| Setting | Default | What it does |
| --- | --- | --- |
| `Enable wake-word listening` | off | Master switch. Off = legacy behavior (Whisper paused at idle, audio gated). On = WhisperKit stays warm at idle and a wake phrase opens a session. |
| `Accept generic "agent" alias` | on | Allows `"agent"` / `"hey agent"` in addition to the persona's name. |
| `Speak replies through speakers` | on | When off, agent replies still stream into the chat panel but Pocket TTS stays muted — useful as a quiet desktop dictation surface. |
| `Session window` slider | 60 s | Silence timeout before the session auto-closes (15–180 s). |

All three switches and the slider apply live through `AgentService.applyIdleConversationConfig` — no reconnect required.

## UI

The agent panel header status label reflects the new states without adding a new pill so the existing layout stays compact:

- Sleeping with wake mode on → `Say "Alice / agent"` (built from `AgentService.wakePhraseSummary`).
- Session open → `In conversation` (uses the existing accent color so it reads as "listening hard").
- Wake mode off → unchanged (`Listening`).

`AgentService.idleListeningForWakeWord` and `AgentService.idleSessionActive` are exposed for any future widgets that want a richer indicator (e.g. countdown bar, wake-pulse animation).

## Why this design

Several alternatives were rejected:

- **Continuous always-on transcription as a default** — burns CPU on every quiet room and pushes hallucinated transcripts through the rest of the pipeline. Kept off by default; the user has to opt in by flipping `Enable wake-word listening`.
- **Dedicated wake-word engine (Porcupine, OpenWakeWord)** — bigger lift, second model to ship, second native dependency. The on-device Whisper pipeline already runs and already handles English well; reusing it gives the user "rename the persona, the wake word follows" for free.
- **`CallPhase.idleConversation` synthetic phase** — touches every call-state consumer in the codebase. Sticking with `_callPhase == idle` plus a single `_idleSessionActive` flag was the smallest blast radius and the existing `_processTranscript` voiceprint / echo / hallucination filters all keep working unchanged.
- **`make_call`-style wake commands handed to the LLM** — would have given the model the chance to hallucinate wake events. The regex match in `_matchWakePhrase` is deterministic, fast, and cannot fire from a model output channel.

## Code locations

- `lib/src/agent_config_service.dart` — `IdleConversationConfig` model + `loadIdleConversationConfig` / `saveIdleConversationConfig`.
- `lib/src/agent_service.dart`
  - Fields `_idleConfig`, `_idleSessionActive`, `_idleSessionTimer`, `_idleSessionLastActivity`, `_idleSessionPendingRemainder`.
  - `_buildWakePhraseRegex`, `_matchWakePhrase`, `_isIdleSessionClosePhrase` — wake/close detection.
  - `_startIdleSession`, `_endIdleSession`, `_resetIdleSessionTimer` — lifecycle.
  - `_handleIdleConversationTranscript` — the gate hooked into `_processTranscript` after the dedup check.
  - Public `applyIdleConversationConfig`, `idleConfig`, `idleSessionActive`, `idleListeningForWakeWord`, `wakePhraseSummary`, `idleSessionSecondsRemaining`.
  - `_applyIdleAudioProcessing` override and `_localAudioSub` guard listen on `_idleListenActive`.
  - `notifyCallPhase` collapses any open session when phase moves off idle.
  - `_appendStreamingResponse` resets the silence timer on every agent final inside an open session.
- `lib/src/widgets/agent_settings_tab.dart` — `_buildIdleConversationContent` (inline list rendered inside the STT panel), `_buildSttAdvancedHeader` (disclosure toggle), `_updateIdleConv`, `_idleConv` state, `_sttAdvancedExpanded` toggle.
- `lib/src/widgets/agent_panel.dart` — status label / color updates that reflect the new states.

## Manual test plan

1. Enable wake-word listening in `Settings > Agents > IDLE CONVERSATION`. Select a persona named "Alice".
2. With no active call, say `"Alice, what time is it?"` — agent should answer through Pocket TTS, panel header reads `In conversation`.
3. Without saying the wake word, ask a follow-up question (e.g. `"And what's the date?"`) — agent answers, session stays open.
4. Stop talking. After ~60 s the panel header switches back to `Say "Alice / agent"`.
5. Open a session, say `"thanks"` — session closes immediately.
6. Open a session, place an outbound call — session closes silently, call proceeds normally with no wake-word interference.
7. Toggle `Speak replies through speakers` off — replies appear in chat panel without TTS.
8. Toggle `Pause between sessions` on — verify Whisper pauses between sessions (mic level meter still moves; transcript log is quiet) and resumes on the next wake phrase.
