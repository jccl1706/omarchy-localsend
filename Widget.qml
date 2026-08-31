import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// LocalSend bar widget: an icon button plus a popup card built from the same
// components (BarWidget, BarIconButton, PopupCard, PanelHero) first-party
// widgets use, so it matches the rest of the bar instead of looking bolted on.
BarWidget {
  id: root
  moduleName: "io.github.jccl1706.localsend"

  readonly property string appId: "org.omarchy.localsend"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/localsend-cli/config.toml"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string deviceAlias: parseToml(configFile.text(), "alias", hostnameFile.text().trim() || "This device")
  readonly property string port: parseToml(configFile.text(), "port", "53317")
  readonly property string destination: parseToml(configFile.text(), "destination", "~/Downloads")

  readonly property bool opened: popup.open

  function parseToml(text, key, fallback) {
    if (!text) return fallback
    var re = new RegExp("^\\s*" + key + "\\s*=\\s*\"?([^\"\\n]*?)\"?\\s*$", "m")
    var match = re.exec(text)
    return match && match[1].length > 0 ? match[1] : fallback
  }

  function urlToPath(url) {
    var s = url.toString()
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return decodeURIComponent(s)
  }

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { popup.open = !popup.open }

  function openLocalSend(filePaths) {
    if (!bar) return
    var cmd = "omarchy-launch-or-focus-tui --app-id=" + appId + " localsend-cli"
    for (var i = 0; i < filePaths.length; i++) {
      cmd += " -f " + Util.shellQuote(filePaths[i])
    }
    bar.run(cmd)
    root.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    printErrors: false
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "LocalSend — click to open, drop a file to send it"
    iconComponent: Component {
      Item {
        Image {
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          source: "assets/localsend.png"
          smooth: true
        }
      }
    }
    onPressed: root.toggle()
  }

  DropArea {
    anchors.fill: parent
    onDropped: function(drop) {
      var paths = []
      for (var i = 0; i < drop.urls.length; i++) paths.push(root.urlToPath(drop.urls[i]))
      if (paths.length > 0) root.openLocalSend(paths)
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(14)

      PanelHero {
        title: "LocalSend"
        meta: root.deviceAlias
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Image {
            width: Style.font.display
            height: Style.font.display
            fillMode: Image.PreserveAspectFit
            source: "assets/localsend.png"
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      Column {
        width: parent.width
        spacing: Style.spacing.labelGap

        InfoPair { label: "Port"; value: root.port }
        InfoPair { label: "Saves to"; value: root.destination }
      }

      PanelSeparator { foreground: root.foreground }

      Text {
        width: parent.width
        text: "Drop a file on the bar icon to send it directly, or open LocalSend to browse nearby devices."
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        width: parent.width
        text: "Open LocalSend"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.openLocalSend([])
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      text: label
      opacity: 0.6
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
