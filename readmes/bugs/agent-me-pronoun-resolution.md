# Agent confused by "me" pronoun + claimed actions without tool calls

## Problem

When the agent manager calls in and says "send me a text," two things go wrong:

1. **Pronoun confusion**: The agent doesn't understand that "me" refers to the caller (the agent manager). The Agent Manager system prompt section grants elevated privileges but never tells the agent the manager's phone number, so it can't resolve "me" to a destination. There's also no general rule about first-person pronouns from callers.

2. **Phantom actions**: The agent says things like "I'll send that text to your phone right now" and "I'll send that over" but never actually calls `send_sms`. It keeps confirming the action verbally without ever invoking the tool — effectively lying about having done something.

## Solution

Three changes:

1. **`agent_service.dart` — Agent Manager section**: When the caller is the agent manager, the system prompt now includes the manager's phone number and an explicit instruction that "me"/"I"/"my" in requests like "send me a text" refers to that number.

2. **`agent_context.dart` — Pronoun resolution rule**: Added a `### Pronoun resolution during calls` subsection under `## Messaging (SMS)` that teaches the agent to resolve "me" to the phone number of the person speaking — whether that's the remote caller (from call state) or the host/manager when idle.

3. **`agent_context.dart` — Rule #17 (tool-action integrity)**: Added a new rule that the agent must NEVER claim to have performed an action without actually invoking the corresponding tool. Tool call first, then confirm. If it lacks info to make the call, it must ask instead of pretending.

## Files

- `phonegentic/lib/src/agent_service.dart` — expanded Agent Manager prompt to include phone number and pronoun guidance
- `phonegentic/lib/src/models/agent_context.dart` — added pronoun resolution rule + tool-action integrity rule (#17)
