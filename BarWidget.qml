import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// LED(s) in the bar. In "Combined" mode (default), a single LED lights up
// whenever the omablinker eBPF service reports any block-layer I/O. In
// "Read/Write" mode, two LEDs track reads and writes independently — green
// on the left for reads, red on the right for writes. Either way, idle
// LEDs turn fully transparent — like an actual unlit LED, showing whatever
// is behind the bar — and blink either as an instant snap (the "Abrupt"
// default, matching how a real drive-activity LED flashes) or a brief
// fade (the "Fade" option). Click to open OmaBlinker's settings popup.
BarWidget {
  id: root
  moduleName: "jayosays.omablinker"

  readonly property var hddService: bar?.shell?.serviceFor(moduleName)

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
  // "Combined": one LED for all block I/O, matching the daemon's original
  // behavior. "Read/Write": two LEDs, tracking each direction the daemon
  // already classifies independently (see bpfd/omablinker-bpfd-ebpf).
  property string activityMode: "Combined"
  // Only meaningful (and only shown in the popup) in Read/Write mode.
  property bool inscribeLetters: false
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
    // A cheap size guard before parsing: our own writes are never more than
    // a few dozen bytes, so anything wildly larger is either not ours or
    // not worth trying to parse.
    if (!text || text.length > 4096) return
    try {
      var data = JSON.parse(text)
      if (data.ledShape === "Square" || data.ledShape === "Circle") root.ledShape = data.ledShape
      if (data.colorScheme === "Red" || data.colorScheme === "Amber") root.colorScheme = data.colorScheme
      if (data.blinkStyle === "Abrupt" || data.blinkStyle === "Fade") root.blinkStyle = data.blinkStyle
      if (data.activityMode === "Combined" || data.activityMode === "Read/Write") root.activityMode = data.activityMode
      if (typeof data.inscribeLetters === "boolean") root.inscribeLetters = data.inscribeLetters
    } catch (e) {
      // No prefs file yet, or it's malformed — the defaults above stand.
    }
  }

  function writePrefs() {
    prefsFile.setText(JSON.stringify({
      ledShape: root.ledShape,
      colorScheme: root.colorScheme,
      blinkStyle: root.blinkStyle,
      activityMode: root.activityMode,
      inscribeLetters: root.inscribeLetters
    }))
  }

  // Reads and writes the prefs file directly — no subprocess, no shell, no
  // PATH lookup. setText() creates ~/.config/omablinker/ itself if it
  // doesn't exist yet, so there's no separate `mkdir -p` step either.
  FileView {
    id: prefsFile
    path: root.prefsPath
    printErrors: false
    onLoaded: root.applyPrefsJson(text())
  }

  // Square: the boxy drive-activity LEDs common on PC front panels.
  // Circle: a classic round 5mm LED. Applies to every LED regardless of
  // Activity mode.
  readonly property bool circle: ledShape === "Circle"

  // Red: the classic 5mm LED on most beige-box drive lights. Amber: the
  // orange tone common on 386/486-era cases (often shared with the turbo
  // button light). Only used in Combined mode — Read/Write mode's colors
  // are fixed (see readColor/writeColor below), not a style choice.
  readonly property var colorPresets: ({
    "Red": "#ff2400",
    "Amber": "#ffb000"
  })
  readonly property color onColor: colorPresets[colorScheme] || colorPresets["Red"]

  // Fixed, not user-selectable: green-for-read/red-for-write is a
  // deliberate, accessibility-motivated convention (see the popup's
  // Activity option), not a stylistic pick like Combined mode's color.
  // Both colors were also the two most common LED colors on vintage PC
  // front panels (green power + red/amber activity), so the pairing stays
  // in period even though it wasn't historically used for read vs write.
  readonly property color readColor: "#33cc33"
  readonly property color writeColor: "#ff2400"

  // Abrupt: no animation, the LED snaps on/off like a real one.
  // Fade: a quick ramp up and a slower, lingering fall off.
  readonly property bool abrupt: blinkStyle !== "Fade"
  readonly property int rampUpMs: abrupt ? 0 : 15
  readonly property int rampDownMs: abrupt ? 0 : 200
  readonly property int haloMs: abrupt ? 0 : 150

  readonly property bool dualMode: activityMode === "Read/Write"
  readonly property bool combinedActive: hddService ? hddService.combinedActive : false
  readonly property bool readActive: hddService ? hddService.readActive : false
  readonly property bool writeActive: hddService ? hddService.writeActive : false

  readonly property string statusText: {
    if (!hddService || !hddService.daemonSeen) return qsTr("Starting HDD activity light…")
    if (!root.dualMode) return root.combinedActive ? qsTr("Storage activity") : qsTr("Idle")
    if (root.readActive && root.writeActive) return qsTr("Read + write activity")
    if (root.readActive) return qsTr("Read activity")
    if (root.writeActive) return qsTr("Write activity")
    return qsTr("Idle")
  }

  implicitWidth: ledRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: ledRow
    anchors.centerIn: parent
    spacing: Style.space(4)

    LedIndicator {
      visible: !root.dualMode
      ledColor: root.onColor
      active: root.combinedActive
      circle: root.circle
      rampUpMs: root.rampUpMs
      rampDownMs: root.rampDownMs
      haloMs: root.haloMs
    }

    LedIndicator {
      visible: root.dualMode
      ledColor: root.readColor
      active: root.readActive
      circle: root.circle
      rampUpMs: root.rampUpMs
      rampDownMs: root.rampDownMs
      haloMs: root.haloMs
      inscribeChar: root.inscribeLetters ? "R" : ""
    }

    LedIndicator {
      visible: root.dualMode
      ledColor: root.writeColor
      active: root.writeActive
      circle: root.circle
      rampUpMs: root.rampUpMs
      rampDownMs: root.rampDownMs
      haloMs: root.haloMs
      inscribeChar: root.inscribeLetters ? "W" : ""
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
        // rest of the shell's glyph icons. Tinted with the Combined-mode
        // color, since there's no single "the LED" color once Read/Write
        // mode is active.
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
        title: qsTr("Activity")
        options: ["Combined", "Read/Write"]
        current: root.activityMode
        onPicked: function(value) { root.activityMode = value; root.writePrefs() }
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

      // LED color and "Inscribe letters" are mutually exclusive: color is
      // a style choice that only applies to the single Combined-mode LED,
      // and the inscribed letters only make sense once there are two
      // fixed-color LEDs to tell apart. Each option group's own separator
      // is paired with it so hiding one never leaves two separators
      // sitting next to each other with nothing between them.

      PanelSeparator {
        visible: !root.dualMode
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      OptionGroup {
        visible: !root.dualMode
        title: qsTr("LED color")
        options: ["Red", "Amber"]
        current: root.colorScheme
        onPicked: function(value) { root.colorScheme = value; root.writePrefs() }
      }

      PanelSeparator {
        visible: root.dualMode
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      OptionGroup {
        visible: root.dualMode
        title: qsTr("Show (R)ead / (W)rite Labels")
        options: ["Off", "On"]
        current: root.inscribeLetters ? "On" : "Off"
        onPicked: function(value) { root.inscribeLetters = value === "On"; root.writePrefs() }
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

  // One LED: a thin rim (not a diffuse glow — light catching the edges of
  // the panel cutout the LED sits behind, the way a slightly-too-big hole
  // lets a sliver of light spill around a real indicator LED), the LED
  // itself (opacity-faded rather than color-faded, and fully transparent
  // when idle — see the color-vs-opacity note below), and an optional
  // inscribed letter.
  //
  // The rim is a sibling of the fill, not nested inside it — an earlier
  // version nested it, which meant the rim's own opacity animation
  // silently multiplied against the fill's during a fade (compounding two
  // animations instead of each running independently). The letter is the
  // opposite case: it's nested *inside* the fill deliberately, with no
  // animation of its own, so it inherits the fill's animated opacity
  // directly — appearing and disappearing in exact lockstep with the LED
  // itself, on only while there's activity.
  component LedIndicator: Item {
    id: ledItem

    property color ledColor: "#ff2400"
    property bool active: false
    property bool circle: false
    property int rampUpMs: 0
    property int rampDownMs: 0
    property int haloMs: 0
    // Empty string means no letter — used for the single Combined-mode LED.
    property string inscribeChar: ""

    // 25% larger than the original 10/2: the R/W letter's font.pixelSize
    // below is defined as a fraction of this LED's own height, so it scales
    // right along with it — no separate font-size change needed.
    implicitWidth: Style.space(12.5)
    implicitHeight: Style.space(12.5)
    width: implicitWidth
    height: implicitHeight

    Rectangle {
      anchors.centerIn: parent
      width: parent.width + Style.space(2.5)
      height: parent.height + Style.space(2.5)
      radius: ledItem.circle ? width / 2 : 0
      color: ledItem.ledColor
      opacity: ledItem.active ? 0.35 : 0
      Behavior on opacity { NumberAnimation { duration: ledItem.haloMs } }
    }

    Rectangle {
      anchors.fill: parent
      radius: ledItem.circle ? width / 2 : 0
      color: ledItem.ledColor
      // Fades opacity rather than color: animating color itself between
      // ledColor and "transparent" would cross-fade through transparent
      // *black* along the way, since both RGB and alpha interpolate
      // together — opacity keeps the hue constant and only fades the alpha.
      opacity: ledItem.active ? 1 : 0

      Behavior on opacity {
        NumberAnimation { duration: ledItem.active ? ledItem.rampUpMs : ledItem.rampDownMs }
      }

      // A child of the fill, not a sibling: its opacity is left unset (so
      // it's always 1 on its own), which means what actually renders is
      // 1 × the fill's opacity above — the letter only ever appears while
      // the LED is lit, fading with the exact same timing, with no
      // separate animation to keep in sync by hand.
      Text {
        // Filling the parent and centering via alignment, rather than
        // `anchors.centerIn` on the Text's own implicit (font-metric-based)
        // size: a single glyph's ink isn't symmetric within its line-height
        // bounding box (ascent/descent padding differs above and below), so
        // centering that box doesn't center the visible letter. Aligning
        // within the LED's actual full area does.
        anchors.fill: parent
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        visible: ledItem.inscribeChar !== ""
        text: ledItem.inscribeChar
        textFormat: Text.PlainText
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.bold: true
        font.pixelSize: parent.height * 0.8
        color: "#101010"
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
