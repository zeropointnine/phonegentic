# Apple Reminders Integration

## Problem

The native Swift bridge (`NativeActionsChannel.swift`) and Dart wrapper (`NativeActionsService`) for Apple Reminders via EventKit already exist, but they aren't wired into:

1. The 3rd party integrations UI — no toggle, no permission check, no list picker
2. The agent's `create_reminder` tool — reminders only go to local SQLite, never to Apple Reminders.app

Users have no way to enable Apple Reminders sync or see it as an available integration.

## Solution

1. **`AppleRemindersConfig`** — simple SharedPreferences-backed config with `enabled` flag and `defaultList` name.
2. **UI section** in `_buildIntegrationsCard()` — expandable row matching the existing pattern (icon, enable toggle, test permission button that probes EventKit access and fetches lists, dropdown for default list).
3. **Agent wiring** — add `add_to_apple_reminders` boolean to the `create_reminder` tool schema (mirrors `add_to_google_calendar`). When enabled and requested, also call `NativeActionsService.createReminder()` after storing in SQLite. The tool description instructs the LLM to offer Apple Reminders when the integration is active.
4. **Config plumbed to AgentService** — a new `appleRemindersEnabled` getter, read from config, used in `_applyIntegrationTools` instruction context and in `_handleCreateReminder`.

## Files

### Created
- `phonegentic/lib/src/apple_reminders_config.dart` — config class
- `readmes/tasks/apple-reminders-integration.md` — this file

### Modified
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — UI integration section
- `phonegentic/lib/src/agent_service.dart` — tool schema + handler wiring
