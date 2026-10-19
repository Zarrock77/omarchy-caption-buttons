# Caption Buttons

A tiny [Omarchy](https://omarchy.org) shell plugin that gives every Hyprland window
Windows-style caption buttons. It does not depend on the bar, so it works with the
stock bar or any replacement bar (floating bar, etc.).

| Control | Action |
|---------|--------|
| `⠿` grip | Drag to move the window (it is floated first). Drop it on a screen edge to **snap** |
| `—` | Minimize to a special workspace; click the app in your dock to bring it back |
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

## Settings

A pin icon (󰐃) is added to your bar. Click it to open the settings popup:

- enable/disable the plugin
- show/hide each button (minimize, maximize, close) and the resize grip
- pill position (top right / top left), size and opacity
- snap on/off, edge sensitivity and gap

Settings are stored in `~/.config/omarchy/caption-buttons.json` and apply instantly. You can
also edit that file by hand.

## Install

```sh
omarchy plugin add https://github.com/Zarrock77/omarchy-caption-buttons.git --enable
omarchy bar put io.github.zarrock77.caption-buttons --section right
```

## Remove

```sh
omarchy plugin remove io.github.zarrock77.caption-buttons --yes
```

## Notes

- Requires Omarchy with Hyprland's Lua dispatcher API and `hyprctl` on `PATH`.
- Buttons are hidden for true-fullscreen windows, windows narrower than 260 px, and when a
  more recently focused window covers them.
- Minimized windows live on `special:caption-minimized`. There is no on-screen shelf: restore a minimized window from your dock (the dock must move it
  back to a normal workspace before focusing it) or with your own keybinding.

## License

MIT
