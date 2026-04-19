# Call search query enhancements

## Problem

The natural-language call history search parser didn't support three useful query patterns:

1. **Article-based durations** — "a minute or longer" / "an hour or more" failed because the regex required a digit (`\d+`), not an article like "a" or "an".
2. **Date ranges** — "from yesterday till today" only matched "yesterday" as a `since` with no `before`, so the range was open-ended. The `before` field existed in `CallSearchParams` but was never populated by the parser.
3. **Transcript content search** — "calls where somebody said X" had no support at all. There was no way to search the `call_transcripts` table via the search UI or the LLM tool.

## Solution

### 1. Article-based durations
Added a regex that matches `a/an + unit` patterns (e.g. "a minute or longer", "an hour or more") and treats the article as 1. Also added a pattern for `N unit or longer/more` (e.g. "5 minutes or longer"). Extracted `_unitToSeconds` helper to avoid duplicating unit conversion logic.

### 2. Date ranges
Added a range pattern that matches `from <date> to/till/until/through <date>` and sets both `since` and `before`. The `before` date gets set to 23:59:59 of that day so the full day is included. The `_tryParseDate` helper supports tokens like "today", "yesterday", day-of-week names, "month day", and M/D(/YYYY) formats, so ranges like "from April 10 to April 15" work.

### 3. Calendar date queries
Expanded the time parsing to handle:
- Specific dates: "on April 15th", "on 4/15", "April 15, 2026", "on 4/15/26"
- Day-of-week: "on Monday", "last Friday", "this Wednesday" (resolves to most recent matching weekday)
- Month ranges: "this month", "last month"
- All of these set both `since` and `before` to bound a single day (or month), so results are scoped precisely.

### 4. Transcript content search
- Added `transcriptQuery` field to `CallSearchParams`
- Parser extracts quoted or unquoted text after patterns like "where somebody said ...", "mentioning ...", "about ...", "containing ..."
- Added `CallHistoryDb.searchCallsByTranscript()` that JOINs `call_records` with `call_transcripts` on text LIKE match, applying all other filters
- `CallHistoryService.search()` routes to the transcript method when `transcriptQuery` is set
- Added `transcript_query` parameter to the `get_call_summary` LLM tool so the AI agent can also search by what was said

## Files

- `phonegentic/lib/src/call_history_service.dart` — enhanced `CallSearchParams.fromQuery` parser, added transcript routing in `search()`
- `phonegentic/lib/src/db/call_history_db.dart` — added `searchCallsByTranscript()` method
- `phonegentic/lib/src/agent_service.dart` — added `transcript_query` to tool schema and wired through handler
