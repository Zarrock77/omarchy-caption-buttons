import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Settings popup. Values live in ~/.config/omarchy/caption-buttons.json; the
// service watches that file, so every change applies instantly.
Panel {
  id: root
  moduleName: "io.github.zarrock77.caption-buttons"
  ipcTarget: "io.github.zarrock77.caption-buttons"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool menuOpen: false
  property bool editing: false

  readonly property var barIdentity: hostWidget || root
  readonly property color fg: root.bar ? root.bar.foreground : "#cacccc"
  readonly property string font: root.bar ? root.bar.fontFamily : "sans-serif"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/caption-buttons.json"
  readonly property var defaults: ({
    enabled: true, titlebar: true, showTitle: true, minimize: true, maximize: true, close: true, resizeHandle: true,
    corner: "top-right", scale: 100, opacity: 88, snap: true, snapLayouts: true, snapEdge: 20, snapGap: 8
  })
  property var values: root.defaults

  function load(text) {
    var next = Object.assign({}, root.defaults)
    try {
      var parsed = JSON.parse(text)
      for (var key in root.defaults)
        if (parsed[key] !== undefined && typeof parsed[key] === typeof root.defaults[key]) next[key] = parsed[key]
    } catch (error) {}
    root.values = next
  }

  function set(key, value) {
    var next = Object.assign({}, root.values)
    next[key] = value
    root.values = next
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: if (!root.editing) root.load(text())
    onFileChanged: configFile.reload()
    onLoadFailed: root.load("{}")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.menuOpen || root.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        Toggle {
          width: parent.width
          label: "Enable caption buttons"
          description: "Show the control pill on every window"
          checked: root.values.enabled
          foreground: root.fg
          fontFamily: root.font
          onClicked: root.set("enabled", !root.values.enabled)
        }

        Toggle {
          width: parent.width
          label: "Titlebar above windows"
          description: "Reserve a bar above each window (uses single-window groups). Off = small floating pill"
          checked: root.values.titlebar
          foreground: root.fg
          fontFamily: root.font
          onClicked: root.set("titlebar", !root.values.titlebar)
        }
        Toggle {
          width: parent.width
          label: "Show window title"
          checked: root.values.showTitle
          foreground: root.fg
          fontFamily: root.font
          onClicked: root.set("showTitle", !root.values.showTitle)
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
        PanelSectionHeader { text: "Buttons"; foreground: root.fg; fontFamily: root.font }

        Toggle {
          width: parent.width; label: "Minimize"; checked: root.values.minimize
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("minimize", !root.values.minimize)
        }
        Toggle {
          width: parent.width; label: "Maximize"; checked: root.values.maximize
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("maximize", !root.values.maximize)
        }
        Toggle {
          width: parent.width; label: "Close"; checked: root.values.close
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("close", !root.values.close)
        }
        Toggle {
          width: parent.width; label: "Resize grip"; description: "Bottom-right corner handle"
          checked: root.values.resizeHandle
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("resizeHandle", !root.values.resizeHandle)
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
        PanelSectionHeader { text: "Appearance"; foreground: root.fg; fontFamily: root.font }

        Text { text: "Pill position (overlay mode)"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
        Dropdown {
          width: parent.width
          showLabel: false
          value: root.values.corner
          options: [{ value: "top-right", label: "Top right" }, { value: "top-left", label: "Top left" }]
          foreground: root.fg
          fontFamily: root.font
          onPopupOpenChanged: root.menuOpen = popupOpen
          onChanged: function(value) { root.set("corner", value) }
        }

        Text { text: "Size: " + root.values.scale + "%"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
        PanelSlider {
          width: parent.width; bar: root.bar
          minimum: 70; maximum: 160; step: 5; integer: true
          value: root.values.scale
          onMoved: root.editing = true
          onReleased: function(value) { root.editing = false; root.set("scale", Math.round(value)) }
        }

        Text { text: "Opacity: " + root.values.opacity + "%"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
        PanelSlider {
          width: parent.width; bar: root.bar
          minimum: 30; maximum: 100; step: 2; integer: true
          value: root.values.opacity
          onMoved: root.editing = true
          onReleased: function(value) { root.editing = false; root.set("opacity", Math.round(value)) }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
        PanelSectionHeader { text: "Snap"; foreground: root.fg; fontFamily: root.font }

        Toggle {
          width: parent.width; label: "Snap to screen edges"
          description: "Drop a window on an edge or corner while dragging by the grip"
          checked: root.values.snap
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("snap", !root.values.snap)
        }

        Toggle {
          width: parent.width; label: "Snap layouts menu"
          description: "While dragging a window, a layout picker appears at the top of the screen"
          checked: root.values.snapLayouts
          foreground: root.fg; fontFamily: root.font
          onClicked: root.set("snapLayouts", !root.values.snapLayouts)
        }

        Text { text: "Edge sensitivity: " + root.values.snapEdge + " px"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
        PanelSlider {
          width: parent.width; bar: root.bar
          minimum: 8; maximum: 80; step: 2; integer: true
          value: root.values.snapEdge
          onMoved: root.editing = true
          onReleased: function(value) { root.editing = false; root.set("snapEdge", Math.round(value)) }
        }

        Text { text: "Gap: " + root.values.snapGap + " px"; color: root.fg; font.family: root.font; font.pixelSize: Style.font.body; textFormat: Text.PlainText }
        PanelSlider {
          width: parent.width; bar: root.bar
          minimum: 0; maximum: 30; step: 1; integer: true
          value: root.values.snapGap
          onMoved: root.editing = true
          onReleased: function(value) { root.editing = false; root.set("snapGap", Math.round(value)) }
        }
      }
    }
  }
}
