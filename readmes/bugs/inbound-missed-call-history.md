# Inbound & Missed Calls Not Appearing in Call History

## Problem

Inbound calls and missed calls are not recorded in call history. Two related issues:

1. **Inbound calls not recorded**: `notifyCallPhase(CallPhase.ringing)` is never called from the dialpad during the inbound ring phase. The call history record is only created when `notifyCallPhase` receives `initiating` or `ringing`, but for inbound calls this path only runs if the CallScreen's `_pushCallPhase` fires for those specific SIP states — which it doesn't, since the CallScreen is created after `CALL_INITIATION` and may never see `PROGRESS` if the call ends quickly.

2. **Missed calls never written**: The `'missed'` status is supported in search, filtering, and display (`_statusColor`, `CallSearchParams.fromQuery`), but the `endCallRecord` pipeline only ever writes `'completed'` or `'failed'`. There's no logic to detect that an inbound call was never answered.

## Solution

1. **Record inbound calls at ring time**: In `_handleInboundRing`, call `agent.notifyCallPhase(CallPhase.ringing, ...)` with the inbound call details. This creates the call history record immediately when ringing starts.

2. **Detect missed calls**: In `AgentService.notifyCallPhase`, when ending a call, check if it was inbound (`!_isOutbound`) and never connected (`_connectedAt == null`). If so, mark the status as `'missed'` instead of `'completed'` or `'failed'`.

3. **UI polish**: Use `phone_missed_rounded` icon for missed calls in the history panel for better visual distinction.

## Files

- `phonegentic/lib/src/dialpad.dart` — add `notifyCallPhase` call in `_handleInboundRing`
- `phonegentic/lib/src/agent_service.dart` — missed-call detection in `notifyCallPhase`
- `phonegentic/lib/src/widgets/call_history_panel.dart` — missed call icon
