# SMS Branding: First Message Only

## Problem

When the agent responds to an inbound text (a reply in an ongoing conversation),
it still includes the full Phonegentic branding and website link — e.g.
"This is Alice with Phonegentic (https://phonegentic.ai)."

This feels spammy on follow-up replies. The branding should only appear on the
initial outbound message that starts a conversation, not every subsequent reply.

## Solution

Updated the "Outbound SMS branding" system instructions in `AgentBootContext.toInstructions()`.
The rules now specify:

- First message to a new recipient: include name, Phonegentic branding, and website link.
- Follow-up replies (recipient has already replied): drop the branding and reply naturally.

## Files

- `phonegentic/lib/src/models/agent_context.dart` — updated SMS branding instructions
