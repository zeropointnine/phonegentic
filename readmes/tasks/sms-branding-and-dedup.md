# SMS Branding & Contact Number Deduplication

## Problem

Two issues with outbound SMS behavior:

1. **No branding**: When Alice sends a message on behalf of the manager, she doesn't identify herself as being with Phonegentic or include a link to phonegentic.ai. Recipients have no context about who/what is texting them.

2. **Duplicate sends**: When a contact has multiple phone numbers (e.g. Keith Bristol with two numbers), the agent sends the same message to ALL numbers. The conversation panel showed two identical messages — one to each number — and the agent confirmed "I've sent that to both numbers." This is unwanted default behavior.

## Solution

Added two new subsections to the `## Messaging (SMS)` block in `AgentBootContext.toInstructions()`:

- **Outbound SMS branding**: Every outbound SMS must identify the agent by name + "with Phonegentic" and include a link to https://phonegentic.ai. The branding should feel natural, not like a spam footer.

- **Contact number selection**: When a contact has multiple numbers, send to only ONE (prefer mobile). Only send to multiple numbers if the host explicitly asks.

Also carried forward from the previous session: fixed a bug in `TextAgentService._callLlm()` where accumulated tool calls were dropped when the response was cancelled (VAD barge-in) or truncated (fabrication detection). The early-return path now falls through to tool-call processing, so actions like `create_reminder` and `send_sms` execute even if the user speaks over the confirmation text.

## Files

- `phonegentic/lib/src/models/agent_context.dart` — added `### Outbound SMS branding` and `### Contact number selection` subsections
- `phonegentic/lib/src/text_agent_service.dart` — removed early return in cancelled/fabrication path so tool calls are preserved
