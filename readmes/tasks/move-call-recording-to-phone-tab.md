# Move call recording setting to Phone tab

## Problem

The "Auto-record calls" toggle was under the Agent settings tab, but call recording is a phone-level concern — it applies regardless of agent configuration. It belongs with the other phone/SIP settings.

## Solution

Moved the `_buildCallRecordingCard` widget, its `_recording` state, and `_updateRecording` helper from `agent_settings_tab.dart` to `register.dart`'s Phone tab. The card sits after the HD Codec card. No logic changes — same `CallRecordingConfig` model and `AgentConfigService` persistence.

## Files

- `phonegentic/lib/src/widgets/agent_settings_tab.dart` — removed recording state, load, update, and card widget
- `phonegentic/lib/src/register.dart` — added recording state, load (alongside conference config), update, and card widget in `_buildPhoneTab`
