# Dialpad Search Icon — Animated Positioning & Styling

## Problem

The autocomplete search icon on the dialpad was statically pinned to the top-right corner at a fixed position. It needed to start more centered (roughly above the "3" key), animate smoothly to the right as the text input widens, use a unique color distinct from the primary accent, and be sized to 20px.

## Solution

**Positioning** — replaced static `Positioned` with `AnimatedPositioned` using text-width-aware placement. The icon's `right` offset is clamped between 8px (hard right) and `displayWidth * 0.19` (aligned above the "3" key). The offset is derived from estimated text half-width (`raw.length * charWidth / 2`) subtracted from center, minus a 44px gap for the icon itself. As the user types more characters, the estimated text width grows, the gap shrinks, and the icon naturally pushes toward the right edge — all without overlapping the centered text.

**Size** — bumped to 24px (20% larger than original 20px).

**Color** — `AppColors.burntAmber` (electric purple `#8B5CF6` in Miami Vice, warm amber `#C97A1A` in VT-100) at 55% alpha when idle, full when active.

**Easing** — `Curves.easeOutCubic` over 380ms for smooth, natural deceleration on each keystroke.

**Auto-show for name search** — when input contains letters and autocomplete results exist, the dropdown opens automatically without requiring a tap on the search icon. Digit-only input still requires manual tap.

## Files

| Action | File |
|--------|------|
| Modify | `phonegentic/lib/src/dialpad.dart` — `_buildNumberDisplay()`: text-width-aware positioning with `AnimatedPositioned`, icon size 24px, `burntAmber` color; `_onDigitsChanged()`: auto-open dropdown when `hasLetters` and matches found |
