# Agent Conversational Style & Brevity

## Problem

The agent sounds robotic and overly verbose during conversations:
- Responds with full paragraphs when a sentence would suffice
- Stacks multiple questions in a single response, overwhelming the other party
- Uses corporate/AI phrasing ("I'd be happy to", "Great question!", "Is there anything else")
- Lacks natural human conversational patterns (reactions, contractions, casual transitions)

## Solution

Added two new numbered rules and a full `## Conversational Style` section to the agent's system prompt in `AgentBootContext.toInstructions()`:

1. **Rule 8 rewritten** — changed from vague "keep responses concise" to explicit "one to two sentences max" with a hard instruction to get to the point.
2. **Rule 15: ONE QUESTION AT A TIME** — enforces asking a single question per turn and waiting for the answer before asking the next.
3. **Rule 16: MATCH THEIR ENERGY** — mirror the other person's pace and tone; brief answers to brief inputs.
4. **Conversational Style section** — concrete guidelines for sounding human:
   - Use contractions
   - Vary sentence structure
   - Use casual transitions ("So", "Anyway", "Oh actually")
   - React before responding ("Oh nice!", "Got it")
   - Don't over-explain; lead with yes/no on yes/no questions
   - Blacklist of AI-sounding phrases
   - Embrace brief responses ("Yeah, done.", "Nope, that's it.")
5. **Voice mode brevity emphasis** — added explicit line in the Voice output section: "BREVITY IS CRITICAL. Long-winded responses make you sound like a robot reading a manual."

Also fixed a typo: "Agent Idnentity" → "Agent Identity".

## Files

- `phonegentic/lib/src/models/agent_context.dart` — all prompt changes
