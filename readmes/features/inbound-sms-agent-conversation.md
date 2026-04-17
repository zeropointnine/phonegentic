# Inbound SMS Agent Conversation

## Problem

The agent could send SMS via `send_sms` and `reply_sms` tools, but had no awareness of inbound messages. When someone texted in, the message was persisted and displayed in the UI, but the agent was never notified. This meant the agent couldn't carry on a two-way text conversation — it was send-only.

## Solution

Wire inbound SMS from `MessagingService` into `AgentService` so the agent sees incoming texts and can respond autonomously.

**Flow:** Polling/webhook → `MessagingProvider.incomingMessages` → `MessagingService._onIncomingMessage` → (new) `inboundMessages` stream → `AgentService._onInboundSms` → inject into text agent or OpenAI Realtime → agent calls `send_sms` to reply.

Key design decisions:
- Used `sendUserMessage` (not `addTranscript`) for the text agent path so the inbound SMS triggers an immediate LLM response rather than being debounced with other transcript context.
- Contact lookup resolves phone numbers to names so the agent sees "John Smith (+14155551234)" rather than just a number.
- Agent instructions updated with strong guardrails against hallucinating inbound SMS. The LLM was generating fake `[Inbound SMS from …]` text in its own responses, role-playing both sides. Fixed by:
  - Using a distinct `SYSTEM EVENT —` prefix that the agent is told only the system can produce
  - Explicit instructions to STOP and WAIT after sending, never predict/fabricate replies
  - Multiple reinforcing rules against simulating inbound messages
- Only fires when the agent is active (`_active` check) — no ghost replies when the agent is off.

### Phase 3: Rate limiter to prevent tool-call spam loops

The LLM (Gemini Flash Lite) entered an infinite loop: after sending an SMS reply, the tool result "Message sent successfully" caused it to generate another `send_sms` call instead of text, repeating ~20+ times. Fixed with a hard code-level rate limiter:

- Max 2 messages per phone number per 60-second window
- Applied to both `send_sms` and `reply_sms` handlers
- Returns a directive error ("STOP sending and wait for their reply") that breaks the loop
- Tool result messages also now include "Do NOT send another message" language

## Files

| File | Change |
|------|--------|
| `phonegentic/lib/src/messaging/messaging_service.dart` | Added `inboundMessages` broadcast stream, emit on inbound SMS in `_onIncomingMessage`, close in `dispose` |
| `phonegentic/lib/src/agent_service.dart` | Added `_inboundSmsSub`, converted `messagingService` to getter/setter with auto-subscribe, added `_onInboundSms` handler, SMS rate limiter (`_smsSendLog`, `_isSmsRateLimited`, `_recordSmsSend`), cleanup in `dispose` |
| `phonegentic/lib/src/models/agent_context.dart` | Added "Inbound SMS conversations" section to agent system instructions with anti-hallucination guardrails |
