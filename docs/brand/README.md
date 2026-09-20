# DeployBar — icon set

Rocket mark, five menu bar drawings. Everything here is generated from the
master SVGs in `svg/`; regenerate those first if the drawing changes.

## Menu bar (the primary asset)

| State | Asset name | Drawing |
|---|---|---|
| Idle | `MenuBarIdle` | rocket upright, engine cold |
| Deploying | `MenuBarDeploying` | rocket climbing at 45°, two detached exhaust marks |
| Succeeded | `MenuBarSucceeded` | rocket upright, circular check badge overlapping the hull |
| Failed | `MenuBarFailed` | rocket upright, triangular exclamation badge overlapping the hull |
| Signed out | `MenuBarLoggedOut` | rocket upright, triangular question-mark badge overlapping the hull |

Rules these follow, and that you must keep when editing:

- **Template images.** Pure black + alpha, `isTemplate = true`. Never tint them
  in code — macOS inverts them for dark mode, dims them when the app is
  inactive, and knocks them out to white while the menu is open.
- **18 pt canvas** (72-unit grid at 4×). The glyph fills ~15 pt of that box, so
  it sits at the same weight as the system's own status items (wifi and the
  speaker measure 15 pt; airplay 17 pt). Rendered: idle 11.3 × 15.3 pt,
  deploying 14.3 × 14.3 pt, succeeded 14.0 × 15.7 pt, failed ~14.3 × 15.2 pt.
  The five drawings are deliberately within ~1.4 pt of each other in height, so
  the bar does not appear to twitch when the state changes.
- **Static.** No animation, no timers, no frame swapping. macOS has no animated
  status item; you would have to swap frames on a `Timer`, and a glyph that
  twitches in the corner of your eye is a nuisance.
- **Square status item** (`NSStatusItem.squareLength`) so neighbours never reflow.
- Nothing thinner than ~1.1 pt. The window is knocked out of the hull, not drawn
  on top, so it stays open at 1×.
- Badge cutouts follow the badge silhouette: a circle for success and a triangle
  for failure and signed out, each with a 3-unit gap from the rocket on the 72-unit grid.

Colour lives inside the popover — green / amber / red per deployment — never in
the bar.

## What is in here

```
svg/                    master drawings (edit these)
png/                    menubar states @1x/@2x/@3x, app icon 16→1024, README banner
../../DeployBar/Assets.xcassets/  AppIcon + 5 template imagesets
DeployBar.iconset/      + make-icns.sh  →  DeployBar.icns
MenuBarIcon.swift       DeployState enum and a status-item controller
web/                    favicons, apple-touch-icon, og image
```

### Note on `@2x` in filenames

The export tool cannot write `@` in a filename, so double/triple-density files
are named `-2x` / `-3x`. The asset catalog's `Contents.json` already points at
those names and Xcode is happy with them — the `@2x` suffix is a convention, not
a requirement. `make-icns.sh` renames the iconset files back to `@2x` before
calling `iconutil`, because *that* tool does require the convention.

## Build the .icns

```bash
cd brand/rocket && ./make-icns.sh
```

## Palette (app icon and marketing only)

| Token | Hex | Use |
|---|---|---|
| Ink top | `#334155` | icon tile gradient start |
| Ink base | `#020617` | icon tile gradient end, dark backgrounds |
| Cold light | `#60A5FA` | top-left glow on the tile, at 45% |
| Rocket | `#FFFFFF` | the mark on the tile |

Tile corner radius is 114 / 512 (22.3%). Clear space around the lockup: one
rocket-width on every side.
