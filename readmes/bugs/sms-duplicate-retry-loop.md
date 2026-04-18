# SMS Duplicate Messages & Rate-Limit Retry Loop

## Problem

Two related bugs in the SMS tool call handling:

1. **Duplicate messages**: The LLM sometimes calls `send_sms` twice in the same response chain with identical text to the same number. Both go through because neither hits the rate limiter (they're the 1st and 2nd messages). The user sees the same text sent twice.

2. **Retry loop after rate limit**: When the rate limiter kicks in, Gemini Flash Lite ignores the "STOP sending" tool result and keeps calling `send_sms` in a loop — sometimes 8+ consecutive attempts — burning LLM tokens and time before finally giving up. The model doesn't understand the rate limit response as a hard stop.

## Solution

Two-layer defense:

1. **Content dedup**: Track the last sent message per number (text + timestamp). If an identical message to the same number was sent within the last 30 seconds, silently return the same success response without actually sending. This prevents duplicate messages even when the LLM double-fires.

2. **Force cancel on repeated rate limits**: Track consecutive rate-limit hits per number. After 2 consecutive rate-limit results for the same number, cancel the current LLM response to forcibly break the retry loop. The LLM has clearly failed to understand the stop instruction.

## Files

### Modified
- `phonegentic/lib/src/agent_service.dart` — added dedup tracking and force-cancel on repeated rate limits
