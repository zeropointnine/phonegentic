# Message Bubble Outline Style

## Problem

The SMS messages UI in `conversation_view.dart` uses plain filled bubbles with box shadows (iMessage style), while the agent panel's SMS thread bubbles (`sms_thread_bubble.dart`) use a speech-bubble outline with an accent-colored border and a small triangular tail. The user wants the messages UI to match the agent panel's outlined speech-bubble look — just the text in the bubble, no header elements.

## Solution

Port the `_SpeechBubblePainter` from `sms_thread_bubble.dart` into `conversation_view.dart` and replace the `BoxDecoration`-based bubble rendering with a `CustomPaint` widget using the painter. Inbound bubbles get a surface fill with a subtle accent border; outbound bubbles get an accent-tinted fill with a stronger accent border. The tail position reflects message direction and the `showTail` flag.

Added dial (phone) and contact (person) icon buttons to the conversation header, placed to the right of the contact name/phone and to the left of the close button. The dial button calls the remote number via SIP; the contact button opens the contact panel for that number.

## Files

- `phonegentic/lib/src/widgets/conversation_view.dart` — modified `_MessageBubble`, added `_SpeechBubblePainter`, added dial/contact header buttons
