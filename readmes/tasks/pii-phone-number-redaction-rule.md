# PII Phone Number Redaction Rule

## Problem

During demos the agent sometimes outputs full phone numbers in its responses (voice or text), exposing PII on screen.

## Solution

Added Rule 18 to the agent's system prompt in `AgentBootContext.toInstructions()`. The rule instructs the agent to never display or speak a full phone number and to reference numbers only by their last four digits (e.g. "ending in 4832").

## Files

- `phonegentic/lib/src/models/agent_context.dart` — added rule 18
- `readmes/tasks/pii-phone-number-redaction-rule.md` — this file
