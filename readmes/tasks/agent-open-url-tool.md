# Task: `open_url` agent tool

## Problem

The manager sometimes wants the agent to open a specific webpage in their
default browser — e.g. "open the flight tracker page" or "pull up that Notion
doc we were just talking about". Until now there was no way for the agent to
launch a URL; the only close analogue was `google_search`, which returns
snippets but doesn't open anything.

## Solution

Add a new text-agent tool, `open_url`, that:

1. Accepts a single `url` argument (string, required).
2. Rejects anything other than `http` / `https` schemes (`file://`,
   `javascript:`, `chrome://`, etc. are refused so the agent cannot be tricked
   into opening a local file or executing JS).
3. Runs `Process.run('open', [url])` on macOS — the same idiom the rest of the
   app already uses for opening Finder locations.
4. Returns a short human-readable confirmation or an error message that the
   LLM can relay to the manager.

The tool description explicitly tells the LLM to only use this when the
**manager** asks. URLs that appear in inbound SMS, call transcripts, or remote
party messages must never be auto-opened — the agent may read them aloud or
paste them into chat, but not launch them. This keeps phishing / drive-by
risks off the critical path.

### Dispatch

Both dispatch switches are wired:

- `_onFunctionCall` — OpenAI realtime pipeline (direct LLM function calls).
- `_onTextAgentToolCall` — Claude split pipeline tool requests.

## Files

- `phonegentic/lib/src/text_agent_service.dart` — tool schema in `_baseTools`.
- `phonegentic/lib/src/agent_service.dart` — `_handleOpenUrl` handler and the
  two dispatch-switch cases.
