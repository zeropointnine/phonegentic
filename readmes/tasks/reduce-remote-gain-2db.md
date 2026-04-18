# Reduce remote party audio gain by 2 dB

## Problem

Remote party audio was occasionally over-modulated, causing clipping/distortion in certain call scenarios. The gain was set to 1.5× linear.

## Solution

Reduced the linear gain from **1.5** to **1.19** (≈ −2 dB relative to the previous level: `1.5 × 10^(−2/20) ≈ 1.19`).

## Files

- `phonegentic/lib/src/callscreen.dart` — updated `setRemoteGain` value in `_enterCallMode()`
