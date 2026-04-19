# Agent Log Access + GitHub Issue Filing

## Problem

The agent has no visibility into its own runtime logs. When something goes wrong (SIP failures, missed auto-answer, TTS drops), diagnosing the issue requires manually scrolling through the Xcode/terminal console. The agent can't self-diagnose or report bugs automatically.

All ~400 `debugPrint` calls go straight to the console and are immediately lost — there's no persistence, no ring buffer, and no programmatic query API.

## Solution

### Log capture — `LogService`

A singleton with a 2000-entry ring buffer that intercepts all `debugPrint` output via a global override in `main()`. Provides three query methods:

- `recent(count)` — last N entries
- `search(query, count)` — case-insensitive substring filter
- `since(time)` — entries after a timestamp

### Agent tools

Two new tools available on both voice (OpenAI Realtime) and text (Claude/OpenAI) pipelines:

| Tool | Purpose |
|------|---------|
| `read_logs` | Query the ring buffer by count, substring, or time window |
| `file_github_issue` | Create a GitHub issue on `reduxdj/phonegentic` with optional log excerpts in a collapsible `<details>` block |

### GitHub config

Gated behind `ENABLE_GITHUB_ISSUES=true` in `build.env` (see `BuildConfig.enableGitHubIssues`). When disabled, the `file_github_issue` tool is not registered and the PAT field is hidden from settings.

When enabled: GitHub PAT stored in SharedPreferences (`agent_github_token`). Repo hardcoded to `reduxdj/phonegentic`. Issues created via `POST /repos/{owner}/{repo}/issues` with `dart:io` `HttpClient`.

## Files

### New
- `phonegentic/lib/src/log_service.dart` — `LogService` singleton, `LogEntry`, ring buffer, query API
- `readmes/features/agent-log-access-github-issues.md` — this file

### Modified
- `phonegentic/lib/main.dart` — `debugPrint` override wiring + `LogService` import
- `phonegentic/lib/src/agent_config_service.dart` — `gitHubRepo` constant, `loadGitHubToken()` / `saveGitHubToken()`
- `phonegentic/lib/src/agent_service.dart` — `_logToolsLlm` / `_logToolsOpenAi` definitions, `_handleReadLogs` / `_handleFileGithubIssue` handlers, switch cases in both `_onFunctionCall` and `_onTextAgentToolCall`, merged into `_applyIntegrationTools`
- `phonegentic/lib/src/whisper_realtime_service.dart` — `read_logs` + `file_github_issue` in voice session tool list
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — GitHub PAT field in integrations card
- `phonegentic/lib/src/calendly_service.dart` — removed partial API key logging (credential audit)
