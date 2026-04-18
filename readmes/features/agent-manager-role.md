# Agent Manager Role

## Problem

When the agent handles inbound calls, it applies guardrails and access restrictions that treat all callers equally. The app owner (host) needs a way to designate a specific phone number/contact as the "Agent Manager" — an elevated role equivalent to the host. This person should be able to issue direct commands that would otherwise be ignored or denied during an inbound call, such as:

- Assigning a job function
- Adding a number to an inbound call flow
- Reading back emails
- Other privileged operations normally restricted to the host

Currently there is no mechanism to distinguish a trusted manager caller from any other inbound caller.

## Solution

1. **Config model + persistence** — Add an `AgentManagerConfig` to `UserConfigService` with a phone number field, stored in SharedPreferences under `user_agent_manager_phone`.

2. **Settings UI** — Add an "Agent Manager" card in the User Settings tab (between Integrations and Demo Mode) with a phone number input field.

3. **Agent-level check** — Expose an `isAgentManager` helper on `AgentService` that compares the current remote caller's number against the stored manager phone (using normalized 10-digit comparison). When the caller is the agent manager:
   - `_checkReadAccess` treats them like the host (bypasses hostOnly/allowList restrictions).
   - The system prompt includes a note telling the LLM that this caller has elevated privileges and should be treated as the host for command execution.

4. **System prompt context** — When an inbound call is active and the caller is the agent manager, append an `## Agent Manager` section to the text agent instructions informing the LLM to honor direct requests from this caller.

## Files

- `phonegentic/lib/src/user_config_service.dart` — Added `AgentManagerConfig` model + load/save
- `phonegentic/lib/src/widgets/user_settings_tab.dart` — Added Agent Manager UI card
- `phonegentic/lib/src/agent_service.dart` — Added `isAgentManager` check, updated `_checkReadAccess` and `_buildTextAgentInstructions`
- `readmes/features/agent-manager-role.md` — This file
