# Caption Buttons

A tiny [Omarchy](https://omarchy.org) shell plugin that gives every Hyprland window
Windows-style caption buttons. It does not depend on the bar, so it works with the
stock bar or any replacement bar (floating bar, etc.).

## Titlebar mode (default)

Every window gets a real titlebar above it, like Windows: title on the left, minimize / maximize /
close on the right. Drag the bar to move the window (drop on an edge to snap), double-click to
maximize. It can be switched off in the settings popup to get the small floating pill instead.

Hyprland has no titlebars, so the plugin puts each window in a one-window group (which makes
Hyprland reserve a strip above it) and draws the bar there. This needs the groupbar to be reserved
but invisible; add this to `~/.config/hypr/looknfeel.lua`:

```lua
hl.config({
  group = {
    auto_group = false, -- new windows must not open as tabs of the focused one
    groupbar = {
      height = 26, gaps_in = 0, gaps_out = 0,
      indicator_height = 1, indicator_gap = 0,
      render_titles = false, gradients = true, keep_upper_gap = true,
      col = { active = "rgba(00000000)", inactive = "rgba(00000000)" },
    },
  },
})
```

The plugin expects a 27 px strip (26 + 1 indicator). Omarchy's group keybindings (Super+G etc.)
are not meaningful in this mode.

## Overlay mode

| Control | Action |
|---------|--------|
| `⠿` grip | Drag to move the window (it is floated first). Drop it on a screen edge to **snap** |
| `—` | Minimize to a special workspace; click the app in your dock to bring it back |
| `▢` / `❐` | Toggle Hyprland's maximized mode |
| `✕` | Close |
| `◢` (bottom-right) | Drag to resize |

## Snap layouts menu

Like Windows 11: press and hold on a titlebar (or the pill grip) and start dragging. A layout
picker appears at the top of the screen; move the pointer over a zone and release to put the
window there. Nine layouts: halves, 2/3 + 1/3, 1/3 + 2/3, stacked, thirds, a column next to two
stacked windows (both ways), quadrants and 1/4 + 1/2 + 1/4. It can be switched off in the settings
popup.

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
