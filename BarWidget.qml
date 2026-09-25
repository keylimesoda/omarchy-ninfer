import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "keylimesoda.ninfer"
  ipcTarget: "keylimesoda.ninfer"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the extra `service` and `vision` methods below.
  manageIpc: false

  // Helper that drives the local inference container. It ships in the plugin
  // directory (see `ninfer-qwen`); the knobs — container name, API endpoint,
  // model metadata — live at the top of that script.
  readonly property string bin: {
    const u = Qt.resolvedUrl("ninfer-qwen").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- service state, polled from the helper ----
  property string serviceState: "checking"   // off | starting | ready | failed
  property string stateBeforeAction: ""
  property bool actionRunning: false
  property var info: ({})

  // ---- live rates derived between `info` samples ----
  property var lastSample: null
  property real genTps: -1
  property real promptTps: -1

  readonly property bool on: root.serviceState === "ready"
  readonly property bool starting: root.serviceState === "starting"
  readonly property bool failed: root.serviceState === "failed"
  readonly property bool serviceActive: root.on || root.starting
  readonly property bool busy: root.actionRunning
  readonly property bool visionOn: root.info.vision === "on"

  readonly property color stateColor: root.on ? "#adda78"
    : root.failed ? Color.urgent
    : root.starting ? Color.accent
    : Color.muted

  readonly property string stateLabel: {
    if (root.actionRunning)
      return (root.stateBeforeAction === "ready" || root.stateBeforeAction === "starting")
        ? "Stopping" : "Starting"
    if (root.on) return "Ready"
    if (root.failed) return "Failed"
    if (root.starting) return "Starting"
    if (root.serviceState === "checking") return "Checking"
    return "Offline"
  }

  readonly property var cacheParts: root.cachePartsValue()
  function cachePartsValue() { return Model.cacheParts(root.info) }

  // Keyboard cursor targets: "hero" (power switch) | "vision" (input switch) | "actions" (logs)
  property string focusSection: "hero"
  property bool cursorActive: false

  function pollStatus() { if (!statusProc.running) statusProc.running = true }
  function refreshInfo() { if (!infoProc.running) infoProc.running = true }

  function ingestInfo(raw) {
    const text = String(raw || "").trim()
    if (!text) return
    const parsed = Model.parseInfo(text)
    root.info = parsed
    root.serviceState = parsed.state
    if (parsed.state === "ready") {
      const sample = {
        epoch: Number(parsed.epoch || 0),
        predicted: Number(parsed.predicted_tokens || 0),
        prompt: Number(parsed.prompt_tokens || 0),
        t: Date.now()
      }
      const prev = root.lastSample
      if (prev && prev.epoch === sample.epoch && sample.t > prev.t) {
        const dt = (sample.t - prev.t) / 1000
        if (dt >= 2) {
          root.genTps = Math.max(0, sample.predicted - prev.predicted) / dt
          root.promptTps = Math.max(0, sample.prompt - prev.prompt) / dt
        }
      } else {
        root.genTps = -1
        root.promptTps = -1
      }
      root.lastSample = sample
    } else {
      root.lastSample = null
      root.genTps = -1
      root.promptTps = -1
    }
  }

  function toggleService() {
    if (root.actionRunning) return
    root.stateBeforeAction = root.serviceState
    root.actionRunning = true
    actionProc.command = [root.bin, "toggle"]
    actionProc.running = true
  }

  function openLogs() {
    if (!logsProc.running) logsProc.running = true
  }

  function toggleVision() {
    if (root.actionRunning) return
    root.stateBeforeAction = root.serviceState
    root.actionRunning = true
    actionProc.command = [root.bin, "vision", "toggle"]
    actionProc.running = true
  }

  IpcHandler {
    target: "keylimesoda.ninfer"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function service() { root.toggleService() }
    function vision() { root.toggleVision() }
  }

  onOpenedChanged: {
    if (opened) {
      root.refreshInfo()
      root.cursorActive = false
      root.focusSection = "hero"
    }
  }

  Process {
    id: statusProc
    command: [root.bin, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const value = String(text || "").trim()
        if (["ready", "starting", "failed", "off"].indexOf(value) >= 0)
          root.serviceState = value
      }
    }
  }

  Process {
    id: infoProc
    command: [root.bin, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestInfo(text)
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.actionRunning = false
      root.pollStatus()
      root.refreshInfo()
    }
  }

  Process {
    id: logsProc
    command: ["omarchy", "launch", "terminal", "docker", "logs", "--follow", "--tail", "200", "ninfer-qwen"]
  }

  Timer { interval: 5000; repeat: true; running: true; onTriggered: root.pollStatus() }

  Timer {
    interval: 4000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refreshInfo()
  }

  Component.onCompleted: {
    root.pollStatus()
    root.refreshInfo()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Official Qwen mark (monochrome silhouette) tinted by state color.
    iconComponent: qMarkBar
    active: root.on || root.failed
    activeColor: root.failed ? Color.urgent : "#adda78"
    dimmed: root.serviceState === "off"
    tooltipText: root.failed ? "NInfer failed. Click for details, right-click to retry."
      : root.on ? "Qwen 3.8 is ready. Click for details, right-click to stop."
      : root.starting ? "NInfer is starting. Click for details, right-click to stop."
      : "Qwen 3.8 is offline. Click for details, right-click to start."
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleService()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(1400))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        const d = dy !== 0 ? dy : dx
        if (d === 0) return
        const sections = ["hero", "vision", "actions"]
        const i = sections.indexOf(root.focusSection)
        root.focusSection = sections[(i + (d > 0 ? 1 : sections.length - 1)) % sections.length]
      }
      onActivateRequested: {
        if (!root.cursorActive) return
        if (root.focusSection === "hero") root.toggleService()
        else if (root.focusSection === "vision") root.toggleVision()
        else root.openLogs()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: Qwen mark · NInfer [state] · power switch ----------
          PanelHero {
            iconComponent: qMarkHero
            title: "NInfer"
            detail: root.stateLabel.toUpperCase()
            meta: Model.modelName(root.info)
            foreground: root.fg
            fontFamily: root.ff

            trailingControl: Component {
              ToggleSwitch {
                id: heroSwitch
                checked: root.serviceActive
                busy: root.busy
                hasCursor: root.cursorActive && root.focusSection === "hero"
                foreground: root.fg
                onHovered: function(on) {
                  if (on) {
                    root.cursorActive = true
                    root.focusSection = "hero"
                  }
                }
                onToggled: root.toggleService()

                PanelToolTip {
                  visible: heroSwitch.containsMouse
                  text: root.serviceActive ? "Stop Qwen 3.8" : "Start Qwen 3.8"
                  fontFamily: root.ff
                }
              }
            }
          }

          // ---------- Live at-a-glance strip ----------
          Row {
            width: parent.width
            spacing: Style.space(12)

            StatCell { label: "Generation"; value: root.on ? Model.tps(root.genTps) : "—" }
            StatCell { label: "Prefill"; value: root.on ? Model.tps(root.promptTps) : "—" }
            StatCell { label: "Power"; value: root.on ? Model.watts(root.info.power_watts) : "—" }
          }

          PanelSeparator {
            foreground: root.fg
          }

          // ---------- Model ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MODEL"
              foreground: root.fg
              fontFamily: root.ff
            }

            Row {
              width: parent.width
              spacing: Style.space(20)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Model"; value: Model.modelName(root.info) }
                InfoPair { label: "Context"; value: Model.contextLabel(root.info) }
                InfoPair { label: "KV cache"; value: Model.kvLabel(root.info) }
                InfoPair { label: "Spec decode"; value: Model.specLabel(root.info) }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "GPU"; value: Model.gpuLabel(root.info) }
                InfoPair { label: "Uptime"; value: root.on ? Model.uptime(root.info.epoch) : "—" }
                InfoPair { label: "Endpoint"; value: root.info.endpoint || "—" }
                InfoPair { label: "Image"; value: root.info.image || "—" }
              }
            }
          }

          // ---------- Throughput (live) ----------
          PanelSeparator {
            visible: root.on
            foreground: root.fg
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.on

            PanelSectionHeader {
              text: "THROUGHPUT"
              foreground: root.fg
              fontFamily: root.ff
            }

            Row {
              width: parent.width
              spacing: Style.space(20)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Prefix cache"; value: Model.prefixHitLabel(root.info) }
                InfoPair { label: "Draft accept"; value: Model.specAcceptLabel(root.info) }
                InfoPair { label: "Generated"; value: Model.generatedLabel(root.info) }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Requests"; value: Model.requestsLabel(root.info) }
                InfoPair { label: "Power draw"; value: Model.watts(root.info.power_watts) }
                InfoPair { label: "Total requests"; value: Model.group(root.info.requests_total) }
              }
            }
          }

          // ---------- Continuation cache (live) ----------
          PanelSeparator {
            visible: root.on
            foreground: root.fg
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.on

            PanelSectionHeader {
              text: "CONTINUATION CACHE"
              foreground: root.fg
              fontFamily: root.ff
            }

            InfoPair { label: "Restored"; value: Model.contLabel(root.info) }

            // Stacked L1/L2/L3 restored-tokens bar.
            Item {
              width: parent.width
              implicitHeight: Style.space(10)

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Util.alpha(root.fg, 0.12)
              }

              Row {
                anchors.fill: parent

                Rectangle {
                  height: parent.height
                  radius: 2
                  width: Math.max(0, parent.width * root.cacheParts.l1)
                  color: "#adda78"
                }
                Rectangle {
                  height: parent.height
                  radius: 2
                  width: Math.max(0, parent.width * root.cacheParts.l2)
                  color: Color.accent
                }
                Rectangle {
                  height: parent.height
                  radius: 2
                  width: Math.max(0, parent.width * root.cacheParts.l3)
                  color: Color.muted
                }
              }
            }

            Row {
              spacing: Style.space(14)

              CacheChip { tint: "#adda78"; label: "L1 " + Model.human(root.cacheParts.rawL1) }
              CacheChip { tint: Color.accent; label: "L2 " + Model.human(root.cacheParts.rawL2) }
              CacheChip { tint: Color.muted; label: "L3 " + Model.human(root.cacheParts.rawL3) }
            }
          }

          // ---------- Vision input ----------
          PanelSeparator {
            foreground: root.fg
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "VISION"
              foreground: root.fg
              fontFamily: root.ff
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              color: root.fg
              opacity: 0.65
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
              text: "Multimodal input: the model accepts images and video frames. Changing this restarts the model if it is running."
            }

            Toggle {
              id: visionToggle
              width: parent.width
              label: "Enable vision"
              checked: root.visionOn
              foreground: root.fg
              fontFamily: root.ff
              hasCursor: root.cursorActive && root.focusSection === "vision"
              onHovered: function(on) {
                if (on) {
                  root.cursorActive = true
                  root.focusSection = "vision"
                }
              }
              onClicked: root.toggleVision()
            }
          }

          // ---------- Actions ----------
          PanelSeparator {
            foreground: root.fg
          }

          Button {
            id: logsBtn
            width: parent.width
            // Explicit height: guards against the button collapsing when its
            // implicit height resolves late (icon-glyph metrics), which would
            // drop the whole actions section out of the column's implicit
            // height and clip it off the panel.
            height: implicitHeight > 0
              ? implicitHeight
              : Style.spacing.controlHeight + Style.spacing.controlPaddingY * 2
            iconText: "\u{F00C5}"  // console
            text: "Logs"
            foreground: root.fg
            fontFamily: root.ff
            bordered: true
            hasCursor: root.cursorActive && root.focusSection === "actions"
            onClicked: root.openLogs()
            onHovered: function(h) {
              if (h) {
                root.cursorActive = true
                root.focusSection = "actions"
              }
            }
          }
        }
      }
    }
  }

  // ---------- Reusable inline components ----------

  // The official Qwen mark: a monochrome line drawing of the brand mark
  // (assets/qwen.png), tinted to the service state color.
  component QwenMark: Item {
    id: mark
    property real size: Style.space(20)
    property color ink: root.fg

    width: size
    height: size

    MultiEffect {
      anchors.fill: parent
      colorization: 1.0
      colorizationColor: mark.ink

      Behavior on colorizationColor { ColorAnimation { duration: 200 } }

      source: Image {
        smooth: true
        sourceSize: Qt.size(200, 200)
        source: "assets/qwen.png"
        fillMode: Image.PreserveAspectFit
      }
    }
  }

  // Bar-sized mark.
  Component {
    id: qMarkBar
    QwenMark {
      size: Style.bar.iconCanvas
      ink: root.stateColor
    }
  }

  // Hero-sized mark; pulses while the service is waking up.
  Component {
    id: qMarkHero
    QwenMark {
      size: Style.font.display
      ink: root.stateColor

      SequentialAnimation on opacity {
        running: root.starting && root.opened
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
      }
    }
  }

  // Vertical stat chip: bold value over a dim label.
  component StatCell: Item {
    id: statCell
    property string label: ""
    property string value: ""

    width: parent ? (parent.width - parent.spacing * 2) / 3 : 0
    implicitHeight: statInner.implicitHeight

    Column {
      id: statInner
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: statCell.value
        color: root.fg
        font.family: root.ff
        font.pixelSize: Style.font.body
        font.bold: true
        opacity: statCell.value === "—" ? 0.45 : 1.0
      }

      Text {
        textFormat: Text.PlainText
        text: statCell.label
        color: root.fg
        opacity: 0.55
        font.family: root.ff
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.8
      }
    }
  }

  // Label left, flexible gap, value right.
  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  // Tiny colored bullet + label for the cache-tier legend.
  component CacheChip: Row {
    id: cacheChip
    property string label: ""
    property color tint: root.fg
    spacing: Style.space(5)

    Rectangle {
      width: Style.space(7)
      height: Style.space(7)
      radius: 2
      color: cacheChip.tint
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: cacheChip.label
      color: root.fg
      opacity: 0.7
      font.family: root.ff
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}