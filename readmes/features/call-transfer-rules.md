# Call Transfer Rules

## Problem

The agent can transfer calls via the existing `transfer_call` tool, but only when explicitly told to in the moment. There's no way for the manager to set up persistent rules like "when Amber calls, transfer her to my cell." The agent also has no protocol for when a remote party requests a transfer — it would either refuse or blindly comply with no manager oversight.

The manager needs:
- Persistent transfer rules that survive sessions (e.g. "always transfer Amber to +1...")
- Silent vs announced mode per rule (agent tells the caller or just transfers)
- Optional job function assignment per rule (switch persona before/during transfer)
- A safety gate: when a remote party requests a transfer, the agent texts the manager for approval first

## Solution

### Data layer
- New `transfer_rules` SQLite table (DB version 15) with columns: `name`, `enabled`, `caller_patterns` (JSON array), `transfer_target`, `silent`, `job_function_id`, timestamps.
- `TransferRule` model with `matches(callerNumber)` using the same E.164/wildcard matching as `InboundRule`.
- `TransferRuleService` with CRUD + `resolve(callerNumber)` to find the first matching enabled rule.

### Agent tools (5 new)
Added to both the text agent (`_baseTools`) and OpenAI Realtime tool lists:
- `create_transfer_rule` — manager says "when Amber calls, transfer to my cell"
- `update_transfer_rule` — modify any field by rule ID
- `delete_transfer_rule` — remove a rule
- `list_transfer_rules` — list all rules with status
- `request_transfer_approval` — agent texts manager (via SMS to their configured phone number) when a remote party asks to be transferred; also posts in the chat panel

### Inbound call integration
When a call connects (`_promoteToConnected`), `_injectTransferRuleContext()` checks if a transfer rule matches the caller. If so, it injects a `SYSTEM CONTEXT` message telling the agent to execute the transfer (silent or announced) using the existing `transfer_call` tool.

### Transfer approval flow
When a remote party requests a transfer:
1. Agent calls `request_transfer_approval` with reason and optional target
2. Handler sends SMS to the manager's phone (`_agentManagerConfig.phoneNumber`) and posts in the chat panel
3. Manager replies YES/NO via SMS → flows through the existing inbound SMS pipeline back to the agent
4. Agent executes `transfer_call` or declines

### Agent instructions
New `## Call Transfers` section in `AgentBootContext.toInstructions()` with rules for:
- Manager requests → transfer immediately
- Remote party requests → always use `request_transfer_approval` first
- Matching transfer rule on connect → auto-execute unless manager overrides
- Silent vs announced mode explanation

## Files

- `phonegentic/lib/src/models/transfer_rule.dart` — **new** model
- `phonegentic/lib/src/transfer_rule_service.dart` — **new** service
- `phonegentic/lib/src/db/call_history_db.dart` — new table, version 15, CRUD helpers
- `phonegentic/lib/src/text_agent_service.dart` — 5 transfer tools added to `_baseTools`
- `phonegentic/lib/src/whisper_realtime_service.dart` — matching 5 tool defs for realtime
- `phonegentic/lib/src/agent_service.dart` — tool handlers, service wiring, transfer context injection on connected calls, `request_transfer_approval` with SMS + chat
- `phonegentic/lib/src/models/agent_context.dart` — Call Transfers instructions section
- `phonegentic/lib/main.dart` — `TransferRuleService` provider + wiring to `AgentService`
