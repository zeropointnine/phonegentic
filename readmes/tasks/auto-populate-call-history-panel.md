# Auto-populate call history panel from agent search

## Problem

When the user asks the agent to search call history (e.g., "Search my call history: calls to Lee"), the agent finds results via `get_call_summary` and narrates them in chat, but the left-side call history panel shows "No calls found."

This happens because `get_call_summary` queries `CallHistoryDb` directly and returns text to the agent — it never pushes results into `CallHistoryService._searchResults`, which is the data source for the panel UI.

## Solution

Modified `_handleGetCallSummary` in `agent_service.dart` to also populate the call history panel:

1. Build a `CallSearchParams` from the tool arguments and call `callHistory.search(params)` to fill `_searchResults`.
2. Call `callHistory.openHistory(keepResults: true)` to open the panel without re-running the search.
3. Append a bracketed instruction to the tool result telling the agent not to list individual calls since they're already visible in the panel.

Updated tool descriptions and system instructions across all three locations (Whisper tool definition, LLM tool definition, system prompt) to reinforce that results appear in the panel automatically and the agent should give a brief summary instead of enumerating calls.

### Phase 2: Don't overwrite search query + placeholder examples

When `_handleGetCallSummary` called `openHistory(query: queryLabel, keepResults: true)`, the query parameter overwrote the user's search bar text via the `Consumer` sync in `CallHistoryPanel`. Fixed by calling `openHistory(keepResults: true)` without a query — the search results are already populated by `search(params)`.

Also replaced the generic `'Search...'` placeholder with example queries: `'calls to Lee, missed today, last hour...'` (at 12px for a suggestion feel).

### Phase 3: Contact name JOIN + agent search fix

Three issues with call history search:

1. **DB queries didn't JOIN contacts** — `searchCalls`, `searchCallsByTranscript`, `getRecentCalls`, and `searchSuggestions` only looked at `remote_display_name`/`remote_identity` in `call_records`. If the call was saved with just a phone number but had a `contact_id`, searching by name (e.g. "dave") returned nothing.

2. **`lastBriefingAt` filter too restrictive** — `_handleGetCallSummary` defaulted `since` to `managerPresenceService.lastBriefingAt` even for targeted contact searches. This meant "calls to dave" would only look at calls since the last briefing, often missing all history.

3. **Tiles didn't show contact name** — Even when calls had linked contacts, the tile showed the raw phone number.

**Fix:** Added `LEFT JOIN contacts c ON c.id = cr.contact_id` to all four DB query methods, returning `c.display_name AS contact_name`. The contact name filter now matches across all three: `remote_display_name`, `remote_identity`, and `c.display_name`. Updated the tile's `_name()` to prefer `contact_name`, and added a phone number subtitle line when a name is available. The `since` fallback now only applies to general "what happened?" queries, not targeted searches.

## Files

- `phonegentic/lib/src/agent_service.dart` — `_handleGetCallSummary` populates `CallHistoryService`, updated tool descriptions/system instructions, fixed `since` fallback logic
- `phonegentic/lib/src/whisper_realtime_service.dart` — updated Whisper-side `get_call_summary` tool description
- `phonegentic/lib/src/widgets/call_history_panel.dart` — search placeholder examples, tile shows contact name + phone number subtitle
- `phonegentic/lib/src/db/call_history_db.dart` — `searchCalls`, `searchCallsByTranscript`, `getRecentCalls`, `searchSuggestions` all JOIN contacts table
