import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "anders.appletv-remote"
  ipcTarget: "anders.appletv-remote"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string pluginDir: configHome + "/omarchy/plugins/anders.appletv-remote"
  readonly property string backend: pluginDir + "/bin/apple-tv"
  readonly property string setupScript: pluginDir + "/bin/setup"
  readonly property string identifier: String(setting("identifier", "") || "")
  readonly property var activeDevice: findActiveDevice()
  readonly property string activeIdentifier: activeDevice ? String(activeDevice.identifier) : ""
  readonly property string activeAddress: activeDevice ? String(activeDevice.address) : ""
  readonly property bool maskTextPreview: Boolean(setting("maskTextPreview", true))
  readonly property bool networkScan: Boolean(setting("networkScan", false))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string shortcutSettings: String(setting("shortcuts", "{}") || "{}")
  readonly property var shortcutActions: [
    {id: "up", label: "Up", key: Qt.Key_Up, text: "↑"},
    {id: "down", label: "Down", key: Qt.Key_Down, text: "↓"},
    {id: "left", label: "Left", key: Qt.Key_Left, text: "←"},
    {id: "right", label: "Right", key: Qt.Key_Right, text: "→"},
    {id: "select", label: "Select", key: Qt.Key_Return, text: "Enter"},
    {id: "menu", label: "Back / Menu", key: Qt.Key_Backspace, text: "Backspace"},
    {id: "play_pause", label: "Play / Pause", key: Qt.Key_Space, text: "Space"},
    {id: "home", label: "Home", key: Qt.Key_H, text: "H"},
    {id: "volume_down", label: "Volume down", key: Qt.Key_Comma, text: ","},
    {id: "volume_up", label: "Volume up", key: Qt.Key_Period, text: "."}
  ]
  property bool shortcutsVisible: false
  property string capturingShortcut: ""
  property string shortcutMessage: "Choose an action, then press its new key. Escape cancels."

  function shortcutOverrides() {
    try {
      if (shortcutSettings.length > 4096) return ({})
      var result = JSON.parse(shortcutSettings)
      return result && typeof result === "object" && !Array.isArray(result) ? result : ({})
    } catch (error) { return ({}) }
  }

  function shortcutFor(action) {
    var value = shortcutOverrides()[action.id]
    if (value && typeof value.key === "number" && value.key > 0 && value.key < 0x02000000
        && value.key !== Qt.Key_Escape && typeof value.modifiers === "number"
        && typeof value.text === "string" && value.text.length <= 40) return value
    return {key: action.key, modifiers: 0, text: action.text}
  }

  function shortcutLabel(id) {
    for (var action of shortcutActions) if (action.id === id) return shortcutFor(action).text
    return ""
  }

  function saveSettings(changes) {
    if (!bar || !bar.shell) return
    var entry = {id: moduleName, identifier: identifier, maskTextPreview: maskTextPreview,
                 networkScan: networkScan, shortcuts: shortcutSettings}
    for (var key in changes) entry[key] = changes[key]
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function captureShortcut(event) {
    if (event.key === Qt.Key_Escape) { capturingShortcut = ""; return }
    if ([Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta].indexOf(event.key) >= 0 || event.isAutoRepeat) return
    var key = event.key === Qt.Key_Enter ? Qt.Key_Return : event.key
    var modifiers = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier)
    for (var action of shortcutActions) {
      var existing = shortcutFor(action)
      if (action.id !== capturingShortcut && existing.key === key && existing.modifiers === modifiers) {
        shortcutMessage = "Already used for " + action.label + ". Choose another key."
        return
      }
    }
    var label = ""
    for (var action of shortcutActions) if (action.key === key) label = action.text
    if (!label && key >= Qt.Key_A && key <= Qt.Key_Z) label = String.fromCharCode(key)
    if (!label && key >= Qt.Key_0 && key <= Qt.Key_9) label = String.fromCharCode(key)
    if (!label && key >= Qt.Key_F1 && key <= Qt.Key_F35) label = "F" + (key - Qt.Key_F1 + 1)
    if (!label && event.text && event.text.charCodeAt(0) >= 32) label = event.text.toUpperCase()
    if (!label) { shortcutMessage = "Choose a letter, number, function key, or remote key."; return }
    label = ((modifiers & Qt.ControlModifier) ? "Ctrl+" : "") + ((modifiers & Qt.AltModifier) ? "Alt+" : "")
      + ((modifiers & Qt.MetaModifier) ? "Super+" : "") + ((modifiers & Qt.ShiftModifier) ? "Shift+" : "") + label
    var overrides = shortcutOverrides()
    overrides[capturingShortcut] = {key: key, modifiers: modifiers, text: label}
    saveSettings({shortcuts: JSON.stringify(overrides)})
    capturingShortcut = ""
    shortcutMessage = "Shortcut saved."
  }

  property string connectionState: "searching"
  property var nowPlaying: ({})
  property double positionReceivedAt: Date.now()
  property double playbackClock: Date.now()
  readonly property real playbackPosition: estimatedPosition()
  property bool pairingVisible: false
  property string pairingStep: "idle"
  property string pairingMessage: "Choose a TV above or enter its IP address."
  property string statusText: "Searching…"
  property string lastError: ""
  property var devices: []
  property int discoveryCycle: 0
  property string lastStroke: "—"
  property string lastAction: "Waiting for a key"
  property bool textInputActive: false
  property string typedPreview: ""
  property var commandQueue: []
  property string runningCommand: ""

  function findActiveDevice() {
    if (devices.length === 1 && identifier === "") return devices[0]
    for (var index = 0; index < devices.length; ++index) {
      var device = devices[index]
      if (String(device.identifier) === identifier || String(device.address) === identifier) return device
    }
    return null
  }

  function playingDetails() {
    var media = nowPlaying
    var parts = []
    if (media.series && media.series !== media.title) parts.push(media.series)
    var artist = media.artist || ""
    // Some apps put the episode reference and title in the artist field.
    if (!/^S\d+[: ]*E\d+/i.test(artist)) {
      var episode = []
      if (media.season !== undefined && media.season !== null) episode.push("Season " + media.season)
      if (media.episode !== undefined && media.episode !== null) episode.push("Episode " + media.episode)
      if (episode.length) parts.push(episode.join(" · "))
    }
    if (artist && artist !== media.title && artist !== media.series) parts.push(artist)
    return parts.join(" · ")
  }

  function estimatedPosition() {
    var position = nowPlaying.position
    if (position === undefined || position === null || !isFinite(position) || position < 0) return -1
    var elapsed = nowPlaying.state === "Playing" ? Math.max(0, playbackClock - positionReceivedAt) / 1000 : 0
    var estimate = position + elapsed
    return nowPlaying.duration > 0 ? Math.min(estimate, nowPlaying.duration) : estimate
  }

  function mediaTime(seconds) {
    if (seconds === undefined || seconds === null || !isFinite(seconds) || seconds < 0) return ""
    var total = Math.floor(seconds)
    var hours = Math.floor(total / 3600)
    var minutes = Math.floor(total / 60) % 60
    var remainder = String(total % 60).padStart(2, "0")
    return hours ? hours + ":" + String(minutes).padStart(2, "0") + ":" + remainder
                 : minutes + ":" + remainder
  }

  function displayedPreview() {
    return maskTextPreview ? "•".repeat(typedPreview.length) : typedPreview
  }

  function migrateLegacyIdentifier() {
    if (!activeDevice || !bar || !bar.shell) return
    if (identifier === String(activeDevice.address)) {
      saveSettings({identifier: String(activeDevice.deviceIdentifier)})
    }
  }

  function command(name) {
    if (activeAddress === "") {
      statusText = devices.length > 1 ? "Choose an Apple TV" : "No Apple TV found"
      return
    }
    if (pairingVisible || shortcutsVisible) return
    lastError = ""
    if (commandQueue.length >= 32) {
      lastError = "Apple TV is busy; wait before sending more keys"
      return
    }
    commandQueue = commandQueue.concat([name])
    runNextCommand()
  }

  function runNextCommand() {
    if (action.running || commandQueue.length === 0 || activeAddress === "") return
    runningCommand = commandQueue[0]
    commandQueue = commandQueue.slice(1)
    action.pendingCommand = runningCommand
    action.command = [backend, activeAddress, "--stdin"]
    action.running = true
  }

  function sendStroke(stroke, actionName, commandName) {
    lastStroke = stroke
    lastAction = actionName
    command(commandName)
  }

  function sendText(text) {
    lastStroke = text === " " ? "SPACE" : text
    lastAction = "Text sent to Apple TV"
    if (typedPreview.length + text.length > 256) typedPreview = ""
    typedPreview += text
    previewClear.restart()
    command("text_append:" + text)
  }

  function sendTextBackspace() {
    lastStroke = "BACKSPACE"
    lastAction = "Text updated on Apple TV"
    if (typedPreview.length > 0) typedPreview = typedPreview.slice(0, -1)
    previewClear.restart()
    command("text_backspace")
  }

  function pollKeyboardState() {
    if (!opened || pairingVisible || focusState.running || activeAddress === "" || connectionState === "pairing") return
    focusState.command = [backend, activeAddress, "keyboard_watch"]
    focusState.running = true
  }

  function setup() {
    pairingVisible = true
    pairingStep = "idle"
    pairingMessage = connectionState === "connected"
      ? "This Apple TV is already paired and connected. Choose another TV above, or pair again if you need to replace its pairing."
      : "Choose a TV above or enter its IP address. Pairing displays a PIN on the TV."
    pairAddress.text = activeAddress
    pairSecret.text = ""
    focusState.running = false
    commandQueue = []
    Qt.callLater(function() { pairAddress.forceActiveFocus() })
  }

  function startPairing() {
    if (pairProcess.running || pairAddress.text.trim() === "") return
    pairingStep = "progress"
    pairingMessage = "Connecting…"
    pairProcess.command = [pluginDir + "/bin/pair-device", pairAddress.text.trim()]
    pairProcess.running = true
  }

  function submitPairing() {
    if (!pairProcess.running || pairSecret.text === "") return
    pairProcess.write(JSON.stringify({value: pairSecret.text}) + "\n")
    pairSecret.text = ""
    pairingStep = "progress"
    pairingMessage = "Verifying…"
  }

  function cancelPairing() {
    pairProcess.running = false
    pairSecret.text = ""
    pairingVisible = false
    pairingStep = "idle"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    refresh()
  }

  function applyResult(result) {
    if (result.ok === false) {
      connectionState = result.state || "error"
      statusText = connectionState === "pairing" ? "Pairing needed"
                 : connectionState === "offline" ? "Offline" : "Connection error"
      lastError = result.error || "Could not reach Apple TV"
      nowPlaying = ({})
      return
    }
    connectionState = "connected"
    lastError = ""
    statusText = result.power === "Off" ? "Apple TV is asleep" : "Connected"
    if (result.playing !== undefined) {
      positionReceivedAt = Date.now()
      playbackClock = positionReceivedAt
      nowPlaying = result.playing
    }
    Qt.callLater(pollKeyboardState)
  }

  function refresh(scanNetwork) {
    if (discover.running || pairProcess.running) return
    discover.command = [pluginDir + "/bin/discover"]
    if (scanNetwork === true && networkScan) discover.command = discover.command.concat(["--network"])
    if (connectionState !== "connected") statusText = "Searching…"
    discover.running = true
  }

  function refreshStatus() {
    if (!opened || status.running || pairingVisible || activeAddress === "") return
    status.command = [backend, activeAddress, "status"]
    status.running = true
  }

  function selectDevice(device) {
    if (!device || !bar || !bar.shell) return
    saveSettings({identifier: String(device.deviceIdentifier)})
    if (pairingVisible && !pairProcess.running) pairAddress.text = String(device.address)
    statusText = "Selected " + device.name
    Qt.callLater(refreshStatus)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh(networkScan)
  Component.onDestruction: {
    lifetime.running = false
    discover.running = false
    action.running = false
    status.running = false
    focusState.running = false
    pairProcess.running = false
    reconnect.running = false
  }

  onOpenedChanged: {
    if (opened) {
      playbackClock = Date.now()
      lastStroke = "—"
      lastAction = "Waiting for a key"
      typedPreview = ""
      textInputActive = false
      refresh()
      pollKeyboardState()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      focusState.running = false
      pairProcess.running = false
      pairSecret.text = ""
      pairingVisible = false
      shortcutsVisible = false
      capturingShortcut = ""
      textInputActive = false
      commandQueue = []
    }
  }

  onActiveAddressChanged: {
    connectionState = activeAddress !== "" ? "connecting" : "offline"
    statusText = activeAddress !== "" ? "Connecting…" : "No Apple TV found"
    lastError = ""
    commandQueue = []
    action.running = false
    status.running = false
    nowPlaying = ({})
    focusState.running = false
    textInputActive = false
    if (opened && activeAddress !== "") Qt.callLater(pollKeyboardState)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function up(): string { root.command("up"); return "ok" }
    function down(): string { root.command("down"); return "ok" }
    function left(): string { root.command("left"); return "ok" }
    function right(): string { root.command("right"); return "ok" }
    function select(): string { root.command("select"); return "ok" }
    function menu(): string { root.command("menu"); return "ok" }
    function home(): string { root.command("home"); return "ok" }
    function playPause(): string { root.command("play_pause"); return "ok" }
    function power(): string { root.command("turn_off"); return "ok" }
    function status(): string { return root.statusText }
    function settings(): void { root.open(); root.setup() }
    function shortcuts(): void { root.open(); root.shortcutsVisible = true }
    function details(): string { return JSON.stringify({state: root.connectionState, device: root.activeDevice, playing: root.nowPlaying, displayedPosition: root.playbackPosition, pairing: root.pairingVisible, keyboardActive: root.opened && keyCatcher.activeFocus && !root.pairingVisible && !root.shortcutsVisible}) }
  }

  Process {
    id: lifetime
    command: ["/usr/bin/sleep", "infinity"]
    running: true
  }

  Process {
    id: discover
    environment: ({ATV_COMPONENT_PID: String(lifetime.processId)})
    command: [root.pluginDir + "/bin/discover"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(text.trim() || "{}")
          if (!Array.isArray(result.devices) || result.devices.length > 32) throw new Error("Invalid devices")
          root.devices = result.devices
          root.lastError = result.error || ""
          root.migrateLegacyIdentifier()
          if (root.devices.length === 0) {
            root.connectionState = result.error ? "error" : "offline"
            root.statusText = result.error ? "Discovery failed" : "No Apple TV found"
            root.nowPlaying = ({})
          } else if (!root.activeDevice) root.statusText = "Choose an Apple TV"
          else if (root.opened) root.refreshStatus()
          else if (root.connectionState !== "connected") {
            root.connectionState = "available"
            root.statusText = "Apple TV available"
          }
        } catch (error) {
          root.devices = []
          root.lastError = "Could not read discovery results"
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 127) root.statusText = "Setup required"
      else if (exitCode !== 0 && root.lastError === "") root.statusText = "Discovery failed"
    }
  }

  Process {
    id: action
    property string pendingCommand: ""
    environment: ({ATV_COMPONENT_PID: String(lifetime.processId)})
    stdinEnabled: true
    onStarted: {
      // Commands can contain passwords typed into an Apple TV field. Keep them
      // out of argv and /proc/PID/cmdline by sending a bounded JSON frame.
      write(JSON.stringify({command: pendingCommand}) + "\n")
      pendingCommand = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.applyResult(JSON.parse(text.trim())) } catch (error) {}
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.commandQueue = []
      if (exitCode === 127) root.statusText = "Setup required"
      if (exitCode === 0 && ["play", "pause", "play_pause"].indexOf(root.runningCommand) >= 0)
        Qt.callLater(root.refreshStatus)
      root.runningCommand = ""
      action.pendingCommand = ""
      Qt.callLater(root.runNextCommand)
    }
  }

  Process {
    id: focusState
    environment: ({ATV_COMPONENT_PID: String(lifetime.processId)})
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var result = JSON.parse(String(line).trim() || "{}")
          if (result.ok === false) root.applyResult(result)
          root.textInputActive = result.keyboard === "Focused"
        } catch (error) {
          root.lastError = "Could not read keyboard state"
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (String(line).trim() !== "") root.lastError = String(line).trim()
      }
    }
    onExited: function(exitCode) {
      root.textInputActive = false
      if (root.opened && root.activeAddress !== "" && exitCode !== 127) focusRetry.restart()
    }
  }

  Timer { id: focusRetry; interval: 5000; repeat: false; onTriggered: root.pollKeyboardState() }

  Timer {
    id: previewClear
    interval: 1800
    repeat: false
    onTriggered: {
      root.typedPreview = ""
      root.lastStroke = "—"
      root.lastAction = root.textInputActive ? "Waiting for text" : "Waiting for a key"
    }
  }

  Process {
    id: status
    environment: ({ATV_COMPONENT_PID: String(lifetime.processId)})
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.applyResult(JSON.parse(text.trim())) }
        catch (error) { root.lastError = "Could not read Apple TV status" }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop()
    }
    onExited: function(exitCode) {
      if (exitCode === 127) root.statusText = "Setup required"
      else if (exitCode !== 0 && root.connectionState === "connected") root.statusText = "Connection error"
    }
  }

  Timer {
    interval: 1000
    running: root.opened && !root.pairingVisible && !root.shortcutsVisible && root.nowPlaying.state === "Playing"
    repeat: true
    onTriggered: root.playbackClock = Date.now()
  }

  Timer {
    interval: 10000
    running: root.opened && !root.pairingVisible && !root.shortcutsVisible
    repeat: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    interval: 60000
    running: !root.pairingVisible && !root.shortcutsVisible
    repeat: true
    onTriggered: {
      root.discoveryCycle += 1
      root.refresh(root.networkScan && root.discoveryCycle % 5 === 0)
    }
  }

  Process { id: reconnect; environment: ({ATV_COMPONENT_PID: String(lifetime.processId)}) }

  Process {
    id: pairProcess
    environment: ({ATV_COMPONENT_PID: String(lifetime.processId)})
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var result = JSON.parse(line)
          root.pairingStep = result.event
          root.pairingMessage = result.message || ""
          if (result.event === "pin" || result.event === "password") {
            pairSecret.text = ""
            Qt.callLater(function() { pairSecret.forceActiveFocus() })
          }
          if (result.event === "done") {
            root.lastError = ""
            reconnect.command = [root.backend, pairAddress.text.trim(), "reconnect"]
            reconnect.running = true
            root.saveSettings({identifier: result.identifier})
          }
        } catch (error) { root.pairingMessage = "Could not read pairing progress" }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.pairingVisible && root.pairingStep !== "done" && root.pairingStep !== "error") {
        root.pairingStep = "error"
        root.pairingMessage = "Pairing stopped. Try again when the TV is ready."
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.activeDevice ? "Apple TV Remote · " + root.activeDevice.name : "Apple TV Remote"
    iconComponent: Component {
      RemoteIcon {
        anchors.centerIn: parent
        width: Style.space(24)
        height: Style.space(24)
        color: root.foreground
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.command("play_pause")
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
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      onActiveFocusChanged: if (!activeFocus) root.commandQueue = []
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (!root.opened || !keyCatcher.activeFocus) return
        if (root.shortcutsVisible) {
          if (root.capturingShortcut !== "") root.captureShortcut(event)
          else if (event.key === Qt.Key_Escape) root.shortcutsVisible = false
          event.accepted = true
          return
        }
        if (root.pairingVisible) {
          if (event.key === Qt.Key_Escape) { root.cancelPairing(); event.accepted = true }
          return
        }
        if (event.key === Qt.Key_Escape) root.close()
        else if (event.key === Qt.Key_Backspace && root.textInputActive) root.sendTextBackspace()
        else if (root.textInputActive && event.text && event.text.charCodeAt(0) >= 32
                 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) root.sendText(event.text)
        else {
          var key = event.key === Qt.Key_Enter ? Qt.Key_Return : event.key
          var modifiers = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier)
          var matched = false
          for (var action of root.shortcutActions) {
            var shortcut = root.shortcutFor(action)
            if (shortcut.key === key && shortcut.modifiers === modifiers) {
              root.sendStroke(shortcut.text, action.label, action.id)
              matched = true
              break
            }
          }
          if (!matched) return
        }
        event.accepted = true
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: root.activeDevice ? String(root.activeDevice.name) : "Apple TV"
          meta: root.shortcutsVisible ? "KEYBOARD SHORTCUTS" : root.pairingVisible ? "APPLE TV SETTINGS" : root.statusText.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
          trailingControl: Component {
            Column {
              visible: !root.pairingVisible && !root.shortcutsVisible
              width: Style.space(110)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.lastStroke !== "—" || root.typedPreview !== ""
                text: root.textInputActive && root.typedPreview !== "" ? root.displayedPreview() : root.lastStroke
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.lastAction
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
              }
            }
          }
          iconComponent: Component {
            RemoteIcon {
              width: Style.space(32)
              height: Style.space(32)
              color: root.foreground
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Column {
          visible: root.devices.length > 0 && !pairProcess.running && !root.shortcutsVisible
          width: parent.width
          spacing: Style.space(7)

          PanelSectionHeader {
            text: "APPLE TVs"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.devices
            Button {
              required property var modelData
              width: parent.width
              text: String(modelData.name) + (selected ? "  ·  " + (root.connectionState === "connected" ? "Connected" : "Selected") : "")
              tooltipText: String(modelData.name) + " · " + String(modelData.address)
              iconText: selected ? "✓" : "󰟴"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              selected: root.activeIdentifier === String(modelData.identifier)
              onClicked: root.selectDevice(modelData)
            }
          }
        }

        Column {
          visible: root.shortcutsVisible
          width: parent.width
          spacing: Style.space(7)
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.shortcutMessage
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.shortcutActions
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                width: parent.width * .44
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                width: parent.width * .56 - parent.spacing
                text: root.capturingShortcut === modelData.id ? "Press a key…" : root.shortcutLabel(modelData.id)
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                selected: root.capturingShortcut === modelData.id
                verticalPadding: Style.space(4)
                onClicked: { root.capturingShortcut = modelData.id; keyCatcher.forceActiveFocus() }
              }
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Restore defaults"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: { root.saveSettings({shortcuts: "{}"}); root.capturingShortcut = ""; root.shortcutMessage = "Defaults restored." }
            }
            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Done"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: { root.shortcutsVisible = false; root.capturingShortcut = ""; keyCatcher.forceActiveFocus() }
            }
          }
        }

        Column {
          visible: root.pairingVisible
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.pairingMessage
            color: root.pairingStep === "error" ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          TextField {
            id: pairAddress
            width: parent.width
            visible: !pairProcess.running && root.pairingStep !== "done"
            placeholderText: "Apple TV IP address"
            foreground: root.foreground
            font.family: root.fontFamily
            onAccepted: root.startPairing()
          }
          TextField {
            id: pairSecret
            width: parent.width
            visible: root.pairingStep === "pin" || root.pairingStep === "password"
            placeholderText: root.pairingStep === "pin" ? "Four-digit PIN" : "AirPlay password"
            echoMode: TextInput.Password
            foreground: root.foreground
            font.family: root.fontFamily
            onAccepted: root.submitPairing()
          }
          Button {
            width: parent.width
            visible: !pairProcess.running && root.pairingStep !== "done"
            text: root.pairingStep === "error" ? "Try pairing again" : root.connectionState === "connected" && pairAddress.text.trim() === root.activeAddress ? "Pair again" : "Start pairing"
            enabled: pairAddress.text.trim() !== ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.startPairing()
          }
          Button {
            width: parent.width
            visible: pairSecret.visible
            text: "Confirm"
            enabled: pairSecret.text.length > 0
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.submitPairing()
          }
          Button {
            width: parent.width
            text: root.pairingStep === "done" ? "Done" : "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.cancelPairing()
          }
        }

        Column {
          visible: !root.pairingVisible && !root.shortcutsVisible && !!root.nowPlaying.title
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: (root.nowPlaying.state === "Paused" ? "Paused · " : "Now playing · ") + (root.nowPlaying.title || "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            maximumLineCount: 2
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.playingDetails()
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            maximumLineCount: 3
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            visible: root.nowPlaying.duration > 0
            text: (root.mediaTime(root.playbackPosition) ? root.mediaTime(root.playbackPosition) + " / " : "") + root.mediaTime(root.nowPlaying.duration)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }


        PanelSeparator { visible: !root.pairingVisible && !root.shortcutsVisible; foreground: root.foreground }

        Column {
          visible: !root.pairingVisible && !root.shortcutsVisible
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(6)
            PanelSectionHeader {
              width: parent.width - shortcutCog.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: "KEYBOARD REMOTE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Button {
              id: shortcutCog
              iconText: "󰒓"
              tooltipText: "Customize keyboard shortcuts"
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(3)
              verticalPadding: Style.space(2)
              onClicked: {
                root.shortcutsVisible = true
                root.capturingShortcut = ""
                root.commandQueue = []
                root.shortcutMessage = "Choose an action, then press its new key. Escape cancels."
                keyCatcher.forceActiveFocus()
              }
            }
          }
          ShortcutRow { keys: ["left", "up", "down", "right"].map(function(id) { return root.shortcutLabel(id) }).join("  "); action: "Navigate" }
          ShortcutRow { keys: root.shortcutLabel("select"); action: "Select" }
          ShortcutRow { keys: root.shortcutLabel("menu"); action: "Back / Menu" }
          ShortcutRow { keys: root.shortcutLabel("play_pause"); action: "Play / Pause" }
          ShortcutRow { keys: root.shortcutLabel("home"); action: "Home" }
          ShortcutRow { keys: root.shortcutLabel("volume_down") + " / " + root.shortcutLabel("volume_up"); action: "Volume down / up" }
          ShortcutRow { keys: "Esc"; action: "Close remote" }

          Text {
            textFormat: Text.PlainText
            visible: root.textInputActive
            width: parent.width
            text: "Text field detected · printable keys and Backspace are sent directly"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.WordWrap
          }
        }


        Button {
          width: parent.width
          visible: !root.pairingVisible && !root.shortcutsVisible
          text: root.connectionState === "pairing" && root.activeDevice ? "Pair " + root.activeDevice.name : root.statusText === "Setup required" ? "Set up Apple TV" : "Manage Apple TV"
          iconText: "󰒓"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          active: true
          onClicked: root.setup()
        }

      }
    }
  }

  component ShortcutRow: Row {
    required property string keys
    required property string action
    width: parent.width
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      width: parent.width * 0.42
      text: keys
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width * 0.58 - parent.spacing
      text: action
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  component RemoteIcon: Item {
    id: remoteIcon
    property color color: root.foreground

    Rectangle {
      id: tintLayer
      anchors.fill: remoteSvg
      color: remoteIcon.color
      visible: false
      layer.enabled: true
    }

    Image {
      id: remoteSvg
      anchors.fill: parent
      source: root.pluginDir + "/assets/apple-tv.svg"
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.max(32, Math.round(width * 3))
      sourceSize.height: Math.max(32, Math.round(height * 3))
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: remoteSvg
      source: tintLayer
      maskEnabled: true
      maskSource: remoteSvg
      maskThresholdMin: 0.01
      maskSpreadAtMin: 0.01
    }
  }
}
