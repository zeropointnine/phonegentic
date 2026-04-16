
# Inbound Call Flows
We need a new type of job function that is an inbound call flow which a user can create from the existing job function dropdown, in the bottom portion "+ Inbound Call Flow"

An inbound call flow can handle multiple job functions which can be assigned to a number, or group of numbers with some simple ordering rules, for instance, a job function takes precidence and can be dragged up or down the list, which ever phone numbers match that job function will execute or go down the list, this needs to appear intutive, so the modal that creates this must be slick.

The idea is say that inbound call comes from Lee, who we just called, we look up the context and refer to the new ibound call flows to see what to do, or what job function is appropriate.

- With this, we need to improve answering a call, we need to be able to run an inbound call flow and enable it, find the best way to include this in our limited space without moving stuff around, it can just be enabled from the dropdown - and maybe a small indicator on the main top nav. Make sure the agent can answer the call, in the ring settings we need a toggle button to allow agent to answer calls (if we are not on one)

We also need a new way to enable/disable toggle the ring (maybe a bell icon) at top, a universal no symbol with a bell for muted.

What we want to allow the user to select or upload a ringtone that will loop and play when an inbound call is answered, aldo in this Call Answer, allow the user to select agent can auto answer calls, the inbound call flow we created can handle the job function selection of what to do. Make sure the agent as the ability to answer the calls.

---

## Solution

### Architecture

Five interconnected pieces, all fitting into the existing Provider + SQLite architecture:

1. **Inbound Call Flow** — new model, DB table, service, and editor UI for routing inbound calls to the right job function by caller number
2. **Ringtone system** — bundled WAV playback via `just_audio`, ringtone selection/upload, looping playback on incoming ring
3. **Ring toggle** — bell icon in the top bar to enable/disable ring with a muted indicator
4. **Agent auto-answer** — toggle in ring settings popover; agent accepts calls when user is not on one
5. **Inbound call wiring** — on incoming SIP INVITE, resolve flow rules, play ringtone, optionally auto-answer

### Key design decisions

- **Ring toggle in top bar**: Compact 32x32 bell icon placed between the SIP status pill and the existing nav buttons. Tap toggles ring on/off; long-press opens a settings popover for ringtone selection, preview, and auto-answer toggle. A green dot indicator appears when an inbound call flow is enabled.
- **Inbound Call Flow in dropdown**: Added as a second action item (after "New Job Function") in the existing `_JobFunctionDropdown` with a `call_received` icon. Opens a full-screen overlay editor matching the existing `JobFunctionEditor` pattern.
- **Reorderable rules**: Each flow contains a list of rules evaluated top-to-bottom. Each rule maps a set of phone patterns (E.164, `*` wildcard) to a job function. Drag-to-reorder sets priority implicitly.
- **Auto-answer**: Static `CallScreenWidget.acceptCall()` method lets the dialpad trigger call acceptance without a mounted call screen, using voice-only media constraints.
- **DB v13 migration**: New `inbound_call_flows` table with rules stored as JSON, following the same CRUD pattern as `job_functions`.

### Files

**New files:**
- `phonegentic/lib/src/models/inbound_call_flow.dart` — `InboundCallFlow` and `InboundRule` models with phone pattern matching
- `phonegentic/lib/src/inbound_call_flow_service.dart` — CRUD service, flow resolution, editor open/close
- `phonegentic/lib/src/ringtone_service.dart` — `just_audio` player, ring toggle, ringtone selection, auto-answer persistence
- `phonegentic/lib/src/widgets/inbound_call_flow_editor.dart` — overlay editor with reorderable rules list

**Modified files:**
- `phonegentic/pubspec.yaml` — registered WAV asset files
- `phonegentic/lib/main.dart` — added `RingtoneService` and `InboundCallFlowService` providers
- `phonegentic/lib/src/db/call_history_db.dart` — version 13 migration, `inbound_call_flows` table + CRUD
- `phonegentic/lib/src/dialpad.dart` — ring toggle in top bar, ring settings popover, inbound call flow editor overlay, ringtone start/stop in `callStateChanged`, auto-answer logic
- `phonegentic/lib/src/widgets/agent_panel.dart` — "+ Inbound Call Flow" entry in job function dropdown
- `phonegentic/lib/src/callscreen.dart` — static `acceptCall()` method for programmatic answer
- `readmes/features/inbound-enhancements.md` — this file
