# Manager Context for Agent

## Problem

When the host (manager) says "call me in 5 minutes", the agent has no idea who "me" is outside of an active inbound call from the manager's number. The agent doesn't know the manager's name or phone number as standing context — it only learns the manager's phone during inbound calls via `_isCallerAgentManager`. This means:

- The agent can't call the manager back proactively (e.g. reminders, scheduled callbacks).
- The agent doesn't know the manager's name to address them naturally.
- The voice agent (OpenAI Realtime) gets **zero** manager context — only the text agent path injects it, and only during active inbound calls from the manager.

## Solution

1. **Expand `AgentManagerConfig`** — add a `name` field alongside `phoneNumber`, persisted in SharedPreferences.
2. **UI** — add a name input row to the existing Agent Manager card in user settings.
3. **Always-on manager context** — inject a `## Manager / Host` section into both voice and text agent instructions (not gated on `_isCallerAgentManager`). This tells the agent: "Your manager is [name] at [phone]. When they say 'call me' or 'text me', use this number. Address them by name."
4. **Settings export/import** — include the new `name` field.

## Files

### Modified
- `phonegentic/lib/src/user_config_service.dart` — `name` field on `AgentManagerConfig`
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — name input in Agent Manager card
- `phonegentic/lib/src/agent_service.dart` — inject manager context into both voice and text instructions
- `phonegentic/lib/src/settings_port_service.dart` — export/import manager name
