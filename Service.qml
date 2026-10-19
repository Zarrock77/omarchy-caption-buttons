pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// Caption Buttons.
//
// Titlebar mode (default): every window lives in a one-window Hyprland group.
// The group makes Hyprland reserve a strip above the window; the native
// groupbar is made invisible (see the README) and this plugin draws a real
// titlebar there: title on the left, minimize / maximize / close on the right,
// drag the bar to move (drop on an edge to snap), double-click to maximize.
//
// Overlay mode: a small pill of buttons floats over the window's corner.
//
// State comes from `hyprctl`, actions go back through Hyprland Lua dispatchers,
// so the plugin works with any bar.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string parkedWorkspace: "special:caption-minimized"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/caption-buttons.json"
  readonly property int edgeInset: 6
  readonly property int minWindowW: 260
  // Strip reserved by Hyprland: groupbar height (26) + indicator (1).
  readonly property int barH: 27

  // Theme colors come straight from the current theme's colors.toml, so the
  // plugin does not depend on the shell's Color singleton (which third-party
  // plugins cannot rely on across Omarchy versions).
  readonly property string themeColorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  property color cBg: "#101315"
  property color cFg: "#cacccc"
  property color cAccent: "#798186"
  property color cUrgent: "#a55555"

  function parseColors(text) {
    var found = {}
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
      if (m) found[m[1]] = m[2]
    }
    if (found.background) root.cBg = found.background
    if (found.foreground) root.cFg = found.foreground
    if (found.accent) root.cAccent = found.accent
    if (found.urgent) root.cUrgent = found.urgent
    else if (found.color1) root.cUrgent = found.color1
  }

  FileView {
    id: colorsFile
    path: root.themeColorsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseColors(text())
    onFileChanged: colorsFile.reload()
  }

  readonly property var defaults: ({
    enabled: true,
    titlebar: true,
    showTitle: true,
    minimize: true,
    maximize: true,
    close: true,
    resizeHandle: true,
    corner: "top-right",
    scale: 100,
    opacity: 88,
    cornerRadius: 6,
    snap: true,
    snapLayouts: true,
    snapEdge: 20,
    snapGap: 8
  })
  property var cfg: root.defaults

  readonly property real uiScale: Math.max(0.6, Math.min(2, cfg.scale / 100))
  readonly property int buttonSize: Math.round(26 * uiScale)
  readonly property int buttonCount: 1 + (cfg.minimize ? 1 : 0) + (cfg.maximize ? 1 : 0) + (cfg.close ? 1 : 0)
  readonly property int pillW: buttonSize * buttonCount + 4
  readonly property int pillH: buttonSize
  readonly property int snapEdge: cfg.snapEdge
  readonly property int snapGap: cfg.snapGap
  readonly property real barAlpha: Math.max(0.2, Math.min(1, cfg.opacity / 100))

  property var clients: []
  property var monitors: []
  property var pills: []
  property var bars: []
  property var handles: []
  property var homes: ({})
  property var groupRequests: ({})

  property string dragAddress: ""
  property var snapZone: null

  function mergeConfig(text) {
    var next = Object.assign({}, root.defaults)
    try {
      var parsed = JSON.parse(text)
      for (var key in root.defaults)
        if (parsed[key] !== undefined && typeof parsed[key] === typeof root.defaults[key]) next[key] = parsed[key]
    } catch (error) {}
    root.cfg = next
    root.rebuild()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.mergeConfig(text())
    onFileChanged: configFile.reload()
    onLoadFailed: root.mergeConfig("{}")
  }

  // ---------------------------------------------------------------- polling

  Process {
    id: poller
    command: ["bash", "-c", "printf '{\"c\":%s,\"m\":%s}' \"$(hyprctl clients -j)\" \"$(hyprctl monitors -j)\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.clients = data.c
          root.monitors = data.m
          root.rebuild()
        } catch (error) {}
      }
    }
  }

  function poll() { if (!poller.running) poller.running = true }

  Timer {
    interval: 200
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.poll() }
  }

  // ----------------------------------------------------------------- model

  function monitorByName(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === name) return root.monitors[i]
    return null
  }

  function monitorById(id) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].id === id) return root.monitors[i]
    return null
  }

  function logicalSize(mon) {
    var scale = mon.scale > 0 ? mon.scale : 1
    var rotated = mon.transform % 2 === 1
    return { w: (rotated ? mon.height : mon.width) / scale, h: (rotated ? mon.width : mon.height) / scale }
  }

  function monitorAt(gx, gy) {
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      var s = root.logicalSize(m)
      if (gx >= m.x && gx < m.x + s.w && gy >= m.y && gy < m.y + s.h) return m
    }
    return null
  }

  function screenByName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  function overlaps(ax, ay, aw, ah, bx, by, bw, bh) {
    return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah
  }

  function rebuild() {
    var visible = []
    for (var i = 0; i < root.clients.length; i++) {
      var c = root.clients[i]
      if (!c.mapped || c.hidden || c.workspace.id < 0) continue
      var mon = root.monitorById(c.monitor)
      if (!mon || mon.activeWorkspace.id !== c.workspace.id || !root.screenByName(mon.name)) continue
      visible.push({ c: c, mon: mon })
    }

    // Titlebar mode keeps every normal window in a one-window group (and
    // undoes that when the mode is switched off).
    root.syncGroups(visible)

    if (!root.cfg.enabled) {
      root.pills = []
      root.bars = []
      root.handles = []
      return
    }

    var nextPills = []
    var nextBars = []
    var nextHandles = []
    for (var v = 0; v < visible.length; v++) {
      var w = visible[v].c
      var m = visible[v].mon
      if (w.fullscreen === 2 || w.size[0] < root.minWindowW || w.size[1] < 120) continue

      var grouped = w.grouped && w.grouped.length === 1
      var useBar = root.cfg.titlebar && grouped
      var px = root.cfg.corner === "top-left" ? w.at[0] + root.edgeInset : w.at[0] + w.size[0] - root.pillW - root.edgeInset
      var py = w.at[1] + root.edgeInset
      var bx = w.at[0]
      var by = w.at[1] - root.barH
      var hx = w.at[0] + w.size[0] - 18
      var hy = w.at[1] + w.size[1] - 18

      // Hide anything covered by a window that was focused more recently.
      var coveredPill = false, coveredBar = false, coveredHandle = false
      for (var k = 0; k < visible.length; k++) {
        var o = visible[k].c
        if (o === w || o.focusHistoryID >= w.focusHistoryID) continue
        var oy = o.at[1] - (o.grouped && o.grouped.length === 1 && root.cfg.titlebar ? root.barH : 0)
        var oh = o.size[1] + (o.at[1] - oy)
        if (root.overlaps(px, py, root.pillW, root.pillH, o.at[0], oy, o.size[0], oh)) coveredPill = true
        if (root.overlaps(bx, by, w.size[0], root.barH, o.at[0], oy, o.size[0], oh)) coveredBar = true
        if (root.overlaps(hx, hy, 16, 16, o.at[0], oy, o.size[0], oh)) coveredHandle = true
      }

      var base = {
        address: w.address, mon: m.name, floating: w.floating, maxed: w.fullscreen === 1,
        winX: w.at[0], winY: w.at[1], winW: w.size[0], winH: w.size[1],
        wsId: w.workspace.id, monX: m.x, monY: m.y,
        cls: w.class || w.initialClass || "", title: w.title || w.class || "",
        focused: w.focusHistoryID === 0, bar: useBar
      }
      if (useBar) {
        // A window can straddle two monitors: draw one bar segment per monitor
        // it touches. The title sits on the left-most segment, the buttons on
        // the right-most one.
        for (var mi = 0; mi < root.monitors.length; mi++) {
          var sm = root.monitors[mi]
          if (!root.screenByName(sm.name)) continue
          var ss = root.logicalSize(sm)
          var x0 = Math.max(bx, sm.x), x1 = Math.min(bx + w.size[0], sm.x + ss.w)
          if (x1 - x0 < 1 || by + root.barH <= sm.y || by >= sm.y + ss.h) continue
          nextBars.push(Object.assign({}, base, {
            key: w.address + "@" + sm.name, mon: sm.name, monX: sm.x, monY: sm.y,
            px: x0 - sm.x, py: by - sm.y, segW: x1 - x0,
            hasLeft: bx >= sm.x - 0.5, hasRight: bx + w.size[0] <= sm.x + ss.w + 0.5,
            show: !coveredBar
          }))
        }
      } else {
        var pm = root.monitorAt(px, py) || m
        nextPills.push(Object.assign({}, base, { mon: pm.name, monX: pm.x, monY: pm.y, px: px - pm.x, py: py - pm.y, show: !coveredPill }))
      }
      var hm = root.monitorAt(hx + 8, hy + 8) || m
      nextHandles.push(Object.assign({}, base, { mon: hm.name, monX: hm.x, monY: hm.y, px: hx - hm.x, py: hy - hm.y,
        show: root.cfg.resizeHandle && !coveredHandle && w.fullscreen !== 1 }))
    }
    // While a window is being dragged its surfaces must stay exactly as they
    // are: recreating one (for instance when the window crosses to the other
    // monitor) would drop the pointer grab and the release would never arrive.
    var held = root.dragAddress
    if (held !== "") {
      var keep = function(list) { return list.filter(function(e) { return e.address === held }) }
      var drop = function(list) { return list.filter(function(e) { return e.address !== held }) }
      nextBars = drop(nextBars).concat(keep(root.bars))
      nextPills = drop(nextPills).concat(keep(root.pills))
      nextHandles = drop(nextHandles).concat(keep(root.handles))
    }
    root.bars = nextBars
    root.handles = nextHandles
    root.pills = nextPills
  }

  // One-window groups ------------------------------------------------------

  function syncGroups(visible) {
    var now = Date.now()
    var requests = Object.assign({}, root.groupRequests)
    for (var i = 0; i < visible.length; i++) {
      var w = visible[i].c
      var members = w.grouped ? w.grouped.length : 0
      if (root.cfg.enabled && root.cfg.titlebar) {
        // Needs a group, and nobody asked for one in the last second.
        if (members === 0 && w.fullscreen !== 2 && !(requests[w.address] > now - 1000)) {
          requests[w.address] = now
          root.dispatch("hl.dsp.group.toggle({ " + root.target(w.address) + " })")
          Qt.callLater(root.poll)
        }
      } else if (members === 1 && requests[w.address] !== undefined) {
        delete requests[w.address]
        root.dispatch("hl.dsp.group.toggle({ " + root.target(w.address) + " })")
        Qt.callLater(root.poll)
      }
    }
    root.groupRequests = requests
  }

  // --------------------------------------------------------------- actions

  function dispatch(lua) { Hyprland.dispatch(lua) }
  function target(address) { return "window = \"address:" + address + "\"" }

  function floatOn(address) { dispatch("hl.dsp.window.float({ action = \"on\", " + target(address) + " })") }
  function unmaximize(address) { dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"unset\", layout_aware = false, " + target(address) + " })") }
  function moveTo(address, x, y) { dispatch("hl.dsp.window.move({ x = " + Math.round(x) + ", y = " + Math.round(y) + ", " + target(address) + " })") }
  function resizeTo(address, w, h) { dispatch("hl.dsp.window.resize({ x = " + Math.round(w) + ", y = " + Math.round(h) + ", exact = true, " + target(address) + " })") }
  function resizeBy(address, dx, dy) { dispatch("hl.dsp.window.resize({ x = " + Math.round(dx) + ", y = " + Math.round(dy) + ", relative = true, " + target(address) + " })") }
  // Focusing a window warps the cursor to its centre; switch warping off for
  // the duration of the dispatch so clicking a titlebar leaves the pointer alone.
  Process { id: focusProcess }
  function focusWindow(address) {
    if (focusProcess.running) return
    var win = "address:" + address
    focusProcess.command = ["bash", "-c",
      "orig=$(hyprctl getoption cursor:no_warps | head -1 | grep -o 'true\\|false'); " +
      "hyprctl eval 'hl.config({ cursor = { no_warps = true } })' >/dev/null; " +
      "hyprctl dispatch \"hl.dsp.focus({ window = \\\"$1\\\" })\" >/dev/null; sleep 0.15; " +
      "hyprctl eval \"hl.config({ cursor = { no_warps = ${orig:-false} } })\" >/dev/null",
      "_", win]
    focusProcess.running = true
  }

  function minimize(info) {
    var next = Object.assign({}, root.homes)
    next[info.address] = info.wsId
    root.homes = next
    dispatch("hl.dsp.window.move({ workspace = \"" + root.parkedWorkspace + "\", follow = false, " + target(info.address) + " })")
    Qt.callLater(root.poll)
  }

  // Hyprland does not reassign a floating window to another monitor when it is
  // moved by dispatcher, so maximizing would fill the screen it *came from*.
  // Keep the window's monitor in step with where it actually is.
  function clientMonitorName(address) {
    for (var i = 0; i < root.clients.length; i++) {
      if (root.clients[i].address !== address) continue
      var m = root.monitorById(root.clients[i].monitor)
      return m ? m.name : ""
    }
    return ""
  }

  function moveToMonitor(address, name) {
    dispatch("hl.dsp.window.move({ monitor = \"" + name + "\", " + target(address) + " })")
  }

  function toggleMaximize(info) {
    var center = root.monitorAt(info.winX + info.winW / 2, info.winY + info.winH / 2)
    if (center && center.name !== root.clientMonitorName(info.address) && !info.maxed) {
      var x = info.winX, y = info.winY
      root.moveToMonitor(info.address, center.name)
      Qt.callLater(function() { root.moveTo(info.address, x, y) })
      maximizeTimer.pending = info
      maximizeTimer.restart()
      return
    }
    dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"toggle\", layout_aware = false, " + target(info.address) + " })")
  }

  Timer {
    id: maximizeTimer
    property var pending: null
    interval: 140
    onTriggered: {
      if (!pending) return
      root.dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"toggle\", layout_aware = false, " + root.target(pending.address) + " })")
      pending = null
    }
  }

  function closeWindow(info) {
    dispatch("hl.dsp.window.close({ " + target(info.address) + " })")
  }

  // ------------------------------------------------------------------ snap

  function workArea(mon) {
    var s = root.logicalSize(mon)
    var r = mon.reserved || [0, 0, 0, 0]
    return { x: mon.x + r[0], y: mon.y + r[1], w: s.w - r[0] - r[2], h: s.h - r[1] - r[3] }
  }

  function snapFor(gx, gy) {
    if (!root.cfg.snap) return null
    var mon = root.monitorAt(gx, gy)
    if (!mon) return null
    var a = root.workArea(mon)
    var e = root.snapEdge
    var left = gx <= a.x + e, right = gx >= a.x + a.w - e
    var top = gy <= a.y + e, bottom = gy >= a.y + a.h - e
    var g = root.snapGap
    var halfW = (a.w - g * 3) / 2, halfH = (a.h - g * 3) / 2
    var L = a.x + g, R = a.x + g * 2 + halfW, T = a.y + g, B = a.y + g * 2 + halfH
    var zone = null
    if (top && left) zone = { x: L, y: T, w: halfW, h: halfH }
    else if (top && right) zone = { x: R, y: T, w: halfW, h: halfH }
    else if (bottom && left) zone = { x: L, y: B, w: halfW, h: halfH }
    else if (bottom && right) zone = { x: R, y: B, w: halfW, h: halfH }
    else if (left) zone = { x: L, y: T, w: halfW, h: a.h - g * 2 }
    else if (right) zone = { x: R, y: T, w: halfW, h: a.h - g * 2 }
    else if (top) zone = { x: a.x + g, y: T, w: a.w - g * 2, h: a.h - g * 2, maximize: true }
    if (zone) zone.mon = mon.name
    return zone
  }

  // ----------------------------------------------- Windows 11 style layouts

  // Zones are [x, y, w, h] fractions of the monitor work area.
  readonly property var layouts: [
    [[0, 0, .5, 1], [.5, 0, .5, 1]],
    [[0, 0, .66, 1], [.66, 0, .34, 1]],
    [[0, 0, .5, 1], [.5, 0, .5, .5], [.5, .5, .5, .5]],
    [[0, 0, .34, 1], [.34, 0, .66, 1]],
    [[0, 0, 1, .5], [0, .5, 1, .5]],
    [[0, 0, .333, 1], [.333, 0, .334, 1], [.667, 0, .333, 1]],
    [[0, 0, .5, .5], [0, .5, .5, .5], [.5, 0, .5, 1]],
    [[0, 0, .5, .5], [.5, 0, .5, .5], [0, .5, .5, .5], [.5, .5, .5, .5]],
    [[0, 0, .25, 1], [.25, 0, .5, 1], [.75, 0, .25, 1]]
  ]
  readonly property int flyCell: 112
  readonly property int flyCellH: 70
  readonly property int flyGap: 10
  readonly property int flyPad: 14
  readonly property int flyW: flyPad * 2 + flyCell * 3 + flyGap * 2
  readonly property int flyH: flyPad * 2 + flyCellH * 3 + flyGap * 2

  property string flyoutMon: ""
  property int hoverCell: -1
  property int hoverZone: -1
  property bool dragMoved: false
  // Live position of the dragged titlebar (global coords) for the follower ghost.
  property real ghostX: 0
  property real ghostY: 0
  property real ghostW: 0
  property string ghostMon: ""
  property var ghostInfo: null

  function flyoutRect(mon) {
    var a = root.workArea(mon)
    return { x: a.x + (a.w - root.flyW) / 2, y: a.y + 8, w: root.flyW, h: root.flyH }
  }

  function zoneRect(mon, f) {
    var a = root.workArea(mon)
    var g = root.snapGap
    var x0 = a.x + g, y0 = a.y + g, W = a.w - 2 * g, H = a.h - 2 * g
    var h = g / 2
    var x = x0 + f[0] * W + (f[0] > 0 ? h : 0)
    var y = y0 + f[1] * H + (f[1] > 0 ? h : 0)
    var w = f[2] * W - (f[0] > 0 ? h : 0) - (f[0] + f[2] < 0.999 ? h : 0)
    var hh = f[3] * H - (f[1] > 0 ? h : 0) - (f[1] + f[3] < 0.999 ? h : 0)
    return { x: x, y: y, w: w, h: hh, mon: mon.name }
  }

  // Zone under the pointer: the layout flyout first, then screen edges.
  function zoneAt(gx, gy) {
    root.hoverCell = -1
    root.hoverZone = -1
    if (!root.dragMoved) return null
    var mon = root.monitorAt(gx, gy)
    if (!mon) return null
    if (root.cfg.snapLayouts) {
      var fr = root.flyoutRect(mon)
      var lx = gx - fr.x - root.flyPad, ly = gy - fr.y - root.flyPad
      if (gx >= fr.x && gx < fr.x + fr.w && gy >= fr.y && gy < fr.y + fr.h) {
        var col = Math.floor(lx / (root.flyCell + root.flyGap))
        var row = Math.floor(ly / (root.flyCellH + root.flyGap))
        if (col >= 0 && col < 3 && row >= 0 && row < 3) {
          var cx = lx - col * (root.flyCell + root.flyGap)
          var cy = ly - row * (root.flyCellH + root.flyGap)
          if (cx >= 0 && cx < root.flyCell && cy >= 0 && cy < root.flyCellH) {
            var index = row * 3 + col
            var zones = root.layouts[index]
            for (var z = 0; z < zones.length; z++) {
              var f = zones[z]
              if (cx >= f[0] * root.flyCell && cx < (f[0] + f[2]) * root.flyCell
                  && cy >= f[1] * root.flyCellH && cy < (f[1] + f[3]) * root.flyCellH) {
                root.hoverCell = index
                root.hoverZone = z
                return root.zoneRect(mon, f)
              }
            }
          }
        }
        return null
      }
    }
    return root.snapFor(gx, gy)
  }

  Timer {
    id: maximizeSetTimer
    property string address: ""
    interval: 140
    onTriggered: root.dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"set\", layout_aware = false, " + root.target(address) + " })")
  }

  function applySnap(info, zone, gx, gy) {
    var offset = info.bar ? root.barH : 0
    if (zone.maximize) {
      if (root.clientMonitorName(info.address) !== zone.mon) root.moveToMonitor(info.address, zone.mon)
      root.moveTo(info.address, gx - 120, gy - 12 + offset)
      maximizeSetTimer.address = info.address
      maximizeSetTimer.restart()
    } else {
      // The zone covers bar + window, so the client area starts below the bar.
      root.resizeTo(info.address, zone.w, zone.h - offset)
      root.moveTo(info.address, zone.x, zone.y + offset)
    }
    Qt.callLater(root.poll)
  }

  // ------------------------------------------------------- drag gestures

  property real pendingX: 0
  property real pendingY: 0
  property bool pendingDirty: false
  property var dragCtx: null

  Timer {
    interval: 16
    repeat: true
    running: root.dragAddress !== ""
    onTriggered: {
      if (!root.pendingDirty || root.dragAddress === "" || !root.dragReady) return
      root.pendingDirty = false
      root.moveTo(root.dragAddress, root.pendingX, root.pendingY)
    }
  }

  // A maximized window must be un-maximized before it can move. Like Windows it
  // comes back at a "normal" size, positioned so the pointer keeps its place
  // along the titlebar; the gesture waits for the compositor to catch up.
  property bool dragReady: true

  Timer {
    id: restoreTimer
    interval: 110
    onTriggered: {
      var d = root.dragCtx
      if (!d) return
      var info = d.info
      var mon = root.monitorByName(info.mon)
      if (!mon) { root.dragReady = true; return }
      var a = root.workArea(mon)
      var offset = info.bar ? root.barH : 0
      var w = Math.max(640, Math.round(a.w * 0.6))
      var h = Math.max(420, Math.round(a.h * 0.7))
      var ratio = info.winW > 0 ? d.mx / info.winW : 0.5
      var x = d.gx0 - ratio * w
      var y = d.gy0 - (info.bar ? d.my : 12) + offset
      x = Math.max(a.x, Math.min(a.x + a.w - w, x))
      y = Math.max(a.y + offset, y)
      if (!info.floating) root.floatOn(info.address)
      root.resizeTo(info.address, w, h)
      root.moveTo(info.address, x, y)
      d.wx = x
      d.wy = y
      root.ghostW = w
      root.pendingDirty = false
      root.dragReady = true
    }
  }

  // fx/fy: frozen surface position (monitor-local); mx/my: pointer in surface.
  function dragPress(info, fx, fy, mx, my) {
    root.dragCtx = { info: info, fx: fx, fy: fy, mx: mx, my: my, wx: info.winX, wy: info.winY,
                     curMon: root.clientMonitorName(info.address),
                     gx0: info.monX + fx + mx, gy0: info.monY + fy + my }
    root.dragAddress = info.address
    root.pendingDirty = false
    root.dragMoved = false
    root.ghostInfo = info
    root.ghostW = info.winW
    root.ghostX = info.winX
    root.ghostY = info.winY - (info.bar ? root.barH : 0)
    root.ghostMon = info.mon
    root.focusWindow(info.address)
    // Nothing moves until the pointer travels a few pixels, so a plain click
    // or double-click on a maximized titlebar leaves the window alone.
    root.dragReady = false
  }

  function beginMove(d) {
    var info = d.info
    if (info.maxed) {
      root.unmaximize(info.address)
      restoreTimer.restart()
    } else {
      if (!info.floating) root.floatOn(info.address)
      root.dragReady = true
    }
  }

  function dragMove(mx, my) {
    var d = root.dragCtx
    if (!d) return
    root.pendingX = d.wx + (mx - d.mx)
    root.pendingY = d.wy + (my - d.my)
    root.pendingDirty = true
    root.ghostX = root.pendingX
    root.ghostY = root.pendingY - (d.info.bar ? root.barH : 0)
    if (!root.dragMoved && Math.abs(mx - d.mx) + Math.abs(my - d.my) > 6) {
      root.dragMoved = true
      root.beginMove(d)
    }
    var gx = d.info.monX + d.fx + mx, gy = d.info.monY + d.fy + my
    var mon = root.monitorAt(gx, gy)
    // Follow the pointer across monitors so the window belongs to the screen
    // it ends up on (workspace, maximize, tiling all depend on that).
    if (root.dragReady && mon && d.curMon !== "" && mon.name !== d.curMon) {
      d.curMon = mon.name
      root.moveToMonitor(d.info.address, mon.name)
    }
    if (mon) root.ghostMon = mon.name
    root.flyoutMon = root.dragMoved && root.cfg.snapLayouts && mon ? mon.name : ""
    root.snapZone = root.zoneAt(gx, gy)
  }

  function dragRelease(mx, my) {
    var d = root.dragCtx
    if (!d) return
    var gx = d.info.monX + d.fx + mx
    var gy = d.info.monY + d.fy + my
    var zone = root.zoneAt(gx, gy)
    if (!zone && root.dragMoved && root.dragReady) root.moveTo(d.info.address, root.pendingX, root.pendingY)
    root.snapZone = null
    root.flyoutMon = ""
    root.hoverCell = -1
    root.hoverZone = -1
    root.dragAddress = ""
    root.dragCtx = null
    root.ghostInfo = null
    if (zone) root.applySnap(d.info, zone, gx, gy)
    Qt.callLater(root.poll)
  }

  // ------------------------------------------------------------- titlebars

  Instantiator {
    model: ScriptModel { values: root.bars; objectProp: "key" }

    delegate: PanelWindow {
      id: bar
      required property var modelData
      readonly property bool dragging: root.dragAddress === modelData.address
      readonly property color fg: root.cFg
      property real frozenX: 0
      property real frozenY: 0
      property bool frozen: false

      screen: root.screenByName(modelData.mon)
      visible: modelData.show || dragging
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.namespace: "caption-buttons-titlebar"
      anchors { top: true; left: true }
      margins {
        left: Math.max(0, Math.round(bar.frozen ? bar.frozenX : bar.modelData.px))
        top: Math.max(0, Math.round(bar.frozen ? bar.frozenY : bar.modelData.py))
      }
      implicitWidth: Math.max(1, Math.round(bar.modelData.segW))
      implicitHeight: root.barH

      TopRounded {
        anchors.fill: parent
        opacity: bar.dragging && root.dragMoved ? 0 : 1
        fill: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, root.barAlpha)

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: Qt.rgba(bar.fg.r, bar.fg.g, bar.fg.b, bar.modelData.focused ? 0.28 : 0.12)
        }

        MouseArea {
          id: dragArea
          anchors.fill: parent
          preventStealing: true
          cursorShape: Qt.ArrowCursor
          onPressed: function(mouse) {
            bar.frozenX = bar.modelData.px
            bar.frozenY = bar.modelData.py
            bar.frozen = true
            root.dragPress(bar.modelData, bar.frozenX, bar.frozenY, mouse.x, mouse.y)
          }
          onPositionChanged: function(mouse) { if (dragArea.pressed) root.dragMove(mouse.x, mouse.y) }
          onReleased: function(mouse) {
            root.dragRelease(mouse.x, mouse.y)
            bar.frozen = false
          }
          onDoubleClicked: root.toggleMaximize(bar.modelData)
        }

        Text {
          visible: root.cfg.showTitle && bar.modelData.hasLeft
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 8 + (bar.modelData.hasRight ? buttons.width : 0)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: bar.modelData.title
          textFormat: Text.PlainText
          color: bar.fg
          opacity: bar.modelData.focused ? 0.95 : 0.55
          font.pixelSize: Math.round(12 * root.uiScale)
        }

        Row {
          id: buttons
          visible: bar.modelData.hasRight
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          CaptionButton { visible: root.cfg.minimize; glyph: "—"; onActivated: root.minimize(bar.modelData) }
          CaptionButton { visible: root.cfg.maximize; glyph: bar.modelData.maxed ? "❐" : "▢"; onActivated: root.toggleMaximize(bar.modelData) }
          CaptionButton { visible: root.cfg.close; glyph: "✕"; danger: true; onActivated: root.closeWindow(bar.modelData) }
        }
      }
    }
  }

  // ---------------------------------------------------- titlebar follower

  // The real titlebar surface is frozen while it holds the pointer grab, so a
  // visual-only copy follows the window live.
  Instantiator {
    model: ScriptModel { values: root.ghostInfo && root.ghostInfo.bar && root.dragMoved ? [root.ghostInfo] : []; objectProp: "address" }

    delegate: PanelWindow {
      id: ghost
      required property var modelData
      readonly property var mon: root.monitorByName(root.ghostMon)
      readonly property real left: mon ? root.ghostX - mon.x : 0
      readonly property real clipLeft: Math.max(0, -left)

      screen: root.screenByName(root.ghostMon)
      visible: mon !== null
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.namespace: "caption-buttons-titlebar-follow"
      anchors { top: true; left: true }
      margins {
        left: Math.max(0, Math.round(ghost.left))
        top: ghost.mon ? Math.max(0, Math.round(root.ghostY - ghost.mon.y)) : 0
      }
      implicitWidth: Math.max(1, Math.round(root.ghostW - ghost.clipLeft))
      implicitHeight: root.barH
      mask: Region {}

      TopRounded {
        anchors.fill: parent
        fill: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, root.barAlpha)

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.28)
        }

        Text {
          visible: root.cfg.showTitle && ghost.clipLeft === 0
          anchors.left: parent.left
          anchors.leftMargin: 10
          anchors.right: parent.right
          anchors.rightMargin: 8 + ghostButtons.width
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: ghost.modelData.title
          textFormat: Text.PlainText
          color: root.cFg
          opacity: 0.95
          font.pixelSize: Math.round(12 * root.uiScale)
        }

        Row {
          id: ghostButtons
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          Repeater {
            model: [root.cfg.minimize ? "—" : "", root.cfg.maximize ? "▢" : "", root.cfg.close ? "✕" : ""]
            delegate: Item {
              required property string modelData
              visible: modelData !== ""
              width: visible ? root.buttonSize : 0
              height: parent.height
              Text { anchors.centerIn: parent; text: parent.modelData; color: root.cFg; font.pixelSize: Math.round(13 * root.uiScale) }
            }
          }
        }
      }
    }
  }

  // ----------------------------------------------------------- overlay pill

  Instantiator {
    model: ScriptModel { values: root.pills; objectProp: "address" }

    delegate: PanelWindow {
      id: pill
      required property var modelData
      readonly property bool dragging: root.dragAddress === modelData.address
      property real frozenX: 0
      property real frozenY: 0
      property bool frozen: false

      screen: root.screenByName(modelData.mon)
      visible: modelData.show || dragging
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "caption-buttons"
      anchors { top: true; left: true }
      margins {
        left: Math.max(0, Math.round(pill.frozen ? pill.frozenX : pill.modelData.px))
        top: Math.max(0, Math.round(pill.frozen ? pill.frozenY : pill.modelData.py))
      }
      implicitWidth: root.pillW
      implicitHeight: root.pillH

      Rectangle {
        anchors.fill: parent
        radius: 8
        color: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, root.barAlpha)
        border.width: 1
        border.color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.18)

        Row {
          anchors.fill: parent
          anchors.margins: 2

          Item {
            width: root.buttonSize
            height: parent.height

            Text {
              anchors.centerIn: parent
              text: "⠿"
              color: root.cFg
              opacity: grip.pressed || grip.containsMouse ? 1 : 0.6
              font.pixelSize: Math.round(15 * root.uiScale)
            }

            MouseArea {
              id: grip
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true
              cursorShape: Qt.SizeAllCursor
              onPressed: function(mouse) {
                pill.frozenX = pill.modelData.px
                pill.frozenY = pill.modelData.py
                pill.frozen = true
                root.dragPress(pill.modelData, pill.frozenX, pill.frozenY, mouse.x, mouse.y)
              }
              onPositionChanged: function(mouse) { if (grip.pressed) root.dragMove(mouse.x, mouse.y) }
              onReleased: function(mouse) {
                root.dragRelease(mouse.x, mouse.y)
                pill.frozen = false
              }
            }
          }

          CaptionButton { visible: root.cfg.minimize; glyph: "—"; onActivated: root.minimize(pill.modelData) }
          CaptionButton { visible: root.cfg.maximize; glyph: pill.modelData.maxed ? "❐" : "▢"; onActivated: root.toggleMaximize(pill.modelData) }
          CaptionButton { visible: root.cfg.close; glyph: "✕"; danger: true; onActivated: root.closeWindow(pill.modelData) }
        }
      }
    }
  }

  // Rectangle with only its top corners rounded.
  component TopRounded: Item {
    id: shape
    property color fill: "black"
    default property alias content: holder.data
    readonly property real r: Math.min(root.cfg.cornerRadius, height)

    Rectangle {
      anchors.fill: parent
      radius: shape.r
      color: shape.fill
    }
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: parent.height - shape.r
      color: shape.fill
    }
    Item { id: holder; anchors.fill: parent }
  }

  component CaptionButton: Item {
    id: button
    property string glyph: ""
    property bool danger: false
    signal activated()

    width: visible ? root.buttonSize : 0
    height: parent ? parent.height : 22

    Rectangle {
      anchors.fill: parent
      anchors.margins: 1
      radius: 6
      color: button.danger ? root.cUrgent : root.cFg
      opacity: area.pressed ? 0.35 : (area.containsMouse ? 0.2 : 0)
    }

    Text {
      anchors.centerIn: parent
      text: button.glyph
      color: area.containsMouse && button.danger ? root.cUrgent : root.cFg
      font.pixelSize: Math.round(13 * root.uiScale)
    }

    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.activated()
    }
  }

  // --------------------------------------------------------- resize grips

  Instantiator {
    model: ScriptModel { values: root.handles; objectProp: "address" }

    delegate: PanelWindow {
      id: handle
      required property var modelData
      property bool frozen: false
      property real frozenX: 0
      property real frozenY: 0
      property real lastX: 0
      property real lastY: 0
      property bool active: false

      screen: root.screenByName(modelData.mon)
      visible: modelData.show || active
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "caption-buttons-resize"
      anchors { top: true; left: true }
      margins {
        left: Math.max(0, Math.round(handle.frozen ? handle.frozenX : handle.modelData.px))
        top: Math.max(0, Math.round(handle.frozen ? handle.frozenY : handle.modelData.py))
      }
      implicitWidth: 16
      implicitHeight: 16

      Text {
        anchors.centerIn: parent
        text: "◢"
        font.pixelSize: 12
        color: root.cFg
        opacity: resizeArea.pressed || resizeArea.containsMouse ? 0.95 : 0.35
      }

      MouseArea {
        id: resizeArea
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.SizeFDiagCursor

        onPressed: function(mouse) {
          handle.frozenX = handle.modelData.px
          handle.frozenY = handle.modelData.py
          handle.frozen = true
          handle.active = true
          handle.lastX = mouse.x
          handle.lastY = mouse.y
        }
        onPositionChanged: function(mouse) {
          if (!resizeArea.pressed) return
          var dx = mouse.x - handle.lastX
          var dy = mouse.y - handle.lastY
          if (dx === 0 && dy === 0) return
          handle.lastX = mouse.x
          handle.lastY = mouse.y
          root.resizeBy(handle.modelData.address, dx, dy)
        }
        onReleased: {
          handle.frozen = false
          handle.active = false
          Qt.callLater(root.poll)
        }
      }
    }
  }

  // ----------------------------------------------------- layout flyout

  Instantiator {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: fly
      required property var modelData
      readonly property var mon: root.monitorByName(modelData.name)
      readonly property var rect: mon ? root.flyoutRect(mon) : null

      screen: modelData
      visible: root.flyoutMon === modelData.name && rect !== null
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "caption-buttons-layouts"
      anchors { top: true; left: true }
      margins {
        left: fly.rect ? Math.max(0, Math.round(fly.rect.x - fly.modelData.x)) : 0
        top: fly.rect ? Math.max(0, Math.round(fly.rect.y - fly.modelData.y)) : 0
      }
      implicitWidth: root.flyW
      implicitHeight: root.flyH
      mask: Region {}

      Rectangle {
        anchors.fill: parent
        radius: 14
        color: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, 0.94)
        border.width: 1
        border.color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.25)

        Repeater {
          model: root.layouts

          delegate: Item {
            id: cell
            required property var modelData
            required property int index
            x: root.flyPad + (index % 3) * (root.flyCell + root.flyGap)
            y: root.flyPad + Math.floor(index / 3) * (root.flyCellH + root.flyGap)
            width: root.flyCell
            height: root.flyCellH

            Repeater {
              model: cell.modelData

              delegate: Rectangle {
                id: zoneBox
                required property var modelData
                required property int index
                readonly property bool hot: root.hoverCell === cell.index && root.hoverZone === zoneBox.index
                x: modelData[0] * cell.width + 1.5
                y: modelData[1] * cell.height + 1.5
                width: modelData[2] * cell.width - 3
                height: modelData[3] * cell.height - 3
                radius: 5
                color: hot ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.55)
                           : Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.14)
                border.width: 1
                border.color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, hot ? 0.9 : 0.3)
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------- snap preview

  Instantiator {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: preview
      required property var modelData
      readonly property var zone: root.snapZone && root.snapZone.mon === modelData.name ? root.snapZone : null

      screen: modelData
      visible: zone !== null
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "caption-buttons-snap"
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region {}

      Rectangle {
        x: preview.zone ? preview.zone.x - preview.modelData.x : 0
        y: preview.zone ? preview.zone.y - preview.modelData.y : 0
        width: preview.zone ? preview.zone.w : 0
        height: preview.zone ? preview.zone.h : 0
        radius: 10
        color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.18)
        border.width: 2
        border.color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.7)
      }
    }
  }
}
