# Conference Second Leg: Missing Greeting

## Problem

When the agent adds a second party to set up a conference call, the new leg never gets a greeting. The root cause: `_hasConnectedBefore` is set `true` when the first call connects and only cleared on call end. So when the second leg reaches `connected`, `_scheduleConnectedGreeting()` is skipped entirely. The agent sits silent on the new leg instead of introducing itself and explaining the conference.

Even when `_firePreGreeting()` runs during settling (split pipeline only), its outbound prompt is generic ("begin the conversation") with no conference context.

## Solution

1. **Detect conference legs**: when a new call starts (`initiating`/`ringing`) while `_hasConnectedBefore` is true, set `_isConferenceLeg = true`.
2. **Reset greeting state**: clear `_hasConnectedBefore`, pre-greeting buffers, and the connected-greeting timer so a fresh greeting cycle runs for the new leg.
3. **Conference-aware prompts**: in both `_tryFireConnectedGreeting` and `_firePreGreeting`, when `_isConferenceLeg` is true, use a prompt that tells the agent to greet the new party, introduce itself, and explain it's setting up a conference call on behalf of the manager.
4. **Cleanup**: clear `_isConferenceLeg` on call end.

## Files

- `phonegentic/lib/src/agent_service.dart` — added `_isConferenceLeg` field, detection logic, greeting prompt branch, cleanup
