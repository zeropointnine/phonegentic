# Missed call search incorrectly includes failed outbound calls

## Problem

When the user asks the AI agent "search my call history: missed today," the agent calls `get_call_summary` with only a time filter (`since_minutes_ago: 1440`). The tool returns all 24 calls — including a failed outbound call — and the LLM incorrectly reports that failed outbound as a "missed" call.

Missed calls should only ever be unanswered **inbound** calls. The status tracking in the DB is correct (`status='missed'` is only set for inbound calls with no `_connectedAt`), but the `get_call_summary` tool lacked `status` and `direction` filter parameters, so the LLM had no way to narrow the query.

The call history panel UI search was actually correct — searching "missed today" returned zero results because there were genuinely no missed inbound calls.

## Solution

Added `status` and `direction` filter parameters to the `get_call_summary` LLM tool schema. Updated `_handleGetCallSummary` to extract and forward these to `getCallActivitySummary`, which passes them through to `CallHistoryDb.searchCalls`. Also updated the tool description to explicitly state that "missed" means unanswered inbound calls, not failed outbound calls.

## Files

- `phonegentic/lib/src/agent_service.dart` — added `direction`/`status` params to tool schema, handler, and `getCallActivitySummary`
