import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Small LED in the bar. Lights up while the omablinker eBPF service reports
// block-layer I/O, and turns fully transparent otherwise — like an actual
// unlit LED, showing whatever's behind the bar rather than a dark plastic
// square. Either an instant snap (the "Abrupt" default, matching how a real
// drive-activity LED flashes) or a brief fade (the "Fade" option). Click it
// to open OmaBlinker's settings popup and change its shape, color, and
// blink style.
BarWidget {
  id: root
  moduleName: "jayosays.omablinker"

  readonly property var hddService: bar?.shell?.serviceFor(moduleName)
  readonly property bool active: hddService ? hddService.active : false
  readonly property string statusText: hddService ? hddService.statusText : qsTr("Starting HDD activity light…")

  // Appearance prefs, kept in a small file of our own rather than through
  // the plugin settings schema in manifest.json: nothing in Omarchy's shell
  // currently renders a settings form from that schema (it's read and
  // stored, but nothing turns it into UI yet), so a schema-only setting has
  // no way to be changed. This popup is the actual, working control surface
  // for them, and needs its own storage to match.
  readonly property string prefsPath: (Quickshell.env("HOME") || "") + "/.config/omablinker/widget-prefs.json"
  property string ledShape: "Square"
  property string colorScheme: "Red"
  property string blinkStyle: "Abrupt"
  property bool popupOpen: false

  // PopupCard's outside-click dismissal calls `owner.close()` when present,
  // falling back to setting its own `open` property directly otherwise —
  // which would silently break the one-way `open: root.popupOpen` binding
  // below (PopupCard.open becomes a disconnected static value, and toggling
  // our own popupOpen stops having any effect, and the popup can never
  // reopen). Providing close()/open()/toggle() here keeps PopupCard always
  // going through our own state instead.
  function open() { root.popupOpen = true }
  function close() { root.popupOpen = false }
  function toggle() { root.popupOpen = !root.popupOpen }

  function applyPrefsJson(text) {
    try {
      var data = JSON.parse(text)
      if (data.ledShape === "Square" || data.ledShape === "Circle") root.ledShape = data.ledShape
      if (data.colorScheme === "Red" || data.colorScheme === "Amber") root.colorScheme = data.colorScheme
      if (data.blinkStyle === "Abrupt" || data.blinkStyle === "Fade") root.blinkStyle = data.blinkStyle
    } catch (e) {
      // No prefs file yet, or it's malformed — the defaults above stand.
    }
  }

  function writePrefs() {
    var json = JSON.stringify({
      ledShape: root.ledShape,
      colorScheme: root.colorScheme,
      blinkStyle: root.blinkStyle
    })
    var script = "mkdir -p \"$(dirname '" + root.prefsPath + "')\" && printf '%s' '" + json + "' > '" + root.prefsPath + "'"
    Quickshell.execDetached(["bash", "-c", script])
  }

  Process {
    running: true
    command: ["bash", "-c", "cat '" + root.prefsPath + "' 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPrefsJson(text)
    }
  }

  // Square: the boxy drive-activity LEDs common on PC front panels.
  // Circle: a classic round 5mm LED.
  readonly property bool circle: ledShape === "Circle"

  // Red: the classic 5mm LED on most beige-box drive lights. Amber: the
  // orange tone common on 386/486-era cases (often shared with the turbo
  // button light).
  readonly property var colorPresets: ({
    "Red": "#ff2400",
    "Amber": "#ffb000"
  })
  readonly property color onColor: colorPresets[colorScheme] || colorPresets["Red"]

  // Abrupt: no animation, the LED snaps on/off like a real one.
  // Fade: a quick ramp up and a slower, lingering fall off.
  readonly property bool abrupt: blinkStyle !== "Fade"
  readonly property int rampUpMs: abrupt ? 0 : 15
  readonly property int rampDownMs: abrupt ? 0 : 200
  readonly property int haloMs: abrupt ? 0 : 150

  function syncServiceSettings() {
    if (hddService && typeof hddService.configure === "function") hddService.configure(settings)
  }

  onSettingsChanged: syncServiceSettings()
  onHddServiceChanged: syncServiceSettings()

  implicitWidth: led.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Item {
    id: led
    anchors.centerIn: parent
    implicitWidth: Style.space(10)
    implicitHeight: Style.space(10)
    width: implicitWidth
    height: implicitHeight

    // A thin rim, not a diffuse glow: light catching the edges of the
    // panel cutout the LED sits behind, the way a slightly-too-big hole
    // lets a sliver of light spill around a real indicator LED. A sibling
    // of the inner square below rather than its child, so the two fade
    // independently instead of one's opacity compounding into the other's.
    Rectangle {
      anchors.centerIn: parent
      width: parent.width + Style.space(2)
      height: parent.height + Style.space(2)
      radius: root.circle ? width / 2 : 0
      color: root.onColor
      opacity: root.active ? 0.35 : 0
      Behavior on opacity { NumberAnimation { duration: root.haloMs } }
    }

    // The LED itself. Fades opacity rather than color, and goes fully
    // transparent when idle: whatever's behind the bar (wallpaper, blur)
    // shows through, like an actual unlit LED rather than a dark plastic
    // square. Animating color itself between onColor and "transparent"
    // would cross-fade through transparent *black* along the way, since
    // both RGB and alpha interpolate together — opacity keeps the hue
    // constant and only fades the alpha.
    Rectangle {
      anchors.fill: parent
      radius: root.circle ? width / 2 : 0
      color: root.onColor
      opacity: root.active ? 1 : 0

      Behavior on opacity {
        NumberAnimation { duration: root.active ? root.rampUpMs : root.rampDownMs }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onEntered: if (root.bar) root.bar.showTooltip(root, root.statusText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(280))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(14)

      PanelHero {
        title: qsTr("OmaBlinker")
        meta: qsTr("Working hard for you")
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

        // md-harddisk (U+F02CA) — same Material Design Icons set as the
        // rest of the shell's glyph icons. Tinted with the current LED
        // color so the icon reflects what's actually selected below.
        iconComponent: Component {
          Item {
            implicitWidth: Style.space(34)
            implicitHeight: Style.space(34)

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "󰋊"
              color: root.onColor
              font.pixelSize: parent.width * 0.75
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      OptionGroup {
        title: qsTr("LED shape")
        options: ["Square", "Circle"]
        current: root.ledShape
        onPicked: function(value) { root.ledShape = value; root.writePrefs() }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      OptionGroup {
        title: qsTr("LED color")
        options: ["Red", "Amber"]
        current: root.colorScheme
        onPicked: function(value) { root.colorScheme = value; root.writePrefs() }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      OptionGroup {
        title: qsTr("Blink style")
        options: ["Abrupt", "Fade"]
        current: root.blinkStyle
        onPicked: function(value) { root.blinkStyle = value; root.writePrefs() }
      }
    }
  }

  component OptionGroup: Column {
    id: group

    property string title: ""
    property var options: []
    property string current: ""
    signal picked(string value)

    width: parent.width
    spacing: Style.space(6)

    Text {
      // Uppercased here rather than at each call site, matching how
      // PanelHero's own caption (`meta`) always uppercases itself.
      text: group.title.toUpperCase()
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      font.letterSpacing: 1.2
    }

    Row {
      spacing: Style.space(6)

      Repeater {
        model: group.options

        Button {
          required property string modelData
          text: modelData
          bordered: true
          selected: modelData === group.current
          foreground: root.bar ? root.bar.foreground : Color.foreground
          onClicked: group.picked(modelData)
        }
      }
    }
  }
}
