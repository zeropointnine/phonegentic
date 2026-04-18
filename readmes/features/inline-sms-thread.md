# Inline SMS Thread Display in Agent Panel

## Problem

When the agent conducts an SMS/text conversation, SMS events appear as plain system messages in the agent panel (e.g. "Inbound SMS from +1234567890: …"). There's no visual distinction between SMS activity and other system events, no conversational threading, and no way to see the send/receive direction at a glance. We need a dedicated inline component that renders SMS messages like a real messaging thread — with speech-bubble shapes, left/right alignment, identicons, contact info, and timestamps.

## Solution

Added a new `MessageType.sms` enum value and `ChatMessage.sms()` constructor to cleanly separate SMS messages from generic system messages. Created `SmsThreadBubble`, a speech-bubble shaped widget rendered via `CustomPainter` (`_SpeechBubblePainter`) that mimics the app's message icon outline — a rounded rectangle with a small triangular tail at the bottom corner.

**Design decisions:**
- **Speech-bubble shape:** CustomPainter draws a rounded-rect path with a triangular tail. The tail anchors bottom-left for inbound, bottom-right for outbound. The middle region grows vertically while corner radii stay fixed at 14px.
- **Left/right alignment:** Inbound messages align left; outbound messages align right — matching natural chat UX.
- **Recipe-card header:** Each bubble has a compact header row with ContactIdenticon, display name, phone number (if contact known), direction arrow icon, and local-time timestamp in monospace.
- **Expandable body:** Message text shows up to 4 lines by default. Clicking the bubble toggles expansion to show full text plus a metadata footer with direction label and full date/time.
- **Theme-aware:** Uses `AppColors` throughout — surface/accent fills, border tints, text hierarchy — so it adapts across Amber VT-100, Miami Vice, and Light themes.

**Integration:**
- `_MessageBubble` in `agent_panel.dart` now routes `MessageType.sms` to `SmsThreadBubble` before checking other types.
- `_onInboundSms`, `_handleSendSms`, and `_handleReplySms` in `agent_service.dart` now emit `ChatMessage.sms()` with structured metadata (`sms_direction`, `sms_remote_phone`, `sms_contact_name`) instead of `ChatMessage.system()`.
- Transcript exporter labels SMS messages as "SMS" instead of "System".

## Files

### Created
- `phonegentic/lib/src/widgets/sms_thread_bubble.dart` — `SmsThreadBubble` widget + `_SpeechBubblePainter`

### Modified
- `phonegentic/lib/src/models/chat_message.dart` — added `MessageType.sms` and `ChatMessage.sms()` constructor
- `phonegentic/lib/src/widgets/agent_panel.dart` — import + routing for SMS messages
- `phonegentic/lib/src/agent_service.dart` — switched 3 SMS handlers to `ChatMessage.sms()`
- `phonegentic/lib/src/transcript_exporter.dart` — SMS label in transcript export
- `readmes/features/inline-sms-thread.md` — this file
