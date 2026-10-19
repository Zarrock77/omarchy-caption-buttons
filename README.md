# Caption Buttons

A tiny [Omarchy](https://omarchy.org) shell plugin that gives every Hyprland window
Windows-style caption buttons. It does not depend on the bar, so it works with the
stock bar or any replacement bar (floating bar, etc.).

| Control | Action |
|---------|--------|
| `⠿` grip | Drag to move the window (it is floated first). Drop it on a screen edge to **snap** |
| `—` | Minimize to a special workspace; restore from the shelf chip (bottom-left) |
| `▢` / `❐` | Toggle Hyprland's maximized mode |
| `✕` | Close |
| `◢` (bottom-right) | Drag to resize |

## Snap zones

While dragging by the grip, a preview shows where the window will land when released:

- left / right edge → half screen
- any corner → quarter screen
- top edge → maximized
- bottom edge alone → nothing

Zones use the monitor's work area, so bars and reserved space are respected, and they
work across monitors.

## Install

```sh
omarchy plugin add https://github.com/Zarrock77/omarchy-caption-buttons.git --enable
```

## Remove

```sh
omarchy plugin remove io.github.zarrock77.caption-buttons --yes
```

## Notes

- Requires Omarchy with Hyprland's Lua dispatcher API and `hyprctl` on `PATH`.
- Buttons are hidden for true-fullscreen windows, windows narrower than 260 px, and when a
  more recently focused window covers them.
- Minimized windows live on `special:caption-minimized`. Any tool that focuses a window on that
  workspace should move it back first; the shelf chips do this for you.

## License

MIT
