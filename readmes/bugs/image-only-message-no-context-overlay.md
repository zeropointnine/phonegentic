# Image-only messages can't be right-clicked / long-pressed

## Problem

Right-clicking (desktop) or long-pressing (mobile) an image-only MMS bubble in
the conversation view does nothing: the iOS-style context overlay never
appears, so the user has no way to react, reply, copy, or delete an image
that was received or sent without any accompanying text. Text bubbles, and
bubbles with both text and images, work fine.

## Root cause

In `conversation_view.dart`, each `_MessageBubble` owns a `bubbleKey` that
the context overlay uses to measure and snapshot the "focused bubble"
rect. The key is only attached in `_buildBubbleWithReactionBadges`, which
is itself gated on `if (message.text.isNotEmpty)`. For image-only messages
there's no widget carrying the key, so `sourceKey.currentContext` is
`null` and `MessageContextOverlay.show` returns immediately at its first
guard:

```dart
final ctx = sourceKey.currentContext;
if (ctx == null) return;
```

The outer `GestureDetector` still receives `onSecondaryTapDown` /
`onLongPress` — we just never get anywhere useful because the overlay has
nothing to anchor to.

## Solution

Attach `bubbleKey` to whichever widget represents the message's visual
anchor:

- Text present (with or without images): keep the key on the speech
  bubble's `RepaintBoundary`, same as today. The reaction bar / menu still
  anchor to the text portion which is what users expect.
- Image-only message: wrap the media `Wrap` in a `RepaintBoundary` and
  attach `bubbleKey` there, so the overlay measures + snapshots the image
  tile(s) and pops over them.

This fix is intentionally minimal — no gesture changes, no new state, no
new wrapper widgets. Just routing the existing key to the right widget
based on which parts of the bubble are actually rendered.

## Files

- Modified: `phonegentic/lib/src/widgets/conversation_view.dart`
- New: `readmes/bugs/image-only-message-no-context-overlay.md`
