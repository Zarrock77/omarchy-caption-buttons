pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Caption Buttons: a small pill of window controls on every Hyprland window.
//
//   ⠿  grip      drag to move; drop on a screen edge/corner to snap
//   —  minimize  parks the window on a special workspace; click its dock icon to bring it back
//   ▢  maximize  toggles Hyprland's "maximized" mode
//   ✕  close
//   ◢  bottom-right grip resizes the window
//
// State comes from `hyprctl`, actions go back through Hyprland Lua dispatchers,
// so the plugin needs nothing from the bar and works with any of them.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string parkedWorkspace: "special:caption-minimized"
  readonly property int pillW: 112
  readonly property int pillH: 26
  readonly property int edgeInset: 6
  readonly property int snapEdge: 20
  readonly property int snapGap: 8
  readonly property int minWindowW: 260

  property var clients: []
  property var monitors: []
  property var pills: []
  property var handles: []
  property var homes: ({})

  // Active drag/resize gesture. The pill's layer surface stays frozen in place
  // while the gesture runs so pointer coordinates stay stable.
  property string dragAddress: ""
  property var snapZone: null

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
    var w = (rotated ? mon.height : mon.width) / scale
    var h = (rotated ? mon.width : mon.height) / scale
    return { w: w, h: h }
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
      if (!c.mapped || c.hidden) continue
      if (c.workspace.id < 0) continue
      var mon = root.monitorById(c.monitor)
      if (!mon || mon.activeWorkspace.id !== c.workspace.id || !root.screenByName(mon.name)) continue
      visible.push({ c: c, mon: mon })
    }

    var nextPills = []
    var nextHandles = []
    for (var v = 0; v < visible.length; v++) {
      var w = visible[v].c
      var m = visible[v].mon
      if (w.fullscreen === 2 || w.size[0] < root.minWindowW || w.size[1] < 120) continue

      var px = w.at[0] + w.size[0] - root.pillW - root.edgeInset
      var py = w.at[1] + root.edgeInset
      var hx = w.at[0] + w.size[0] - 18
      var hy = w.at[1] + w.size[1] - 18

      // Hide anything covered by a window that was focused more recently.
      var coveredPill = false
      var coveredHandle = false
      for (var k = 0; k < visible.length; k++) {
        var o = visible[k].c
        if (o === w || o.focusHistoryID >= w.focusHistoryID) continue
        if (root.overlaps(px, py, root.pillW, root.pillH, o.at[0], o.at[1], o.size[0], o.size[1])) coveredPill = true
        if (root.overlaps(hx, hy, 16, 16, o.at[0], o.at[1], o.size[0], o.size[1])) coveredHandle = true
      }

      var base = {
        address: w.address, mon: m.name, floating: w.floating, maxed: w.fullscreen === 1,
        winX: w.at[0], winY: w.at[1], winW: w.size[0], winH: w.size[1],
        wsId: w.workspace.id, monX: m.x, monY: m.y
      }
      nextPills.push(Object.assign({ px: px - m.x, py: py - m.y, show: !coveredPill }, base))
      nextHandles.push(Object.assign({ px: hx - m.x, py: hy - m.y, show: !coveredHandle && w.fullscreen !== 1 }, base))
    }
    root.pills = nextPills
    root.handles = nextHandles
  }

  // --------------------------------------------------------------- actions

  function dispatch(lua) { Hyprland.dispatch(lua) }
  function target(address) { return "window = \"address:" + address + "\"" }

  function floatOn(address) { dispatch("hl.dsp.window.float({ action = \"on\", " + target(address) + " })") }
  function unmaximize(address) { dispatch("hl.dsp.window.fullscreen({ action = \"unset\", layout_aware = false, " + target(address) + " })") }
  function moveTo(address, x, y) { dispatch("hl.dsp.window.move({ x = " + Math.round(x) + ", y = " + Math.round(y) + ", " + target(address) + " })") }
  function resizeTo(address, w, h) { dispatch("hl.dsp.window.resize({ x = " + Math.round(w) + ", y = " + Math.round(h) + ", exact = true, " + target(address) + " })") }
  function resizeBy(address, dx, dy) { dispatch("hl.dsp.window.resize({ x = " + Math.round(dx) + ", y = " + Math.round(dy) + ", relative = true, " + target(address) + " })") }

  function minimize(info) {
    var next = Object.assign({}, root.homes)
    next[info.address] = info.wsId
    root.homes = next
    dispatch("hl.dsp.window.move({ workspace = \"" + root.parkedWorkspace + "\", follow = false, " + target(info.address) + " })")
    Qt.callLater(root.poll)
  }

  function toggleMaximize(info) {
    dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"toggle\", layout_aware = false, " + target(info.address) + " })")
  }

  function closeWindow(info) {
    dispatch("hl.dsp.window.close({ " + target(info.address) + " })")
  }

  // ------------------------------------------------------------------ snap

  // Work area of a monitor in layout coordinates, minus bars/reserved edges.
  function workArea(mon) {
    var s = root.logicalSize(mon)
    var r = mon.reserved || [0, 0, 0, 0] // left, top, right, bottom
    return { x: mon.x + r[0], y: mon.y + r[1], w: s.w - r[0] - r[2], h: s.h - r[1] - r[3] }
  }

  function snapFor(gx, gy) {
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

  function applySnap(address, zone, gx, gy) {
    if (zone.maximize) {
      root.moveTo(address, gx - 120, gy - 12)
      Qt.callLater(function() { root.dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"set\", layout_aware = false, " + root.target(address) + " })") })
    } else {
      root.resizeTo(address, zone.w, zone.h)
      root.moveTo(address, zone.x, zone.y)
    }
    Qt.callLater(root.poll)
  }

  // ------------------------------------------------------------ move queue

  property real pendingX: 0
  property real pendingY: 0
  property bool pendingDirty: false

  Timer {
    id: moveTimer
    interval: 16
    repeat: true
    running: root.dragAddress !== ""
    onTriggered: {
      if (!root.pendingDirty || root.dragAddress === "") return
      root.pendingDirty = false
      root.moveTo(root.dragAddress, root.pendingX, root.pendingY)
    }
  }

  // ---------------------------------------------------------------- pills

  Instantiator {
    model: ScriptModel { values: root.pills; objectProp: "address" }

    delegate: PanelWindow {
      id: pill
      required property var modelData
      readonly property bool dragging: root.dragAddress === modelData.address
      property real frozenX: 0
      property real frozenY: 0
      property bool frozen: false
      property real pressX: 0
      property real pressY: 0
      property real winStartX: 0
      property real winStartY: 0

      readonly property var targetScreen: root.screenByName(modelData.mon)
      screen: targetScreen
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
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.88)
        border.width: 1
        border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)

        Row {
          anchors.fill: parent
          anchors.margins: 2

          // Drag grip (also the snap handle)
          Item {
            width: 26
            height: parent.height

            Text {
              anchors.centerIn: parent
              text: "⠿"
              color: Color.foreground
              opacity: grip.pressed || grip.containsMouse ? 1 : 0.6
              font.pixelSize: 15
            }

            MouseArea {
              id: grip
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true
              cursorShape: Qt.SizeAllCursor

              onPressed: function(mouse) {
                var info = pill.modelData
                pill.frozenX = info.px
                pill.frozenY = info.py
                pill.frozen = true
                pill.pressX = mouse.x
                pill.pressY = mouse.y
                pill.winStartX = info.winX
                pill.winStartY = info.winY
                root.dragAddress = info.address
                root.pendingDirty = false
                if (info.maxed) root.unmaximize(info.address)
                if (!info.floating) root.floatOn(info.address)
              }
              onPositionChanged: function(mouse) {
                if (!grip.pressed) return
                var info = pill.modelData
                root.pendingX = pill.winStartX + (mouse.x - pill.pressX)
                root.pendingY = pill.winStartY + (mouse.y - pill.pressY)
                root.pendingDirty = true
                root.snapZone = root.snapFor(info.monX + pill.frozenX + mouse.x, info.monY + pill.frozenY + mouse.y)
              }
              onReleased: function(mouse) {
                var info = pill.modelData
                var gx = info.monX + pill.frozenX + mouse.x
                var gy = info.monY + pill.frozenY + mouse.y
                var zone = root.snapFor(gx, gy)
                if (!zone) root.moveTo(info.address, root.pendingX, root.pendingY)
                root.snapZone = null
                root.dragAddress = ""
                pill.frozen = false
                if (zone) root.applySnap(info.address, zone, gx, gy)
                Qt.callLater(root.poll)
              }
            }
          }

          CaptionButton { glyph: "—"; onActivated: root.minimize(pill.modelData) }
          CaptionButton { glyph: pill.modelData.maxed ? "❐" : "▢"; onActivated: root.toggleMaximize(pill.modelData) }
          CaptionButton { glyph: "✕"; danger: true; onActivated: root.closeWindow(pill.modelData) }
        }
      }
    }
  }

  component CaptionButton: Item {
    id: button
    property string glyph: ""
    property bool danger: false
    signal activated()

    width: 26
    height: parent ? parent.height : 22

    Rectangle {
      anchors.fill: parent
      anchors.margins: 1
      radius: 6
      color: button.danger ? Color.urgent : Color.foreground
      opacity: area.pressed ? 0.35 : (area.containsMouse ? 0.2 : 0)
    }

    Text {
      anchors.centerIn: parent
      text: button.glyph
      color: area.containsMouse && button.danger ? Color.urgent : Color.foreground
      font.pixelSize: 13
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

      readonly property var targetScreen: root.screenByName(modelData.mon)
      screen: targetScreen
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
        color: Color.foreground
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
          if (!handle.modelData.floating) return
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
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        border.width: 2
        border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
      }
    }
  }
}
