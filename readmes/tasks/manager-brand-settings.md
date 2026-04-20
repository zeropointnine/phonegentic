# Manager Brand Name & Website Settings

## Problem

The agent has no way to know the brand/company it represents. When the agent answers calls or interacts with callers, it cannot dynamically reference the business name or direct people to the company website. These fields need to live in user settings under the existing Agent Manager section so the agent can incorporate them into its context.

## Solution

Add `brandName` and `brandWebsite` fields to `AgentManagerConfig`, with persistence via `UserConfigService` (SharedPreferences), UI inputs in the Agent Manager card on the User settings tab, export/import support, and agent context injection in `_buildManagerContext`.

## Files

- `phonegentic/lib/src/user_config_service.dart` — add fields to `AgentManagerConfig`, update load/save
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — add text controllers and UI rows for brand name and website
- `phonegentic/lib/src/settings_port_service.dart` — include brand fields in export/import
- `phonegentic/lib/src/agent_service.dart` — inject brand context into `_buildManagerContext`
