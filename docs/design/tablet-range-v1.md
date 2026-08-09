# Tablet range v1 (#736)

## Decision

**Tablet gets the desktop cockpit with touch-sized targets — but only when a
keyboard is present.** A bare tablet gets the compact (mobile web cockpit)
treatment when *width* says so; it does **not** lose desktop pickers merely
because the pointer is coarse.

This is an operator decision. Do not revisit it here; implement it.

## Upstream rule (#735 / #779)

**`pointer-coarse` decides hit targets, spacing, and gesture affordances; width
decides layout and information density.** Stated in
`docs/subsystems/web_cockpit.md` and the workspace shell moduledoc.

This track **adopts** that rule. It does not reintroduce layout hides via
`pointer-coarse:hidden`. Header pickers use `max-sm:hidden` + the width-only
`@media (max-width: 639px)` block from #735. Touch targets stay on
`pointer-coarse:*`.

## Why the range fell through (pre-#735)

Breakpoint use was bimodal (`sm` / `lg`). Layout was also wrongly tied to
pointer, so tablets either got desktop chrome at a bad width or mobile chrome
stretched wide. #735 fixed the mechanism; this issue designs the band and the
keyboard upgrade path.

## What #736 adds on top of #735

| Piece | Role |
|--------|------|
| Physical `keydown` evidence | Not a media query. Chords / nav / F-keys only — not soft-keyboard printables. Persists `casein:cockpit-keyboard=1`. |
| Explicit override | `casein:cockpit-layout` = `auto` \| `compact` \| `desktop`, same client-persist pattern as sidebar sort. ⋯ menu. |
| `data-cockpit-layout` | Set **only** when override or keyboard must change what #735 CSS would do. **Auto leaves the attribute unset** so #735 media queries alone decide the default. |
| Multi-column panels | Demote `lg:` → `md:` where landscape tablet has room (run / agent activity / files). |

### Trap (do not “fix” with pointer)

Magic Keyboard + trackpad often reports `pointer: fine` and already keeps
desktop layout under #735. **Smart Keyboard Folio** has keys and no trackpad —
stays `coarse` while keyboard-driven. Pointer is not a keyboard proxy; upgrade
is on keydown evidence + override.

## Degrade direction

- Bare / narrow must never get chrome it cannot drive.
- Keyboard tablet should reach full cockpit within one physical keystroke when
  something still compact-treats the band (chrome-narrow, forced compact).
- Wide coarse bare tablet already has desktop pickers via #735 — do not force
  compact from pointer alone.

## Orientation

| | Bare | Keyboard |
|--|------|----------|
| **Portrait** | Width may be phone-class (`max-sm`) → compact layout. Touch targets via `pointer-coarse`. | Same width rules; override or keydown can force desktop when room exists (≥640 and not chrome-narrow). |
| **Landscape** | Wide → desktop pickers (#735); key bar may still show as a touch affordance (not a layout switch). | Desktop chrome; multi-column panels at `md` (768). |

Terminal cell geometry does not reflow with chrome; chrome first.

## Walk (what was wrong before apply)

1. **Pre-#735 coarse iPad Folio** — Forced compact via pointer alone; fixed upstream by #735 (`max-sm` layout).
2. **Landscape coarse** — Wasted width when panels waited for `lg` (1024); demoted to `md`.
3. **Phone ≤639** — Compact correct; palette #763 `max-sm` collapse correct.
4. **`data-chrome-narrow`** — Compact pickers correct; keyboard evidence must not show pickers that do not fit (still null under auto).
5. **No keyboard preference path** — Added override + keydown evidence for Folio-class and operator force.

## Apply (files)

- `assets/js/cockpit_layout.mjs` + early stamp inside the **existing** hashed
  theme `<script>` in `root.html.heex` (CSP: recompute `@script_src` hash in
  `router.ex` when that script changes).
- Additive CSS for `html[data-cockpit-layout=…]` only — does not replace #735
  media blocks.
- Overflow menu Layout override; `md:` panel promotes.
- Markup keeps `max-sm:hidden` on pickers (#735 contract).

## Out of scope

- #734 reduced-motion, #735 mechanism (landed), #733 motion chrome.
- Shrinking touch targets.
- New Tailwind breakpoint token.
