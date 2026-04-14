# Call screen: video preview toggle and call timer

## Problem

The local video preview (self-view) was always visible during video calls with
no way to dismiss it. Additionally, the call duration timer was only displayed
during the pre-connect/voice overlay and disappeared once a call was confirmed.

## Solution

1. **Camera toggle in top bar**: Added a videocam icon button in the top bar
   (next to the headphones/audio button) that toggles the local video PiP
   overlay on/off. Hidden by default (`_showLocalVideo = false`). Only appears
   when a call is confirmed and a local video stream exists.

2. **Floating timer chip**: Added a `Positioned` timer pill at the top-center
   of the content area that displays during confirmed calls. Reuses the
   existing `_timeLabel` ValueNotifier. Styled with a semi-transparent
   `AppColors.card` background and rounded corners.

## Files

- `phonegentic/lib/src/callscreen.dart` — added `_showLocalVideo` state,
  camera bar button, gated local video rendering, and timer chip overlay
