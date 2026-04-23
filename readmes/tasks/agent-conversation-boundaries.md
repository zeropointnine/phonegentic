# Agent awareness of conversation boundaries

## Problem

Alice's text-agent runs off a **single conversation thread** that is actually a multiplex of several independent channels:

1. Voice transcripts from the person on the active call
2. Inbound SMS from various phone numbers (injected as `SYSTEM EVENT — New inbound SMS received…`)
3. System / platform events (conference leg connected, voicemail beep, IVR menu, reminder fires, call answered/ended)
4. Tool results from her own tool calls

Because everything lands in the same LLM context, there's a real risk of **cross-channel leakage**:

- Agent is mid-call with Alice, gets an SMS from Bob → next spoken reply accidentally opens with "Hey Bob" (leaks Bob's identity to Alice, ignores Alice).
- SMS arrives from Bob with "call me", agent interprets "me" as the active caller Alice and calls the wrong number.
- Agent pastes quoted SMS body or tool output into a spoken reply.
- Agent reuses a salutation from one channel on a different channel.

This is especially dangerous because `send_sms` is always a tool call away, so confused audience resolution can produce real side-effects (wrong-recipient SMS).

## Solution

Add a new `_buildConversationBoundariesContext()` section to the agent's system prompt (called from `_buildTextAgentInstructions()` between the reminder-awareness and hallucination-awareness sections). It teaches the LLM:

1. **Channel taxonomy** — the four categories of messages she'll see and how they're prefixed (`SYSTEM EVENT`, `[SYSTEM]`, raw transcript, tool result).
2. **One reply, one audience** — before responding, pick the audience; spoken replies go only to the active caller, `send_sms` goes only to the specified recipient. Updates to the manager during a call must go via `send_sms`, not TTS.
3. **No cross-channel leakage** — never address the wrong party, never include caller content in an SMS reply or SMS content in a spoken reply, never reuse salutations across channels.
4. **Pronoun disambiguation** — "me / my / you" resolve against the recipient of the reply being composed, not the most recent inbound sender. A "call me" SMS from Bob is not an instruction from the active caller.
5. **Switching-attention discipline** — inbound SMS during a call may be acknowledged internally or via tool calls, but should not bleed into the spoken stream unless operationally relevant, and even then never read SMS bodies/senders/numbers/tool outputs aloud (except to the manager on explicit request — which already ties into the privacy rules in the hallucination-awareness section).

No new tools, no new code paths — the existing `SYSTEM EVENT —` prefixes on inbound SMS and the `[SYSTEM]` prefixes on platform events are already diagnostic; this change just makes the LLM treat them correctly.

## Files

- `phonegentic/lib/src/agent_service.dart` — new `_buildConversationBoundariesContext()` method; wired into `_buildTextAgentInstructions()` before `_buildHallucinationAwarenessContext()`
