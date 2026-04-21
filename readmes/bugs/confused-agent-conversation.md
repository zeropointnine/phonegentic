# Confused Agent Conversation — Multi-Issue Bug Fix

## Problem

During a single session, the agent exhibited multiple confused behaviors:

1. **Conference-with-self SDP crash (P7):** Agent hallucinated a name ("Christophe") from garbled STT, attempted to conference someone in, and dialed the caller's own number — causing an SDP m-line mismatch crash that killed the call and corrupted SIP state. Subsequent calls failed, and SIP registration eventually dropped entirely (500 Connection Error).

2. **Wrong recipient name in SMS (P6):** Agent sent an SMS to +13038982988 (Keith) but addressed him as "Luke" — a name fabricated from hallucinated speech. No contact search was performed before sending.

3. **Duplicate SMS confirmations (P1):** After sending SMS to a third party (Luis), agent sent 3 separate confirmation texts to the manager within seconds ("Sent that message", "Confirmed, I've sent that text", then rate-limited on third).

4. **Greeting suppressed on reminder-triggered call (P3):** Reminder fired `make_call`, which set `_callDialPending = true`. The LLM generated a greeting that was suppressed during dial-pending. The pre-greeting mechanism couldn't fire because the text agent was still mid-response from the stale make_call result.

5. **Agent unresponsive after rate-limit cancellation (P2):** `cancelCurrentResponse()` killed the entire LLM turn including non-SMS actions. Subsequent commands were silently dropped because the LLM had no indication to retry.

6. **Agent responds to hallucinated STT (P4):** Whisper transcribed background noise/echo as nursery rhymes, random names, and incoherent sentences. Agent responded to all of it, including attempting conference calls based on misheard names.

## Solution

### P7: Self-dial guard in `_handleAddConferenceParticipant`
Compare the cleaned dialing number against `_remoteIdentity`. If they match, return an error instead of dialing — prevents the SDP crash.

### P6: SMS name mismatch detection
- Moved contact lookup before the send in `_handleSendSms` and `_handleReplySms`
- Added `_detectSmsNameMismatch()` — extracts the greeting name from the message body ("Hi Luke") and compares against the stored contact name. If mismatch, blocks the send with a warning
- Tool result now includes the contact name (e.g. "Message sent to Keith (+1303...)") so the LLM can self-correct

### P1: Manager confirmation cooldown
- Added `_smsManagerCooldownUntil` — after any successful send to a third party, blocks SMS to the manager's number for 30 seconds
- Cooldown clears when the manager texts back (inbound SMS)
- Prevents the LLM from sending duplicate "I sent that" confirmations

### P3: Cancel stale response before pre-greeting
- `_firePreGreeting()` now calls `_textAgent?.cancelCurrentResponse()` first
- Ensures the pre-greeting prompt isn't queued behind a stale make_call response

### P2: System nudge after rate-limit cancellation
- After `cancelCurrentResponse()` fires due to rate limits, inject a delayed system context message telling the LLM its response was cancelled and to retry without SMS
- Non-SMS actions (calls, reminders, conversation) are no longer silently dropped

### P4/P4b: Hallucination guardrails in system instructions
- Added rule 19: "NEVER act on incoherent or contextually bizarre speech during a call"
- Added "Conference Calling Rules" section requiring explicit host request before any conference action
- Added rule that `request_manager_conference` approval must be received before hold/dial

## Files

### Modified
- `phonegentic/lib/src/agent_service.dart` — P7 self-dial guard, P6 name mismatch detection, P1 manager cooldown, P3 pre-greeting cancel, P2 rate-limit nudge
- `phonegentic/lib/src/models/agent_context.dart` — P4/P4b conference rules and hallucination guardrail instructions
