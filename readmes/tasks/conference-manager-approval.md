# Conference-in-Manager with Approval Flow

## Problem

When a caller asks the agent to set up a conference call, the agent responds with
"I'm not currently set up to manage a conference call." Two issues:

1. The text agent (split pipeline) doesn't have `hold_call`,
   `add_conference_participant`, or `merge_conference` in its tool definitions,
   so it literally can't see those tools.
2. There are no instructions telling the agent *how* to orchestrate a conference
   call or that the only supported conference scenario is conferencing in the
   manager/host.
3. There is no approval gate — the manager should be texted first to confirm
   they're available before being dialed in.

## Solution

### New tool: `request_manager_conference`

Modeled after `request_transfer_approval`. Sends an SMS to the manager asking if
they want to be conferenced into the active call. Posts a system message in the
chat panel too. The agent waits for the manager's YES/NO reply (arrives via
inbound SMS) before proceeding.

### Text agent tool exposure

Add `hold_call`, `add_conference_participant`, and `merge_conference` to the text
agent's `_baseTools` so the split-pipeline LLM can see and invoke them.

### Manager context instructions

Expand `_buildManagerContext()` to include a **Conference Calling** section that:

- Explains the only conference option is to dial in the manager.
- Requires `request_manager_conference` before proceeding.
- Walks the agent through the hold → dial → merge sequence.
- Tells the agent to inform the caller they'll be placed on hold.

### Execution flow

1. Caller: "Can you conference in [manager]?"
2. Agent → `request_manager_conference` → SMS sent to manager.
3. Agent tells caller: "Checking with [manager], one moment."
4. Manager replies YES → inbound SMS triggers agent context.
5. Agent informs caller they'll be placed on hold.
6. Agent → `hold_call(hold)` → `add_conference_participant(manager phone)` →
   waits for connection → `merge_conference`.

## Files

- `phonegentic/lib/src/text_agent_service.dart` — added conference tools + `request_manager_conference` to `_baseTools`
- `phonegentic/lib/src/whisper_realtime_service.dart` — added `request_manager_conference` tool schema
- `phonegentic/lib/src/agent_service.dart` — added `_handleRequestManagerConference`, wired into both tool-call switches, updated `_buildManagerContext()`
