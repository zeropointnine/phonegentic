# SMS Rate Limit Blocks Reply to Inbound Conversation

## Problem

When someone texts the agent and a back-and-forth conversation develops, the
per-number SMS rate limiter (2 messages / 60 seconds) blocks the agent from
replying to the third inbound message within the window. The LLM receives a
"Rate limited… STOP sending" tool result and — instead of just waiting — gets
creative: it schedules a **reminder** to send the reply later, which is
confusing and wrong.

### Root cause

`_onInboundSms` never resets the send-rate state for the sender's number.
The rate limiter is designed to prevent tool-call loops (LLM calling send_sms
in a tight loop), but it doesn't distinguish between autonomous loop sends and
legitimate replies to a real person who is actively texting back.

## Solution

When an inbound SMS arrives from a number, clear that number's rate-limit
history (`_smsSendLog` and `_smsConsecutiveRateLimits`). A reply from the
other person is proof that this is a genuine conversation, not a loop — so
the agent should be allowed to respond immediately.

## Files

- `phonegentic/lib/src/agent_service.dart` — clear rate-limit state in `_onInboundSms`
