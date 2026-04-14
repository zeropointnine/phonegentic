# HTML SLICKENING

## Problem

The index page needed a visually striking presentation to impress potential users and investors. A single static color scheme doesn't showcase the app's visual identity well. The page needed:

- A theme selector dropdown supporting "Amber VT-100" and "Miami Vice Neon" themes
- Smooth 10-second CSS transitions between themes that interpolate all colors
- Auto-cycling between themes on idle so visitors see both without interacting
- Hero screenshot crossfading between the two theme screenshots
- Video-ready container for future demo videos (landscape)
- Sticky theme preference via localStorage

## Solution

Implemented a dual-theme system driven entirely by CSS custom properties on `<html>`:

- **CSS custom properties**: All colors (`--gold`, `--bg`, `--text`, etc.) are defined in `.theme-vt100` and `.theme-miami` class blocks. Switching the class on `<html>` morphs every color across the page.
- **10s transitions**: A comprehensive selector list applies `transition: color, background-color, border-color, box-shadow 10s ease-in-out` to all themed elements. SVG `path`, `circle`, `rect`, etc. get separate `fill`/`stroke` transitions.
- **SVG recoloring**: All 75+ inline SVG attributes were changed from hardcoded `#d4a853`/`#efc35a` to `var(--gold)`/`var(--gold-bright)` so they participate in theme transitions.
- **Nav dropdown**: A `JetBrains Mono`-styled dropdown in the nav with color swatches for each theme. Click to select, persisted to `localStorage` under key `pg-theme`.
- **Auto-cycle**: A 15-second `setInterval` toggles themes if the user hasn't manually chosen one. Stops immediately on any manual selection.
- **Hero crossfade**: Two stacked screenshots (`shot_vt100.png`, `shot_miami_vice.png`) with `opacity` crossfade tied to the active theme class. During the 10s transition, both images blend visually.
- **Video container**: A `.hero-media` wrapper with a hidden `<video>` element. Adding `has-video` class to `.hero-media` swaps the screenshots for the video player. Landscape aspect ratio (16:9).
- **Hardcoded color cleanup**: Replaced all hardcoded `rgba(212,168,83,...)` values in hover states, gradients, and backgrounds with the appropriate CSS variable equivalents.

## Files

- `static/index.html` — CSS theme definitions, transition rules, SVG recoloring, nav dropdown, hero crossfade, video container, JS theme logic
- `static/shot_vt100.png` — Amber VT-100 hero screenshot
- `static/shot_miami_vice.png` — Miami Vice Neon hero screenshot
