import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "IdleModel.js" as IdleModel

// Power-saving idle service in four stages, each with its own switch and
// timeout, grouped the way they are presented in the panel:
//   display: screensaver → standby (monitors off, DPMS)
//   system:  lock → sleep (suspend)
// Derived from Omarchy's omarchy.idle service, which only knows screensaver +
// lock and has no way to switch either off, and extended; Panel.qml is the bar
// widget that drives it. It replaces omarchy.idle, so this service disables the
// stock one on sight (once per shell session) rather than lock and launch the
// screensaver twice; re-enable it by hand and this service says it is paused.
//
// Nothing in Omarchy ever turns a monitor off: the lock screen's "blank" is
// `omarchy-brightness-display off` (backlight/DDC on the focused monitor), and
// the only DPMS keys in the defaults are the ones that switch monitors back
// *on* for input. So the standby stage drives Hyprland's dpms dispatcher
// itself. Hyprland 0.56 dropped the plain-string dispatch form ("dpms off" now
// parses as Lua), which is why it goes through `hyprctl eval`.
//
// Config lives in the `idle` block of ~/.config/omarchy/shell.json, keeping
// the stock keys with their stock meaning so omarchy.idle still reads them
// if this plugin is ever removed:
//   screensaver / lock / suspend   seconds since idle began (stock keys)
//   standby                        seconds since idle began (ours)
//   lockEnabled / suspendEnabled / standbyEnabled
//                                  booleans (defaults: true / false / false)
// The screensaver switch is Omarchy's own `screensaver-off` toggle
// (`omarchy toggle screensaver`), so the menu and the panel agree. "Stay
// awake" (`omarchy toggle idle`) pauses all three stages.
//
// Screensaver and lock share one IdleMonitor armed at the earliest enabled
// deadline and are staggered with timers, exactly as upstream does, because
// locking ends that cycle (the lock plugin owns the screen from then on).
// Standby and suspend get an IdleMonitor each so they survive the lock and fire
// on the wall-clock idle time regardless of what the other stages did.
// NOTE: after editing this file run `omarchy restart shell` — the hot reload
// re-instantiates but keeps the old compiled QML.
Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stayAwakeStateDir: home + "/.local/state/omarchy/indicators"
  readonly property string stayAwakeStatePath: stayAwakeStateDir + "/stay-awake"
  readonly property string togglesDir: home + "/.local/state/omarchy/toggles"
  readonly property int defaultScreensaverSeconds: 150
  readonly property int defaultLockSeconds: 300
  readonly property int defaultStandbySeconds: 600
  readonly property int defaultSuspendSeconds: 1800
  readonly property int minTimeoutSeconds: 10
  readonly property var idleConfig: shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : ({})
  readonly property int screensaverTimeoutSeconds: secondsFromConfig(idleConfig.screensaver, defaultScreensaverSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(idleConfig.lock, defaultLockSeconds)
  readonly property int standbyTimeoutSeconds: secondsFromConfig(idleConfig.standby, defaultStandbySeconds)
  readonly property int suspendTimeoutSeconds: secondsFromConfig(idleConfig.suspend, defaultSuspendSeconds)
  readonly property bool lockEnabled: IdleModel.boolFromConfig(idleConfig.lockEnabled, true)
  readonly property bool standbyEnabled: IdleModel.boolFromConfig(idleConfig.standbyEnabled, false)
  readonly property bool suspendEnabled: IdleModel.boolFromConfig(idleConfig.suspendEnabled, false)
  readonly property bool screensaverEnabled: screensaverToggleLoaded && !screensaverOff
  readonly property int firstIdleTimeoutSeconds: IdleModel.firstTimeout(screensaverEnabled, screensaverTimeoutSeconds, lockEnabled, lockTimeoutSeconds)
  readonly property int screensaverDelaySeconds: Math.max(0, screensaverTimeoutSeconds - firstIdleTimeoutSeconds)
  readonly property int lockDelaySeconds: Math.max(0, lockTimeoutSeconds - firstIdleTimeoutSeconds)
  // Re-evaluated on every registry change (registryRevision is the tick).
  readonly property bool stockIdleEnabled: {
    if (!shell || !shell.pluginRegistry) return false
    var revision = shell.pluginRegistry.registryRevision
    return shell.pluginRegistry.isEnabled("omarchy.idle") === true
  }
  readonly property bool idleEnabled: stayAwakeStateLoaded && !stayAwake && !stockIdleEnabled
  readonly property bool cycleEnabled: idleEnabled && (screensaverEnabled || lockEnabled)
  readonly property bool standbyArmed: idleEnabled && standbyEnabled
  readonly property bool suspendArmed: idleEnabled && suspendEnabled
  readonly property string screensaverClass: "org.omarchy.screensaver"
  property var cycleMonitor: null
  property var standbyMonitor: null
  property var suspendMonitor: null
  readonly property bool cycleIdle: cycleMonitor ? cycleMonitor.isIdle : false
  readonly property bool standbyIdle: standbyMonitor ? standbyMonitor.isIdle : false
  readonly property bool suspendIdle: suspendMonitor ? suspendMonitor.isIdle : false

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property bool hasPendingStayAwakePersist: false
  property bool pendingStayAwakePersist: false
  property bool screensaverOff: false
  property bool screensaverToggleLoaded: false
  property bool idledThisCycle: false
  property bool screensaverStartedThisCycle: false
  property bool standbyActive: false
  property bool autoDisabledStockIdle: false
  property string lastEvent: "starting"
  property string lastEventAt: ""
  property string lastStandbyAt: ""
  property string lastSuspendAt: ""
  property var screensaverWindows: ({})
  property int screensaverWindowCount: 0

  function secondsFromConfig(value, fallback) {
    return IdleModel.secondsFromConfig(value, fallback)
  }

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = nowIso()
    root.lastEvent = event + suffix
    console.log("omarchy idle " + root.lastEventAt + " " + root.lastEvent)
  }

  function runProcess(process, label, command) {
    if (process.running) {
      logEvent("process-skip", label + " already running")
      return false
    }
    logEvent("process-start", label + " " + command)
    process.command = ["bash", "-lc", command]
    process.running = true
    return true
  }

  // ------------------------------------------------------ screensaver/lock

  function launchScreensaver() {
    root.screensaverStartedThisCycle = true
    screensaverLaunchGraceTimer.restart()
    runProcess(screensaverProcess, "screensaver", "[[ $(omarchy-shell lock isLocked 2>/dev/null) == \"true\" ]] || omarchy-launch-screensaver")
  }

  function lockSystem(reason) {
    logEvent("lock-system", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    screensaverLaunchGraceTimer.stop()
    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
    resetScreensaverWindows()
    runProcess(lockProcess, "lock", "omarchy-system-lock")
  }

  function startIdleCycle() {
    if (root.idledThisCycle) {
      logEvent("idle-cycle-already-running")
      return
    }

    logEvent("idle-cycle-start", "screensaver=" + (root.screensaverEnabled ? root.screensaverTimeoutSeconds : "off")
      + " lock=" + (root.lockEnabled ? root.lockTimeoutSeconds : "off"))
    root.idledThisCycle = true
    root.screensaverStartedThisCycle = false
    resetScreensaverWindows()

    if (root.screensaverEnabled) {
      if (root.screensaverDelaySeconds === 0) launchScreensaver()
      else screensaverTimer.restart()
    }

    if (root.lockEnabled) {
      if (root.lockDelaySeconds === 0) lockSystem("lock-timeout-immediate")
      else lockTimer.restart()
    }
  }

  function cancelIdleCycle(reason) {
    logEvent("idle-cycle-cancel", reason || "requested")
    screensaverTimer.stop()
    lockTimer.stop()
    screensaverLaunchGraceTimer.stop()

    if (root.idledThisCycle) runProcess(wakeProcess, "wake", "omarchy-system-wake")

    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
    resetScreensaverWindows()
  }

  function resetScreensaverWindows() {
    root.screensaverWindows = ({})
    root.screensaverWindowCount = 0
  }

  function setScreensaverWindow(address, visible) {
    var next = IdleModel.screensaverWindowsAfter(root.screensaverWindows, address, visible)
    root.screensaverWindows = next.windows
    root.screensaverWindowCount = next.count
  }

  function handleScreensaverWindowOpened(address) {
    setScreensaverWindow(address, true)
    screensaverLaunchGraceTimer.stop()
  }

  function handleScreensaverWindowClosed(address) {
    setScreensaverWindow(address, false)

    if (!root.cycleEnabled || !root.idledThisCycle || !root.screensaverStartedThisCycle) return
    if (root.screensaverWindowCount > 0) return

    // The user dismissed the screensaver before the lock deadline. Treat that
    // as activity and cancel the pending lock; the lock timer is only allowed
    // to fire while the screensaver remains up.
    root.cancelIdleCycle("screensaver-dismissed")
  }

  function eventParts(event, count) {
    return IdleModel.eventParts(event, count)
  }

  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name === "openwindow") {
      var open = eventParts(event, 4)
      if (String(open[2] || "") === root.screensaverClass) root.handleScreensaverWindowOpened(open[0])
    } else if (name === "closewindow") {
      var close = eventParts(event, 1)
      var address = String(close[0] || "")
      if (root.screensaverWindows[address]) root.handleScreensaverWindowClosed(address)
    }
  }

  function handleActiveSignal() {
    if (!root.idledThisCycle) return

    // Starting the screensaver can make the compositor report activity. Keep
    // the lock timer running once the screensaver exists (or during its short
    // launch grace); Hyprland window events cancel the cycle if it exits before
    // the normal lock deadline.
    if (root.screensaverStartedThisCycle && (root.screensaverWindowCount > 0 || screensaverLaunchGraceTimer.running)) {
      logEvent("idle-monitor-active", "screensaver cycle remains armed")
      return
    }

    cancelIdleCycle("activity")
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", root.cycleIdle ? "idle" : "active")
    if (!root.cycleEnabled) return

    if (root.cycleIdle) startIdleCycle()
    else handleActiveSignal()
  }

  // --------------------------------------------------------------- standby

  // `hyprctl dispatch dpms off` is gone on Hyprland 0.56 (the argument is
  // parsed as Lua), so the dispatcher is reached through hl.dsp. The action
  // MUST be passed as `{action = "off"}`: hl.dsp.dpms("off"), and every other
  // shape tried, builds a valid dispatcher whose argument is then ignored, and
  // the dispatch *toggles* — verified against /sys/class/drm/*/dpms, which is
  // also the only trustworthy read of the state (`hyprctl monitors` reports
  // dpmsStatus a dispatch behind). A toggle would be silently wrong here: two
  // stages racing, or a lost wake, would leave the desktop dark. With `action`
  // the dispatch is idempotent, so a redundant "on" costs nothing.
  //
  // Monitors also come back on their own on key press or mouse move —
  // misc.key_press_enables_dpms and misc.mouse_move_enables_dpms are on in
  // Omarchy's defaults — but a wake from anywhere else would leave a black
  // desktop, so activity turns them on explicitly too. Off and on run in their
  // own processes: a still-running "off" must never make the "on" that follows
  // it a no-op.
  readonly property string dpmsOffCommand: "hyprctl eval 'hl.dispatch(hl.dsp.dpms({action = \"off\"}))'"
  readonly property string dpmsOnCommand: "hyprctl eval 'hl.dispatch(hl.dsp.dpms({action = \"on\"}))'"

  function standbyDisplays(reason) {
    if (root.standbyActive) return
    root.standbyActive = true
    root.lastStandbyAt = nowIso()
    logEvent("standby", "displays off (" + (reason || "requested") + ")")
    runProcess(standbyOffProcess, "standby-off", root.dpmsOffCommand)
  }

  // The screensaver is deliberately left running: a monitor in DPMS off gets no
  // frames, so its Wayland client throttles itself, and killing it would look
  // like the user dismissed it and cancel a pending lock.
  function wakeDisplays(reason) {
    if (!root.standbyActive) return
    root.standbyActive = false
    logEvent("standby", "displays on (" + (reason || "requested") + ")")
    runProcess(standbyOnProcess, "standby-on", root.dpmsOnCommand)
  }

  function handleStandbyIdleChanged() {
    logEvent("standby-monitor", root.standbyIdle ? "idle" : "active")
    if (root.standbyIdle) {
      if (root.standbyArmed) standbyDisplays("standby-timeout")
      return
    }
    wakeDisplays("activity")
  }

  // --------------------------------------------------------------- suspend

  function suspendSystem(reason) {
    logEvent("suspend-system", reason || "requested")
    root.lastSuspendAt = nowIso()
    // Resume must not land on monitors this service left in DPMS off: the
    // machine would look dead until something happened to poke them.
    wakeDisplays("suspend")
    // omarchy-sleep-lock.service locks the session on PrepareForSleep, so no
    // lock call is needed here. logind refuses while a sleep inhibitor is
    // held; the exit code lands in the log either way.
    runProcess(suspendProcess, "suspend", "systemctl suspend")
  }

  function handleSuspendIdleChanged() {
    logEvent("suspend-monitor", root.suspendIdle ? "idle" : "active")
    if (!root.suspendIdle || !root.suspendArmed) return
    suspendSystem("suspend-timeout")
  }

  // ------------------------------------------------------------ status/IPC

  function stageEnabled(name) {
    if (name === "screensaver") return root.screensaverEnabled
    if (name === "standby") return root.standbyEnabled
    if (name === "lock") return root.lockEnabled
    if (name === "suspend") return root.suspendEnabled
    return false
  }

  function stageTimeout(name) {
    if (name === "screensaver") return root.screensaverTimeoutSeconds
    if (name === "standby") return root.standbyTimeoutSeconds
    if (name === "lock") return root.lockTimeoutSeconds
    if (name === "suspend") return root.suspendTimeoutSeconds
    return 0
  }

  function stageJson(name) {
    return { enabled: stageEnabled(name), timeout: stageTimeout(name) }
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.idleEnabled,
      stayAwake: root.stayAwake,
      stockIdleEnabled: root.stockIdleEnabled,
      stayAwakeStateLoaded: root.stayAwakeStateLoaded,
      stayAwakeStatePath: root.stayAwakeStatePath,
      stages: {
        screensaver: stageJson("screensaver"),
        standby: stageJson("standby"),
        lock: stageJson("lock"),
        suspend: stageJson("suspend")
      },
      idle: root.cycleIdle,
      standbyIdle: root.standbyIdle,
      standbyActive: root.standbyActive,
      suspendIdle: root.suspendIdle,
      inIdleCycle: root.idledThisCycle,
      screensaverStarted: root.screensaverStartedThisCycle,
      firstTimeout: root.firstIdleTimeoutSeconds,
      screensaverDelay: root.screensaverDelaySeconds,
      lockDelay: root.lockDelaySeconds,
      screensaverWindows: root.screensaverWindowCount,
      monitors: {
        cycle: root.cycleMonitor !== null,
        cycleTimeout: root.cycleMonitor ? root.cycleMonitor.timeout : null,
        standby: root.standbyMonitor !== null,
        standbyTimeout: root.standbyMonitor ? root.standbyMonitor.timeout : null,
        suspend: root.suspendMonitor !== null,
        suspendTimeout: root.suspendMonitor ? root.suspendMonitor.timeout : null
      },
      timers: {
        screensaver: screensaverTimer.running,
        lock: lockTimer.running,
        screensaverLaunchGrace: screensaverLaunchGraceTimer.running
      },
      processes: {
        screensaver: screensaverProcess.running,
        lock: lockProcess.running,
        wake: wakeProcess.running,
        standbyOff: standbyOffProcess.running,
        standbyOn: standbyOnProcess.running,
        suspend: suspendProcess.running
      },
      lastStandbyAt: root.lastStandbyAt,
      lastSuspendAt: root.lastSuspendAt,
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt
    })
  }

  // ---------------------------------------------------------- persistence

  // Writes go through the shell's own shell.json writer; the new config is
  // pushed back into `idleConfig`, which is what re-arms the monitors.
  function mutateIdleConfig(label, mutate) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") {
      logEvent("config-write-skipped", label + " (no shell)")
      return false
    }
    root.shell.mutateShellConfig(function(config) {
      if (!config.idle || typeof config.idle !== "object" || Array.isArray(config.idle)) config.idle = {}
      mutate(config.idle)
    })
    logEvent("config", label)
    return true
  }

  function setStageTimeout(name, seconds) {
    if (!IdleModel.isStage(name)) return false
    var n = Math.floor(Number(seconds))
    if (!isFinite(n) || n < root.minTimeoutSeconds) return false
    return mutateIdleConfig(name + "=" + n, function(idle) { idle[name] = n })
  }

  function setStageEnabled(name, value) {
    var enabled = !!value
    if (name === "screensaver") {
      if (root.screensaverToggleLoaded && root.screensaverEnabled === enabled) return true
      root.screensaverOff = !enabled
      root.screensaverToggleLoaded = true
      logEvent("stage", "screensaver " + (enabled ? "on" : "off"))
      screensaverToggleWriter.command = ["omarchy-toggle", "screensaver-off", enabled ? "off" : "on"]
      screensaverToggleWriter.running = true
      return true
    }
    if (name === "standby") {
      if (root.standbyEnabled === enabled) return true
      return mutateIdleConfig("standby " + (enabled ? "on" : "off"), function(idle) { idle.standbyEnabled = enabled })
    }
    if (name === "lock") {
      if (root.lockEnabled === enabled) return true
      return mutateIdleConfig("lock " + (enabled ? "on" : "off"), function(idle) { idle.lockEnabled = enabled })
    }
    if (name === "suspend") {
      if (root.suspendEnabled === enabled) return true
      return mutateIdleConfig("suspend " + (enabled ? "on" : "off"), function(idle) { idle.suspendEnabled = enabled })
    }
    return false
  }

  function persistStayAwake(value) {
    var command = value
      ? "mkdir -p \"$HOME/.local/state/omarchy/indicators\" && touch \"$HOME/.local/state/omarchy/indicators/stay-awake\""
      : "rm -f \"$HOME/.local/state/omarchy/indicators/stay-awake\""

    if (stayAwakeStateWriter.running) {
      root.pendingStayAwakePersist = !!value
      root.hasPendingStayAwakePersist = true
      return
    }

    stayAwakeStateWriter.command = ["bash", "-lc", command]
    stayAwakeStateWriter.running = true
  }

  function refreshStayAwakeState() {
    if (!stayAwakeStateProbe.running) stayAwakeStateProbe.running = true
  }

  function refreshScreensaverToggle() {
    if (!screensaverToggleProbe.running) screensaverToggleProbe.running = true
  }

  function applyScreensaverOff(value, reason) {
    var off = !!value
    var changed = !root.screensaverToggleLoaded || root.screensaverOff !== off
    root.screensaverOff = off
    root.screensaverToggleLoaded = true
    if (changed) logEvent("screensaver-toggle", (off ? "off" : "on") + (reason ? " " + reason : ""))
  }

  function applyStayAwake(value, persist, reason) {
    var enabled = !!value
    var changed = !root.stayAwakeStateLoaded || root.stayAwake !== enabled

    if (persist) persistStayAwake(enabled)

    root.stayAwake = enabled
    root.stayAwakeStateLoaded = true

    if (!changed) return enabled ? "disabled" : "enabled"

    logEvent("stay-awake", (enabled ? "enabled" : "disabled") + (reason ? " " + reason : ""))
    if (enabled) {
      cancelIdleCycle("stay-awake")
      wakeDisplays("stay-awake")
    }
    else Qt.callLater(root.handleIdleChanged)

    return enabled ? "disabled" : "enabled"
  }

  // This plugin replaces omarchy.idle, so enabling it is the whole consent
  // needed to switch the stock service off — one `omarchy plugin add … --enable`
  // is the entire installation. Done once per shell session: a user who
  // deliberately re-enables the stock service afterwards gets the notice and
  // this one stays paused instead of fighting them for the setting.
  function handleStockIdle() {
    if (root.autoDisabledStockIdle) {
      logEvent("stock-idle-enabled", "paused until omarchy.idle is disabled")
      runProcess(notifyProcess, "notify",
        "omarchy-notification-send -g 󰒲 'Power Saving is paused' 'The stock idle service is on again: omarchy plugin disable omarchy.idle'")
      return
    }

    root.autoDisabledStockIdle = true
    logEvent("stock-idle-enabled", "disabling omarchy.idle")
    runProcess(stockIdleDisableProcess, "disable-stock-idle",
      "omarchy-shell shell setPluginEnabled omarchy.idle false")
  }

  onStockIdleEnabledChanged: if (stockIdleEnabled) handleStockIdle()

  function setIdleEnabled(value) {
    return applyStayAwake(!value, true, "ipc")
  }

  // ------------------------------------------------------------- monitors

  // Quickshell 0.3.1 bug: when an IdleMonitor's timeout (or enabled) changes
  // it destroys and recreates its ext_idle_notification in place, and when the
  // allocator hands the new one the old address the isIdle binding sees no
  // change and keeps watching the dead object — the monitor never fires again
  // (verified standalone: Hyprland logs "marked idle", QML isIdle stays
  // false). So a monitor is never reconfigured here: every enabled/timeout
  // combination is a brand-new IdleMonitor with the timeout set at creation,
  // and the previous one is retired and destroyed.
  Component {
    id: monitorComponent

    IdleMonitor {
      // "cycle" (screensaver + lock) or "suspend"; "retired" once replaced so
      // a signal from a monitor awaiting deletion cannot reach a handler.
      property string stage: ""
      respectInhibitors: true
      onIsIdleChanged: {
        if (stage === "cycle") root.handleIdleChanged()
        else if (stage === "standby") root.handleStandbyIdleChanged()
        else if (stage === "suspend") root.handleSuspendIdleChanged()
      }
    }
  }

  function armMonitor(current, wanted, timeoutSeconds, stage) {
    if (current) {
      if (wanted && current.timeout === timeoutSeconds) return current
      current.stage = "retired"
      current.destroy()
      logEvent("monitor-disarm", stage)
    }
    if (!wanted) return null
    var monitor = monitorComponent.createObject(root, { stage: stage, timeout: timeoutSeconds })
    if (!monitor) {
      logEvent("monitor-arm-failed", stage + " timeout=" + timeoutSeconds)
      return null
    }
    logEvent("monitor-arm", stage + " timeout=" + timeoutSeconds)
    return monitor
  }

  function syncMonitors() {
    var previousCycle = root.cycleMonitor
    root.cycleMonitor = armMonitor(root.cycleMonitor, root.cycleEnabled, root.firstIdleTimeoutSeconds, "cycle")
    root.standbyMonitor = armMonitor(root.standbyMonitor, root.standbyArmed, root.standbyTimeoutSeconds, "standby")
    root.suspendMonitor = armMonitor(root.suspendMonitor, root.suspendArmed, root.suspendTimeoutSeconds, "suspend")
    // A cycle that was started by a monitor that no longer exists has nothing
    // to end it on activity; drop it and let the new monitor start afresh.
    if (root.idledThisCycle && root.cycleMonitor !== previousCycle) cancelIdleCycle("monitor-rearm")
  }

  onCycleEnabledChanged: syncMonitors()
  onFirstIdleTimeoutSecondsChanged: syncMonitors()
  // Switching standby off (or pausing it) with the monitors already dark would
  // leave nothing armed to wake them: bring them back first.
  onStandbyArmedChanged: {
    if (!standbyArmed) wakeDisplays("standby-disarmed")
    syncMonitors()
  }
  onStandbyTimeoutSecondsChanged: syncMonitors()
  onSuspendArmedChanged: syncMonitors()
  onSuspendTimeoutSecondsChanged: syncMonitors()

  Timer {
    id: screensaverTimer
    interval: root.screensaverDelaySeconds * 1000
    repeat: false
    onTriggered: if (root.cycleEnabled && root.screensaverEnabled && root.idledThisCycle) root.launchScreensaver()
  }

  Timer {
    id: lockTimer
    interval: root.lockDelaySeconds * 1000
    repeat: false
    onTriggered: if (root.cycleEnabled && root.lockEnabled && root.idledThisCycle) root.lockSystem("lock-timeout")
  }

  Timer {
    id: screensaverLaunchGraceTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (root.cycleEnabled && root.idledThisCycle && root.screensaverStartedThisCycle && root.screensaverWindowCount === 0 && !root.cycleIdle) {
        root.cancelIdleCycle("screensaver-not-running")
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  // ------------------------------------------------------------ processes

  Process {
    id: screensaverProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "screensaver exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: lockProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "lock exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: wakeProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "wake exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: notifyProcess
  }
  Process {
    id: standbyOffProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "standby-off exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: standbyOnProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "standby-on exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: stockIdleDisableProcess
    onExited: function(exitCode, exitStatus) {
      root.logEvent("process-exit", "disable-stock-idle exitCode=" + exitCode + " status=" + exitStatus)
      if (exitCode === 0) {
        root.runProcess(notifyProcess, "notify",
          "omarchy-notification-send -g 󰒲 'Power Saving is on' 'The stock idle service (omarchy.idle) was disabled; this plugin replaces it.'")
      } else {
        root.runProcess(notifyProcess, "notify",
          "omarchy-notification-send -g 󰒲 'Power Saving is paused' 'Could not disable the stock idle service: omarchy plugin disable omarchy.idle'")
      }
    }
  }
  Process {
    id: suspendProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "suspend exitCode=" + exitCode + " status=" + exitStatus) }
  }

  Process {
    id: stayAwakeStateProbe
    command: ["bash", "-c", "mkdir -p \"$HOME/.local/state/omarchy/indicators\"; if [[ -f $HOME/.local/state/omarchy/indicators/stay-awake ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyStayAwake(String(line).trim() === "yes", false, "state-file") }
    }
    onExited: function() { stayAwakeStateDirWatcher.reload() }
  }

  Process {
    id: stayAwakeStateWriter
    onExited: function() {
      if (root.hasPendingStayAwakePersist) {
        var pending = root.pendingStayAwakePersist
        root.hasPendingStayAwakePersist = false
        root.persistStayAwake(pending)
        return
      }

      root.refreshStayAwakeState()
    }
  }

  FileView {
    id: stayAwakeStateDirWatcher
    path: root.stayAwakeStateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshStayAwakeState()
  }

  // The screensaver switch is Omarchy's own toggle flag, watched so the
  // menu's "Toggle screensaver" and this service never disagree.
  Process {
    id: screensaverToggleProbe
    command: ["bash", "-c", "mkdir -p \"$HOME/.local/state/omarchy/toggles\"; if [[ -f $HOME/.local/state/omarchy/toggles/screensaver-off ]]; then echo yes; else echo no; fi"]
    stdout: SplitParser {
      onRead: function(line) { root.applyScreensaverOff(String(line).trim() === "yes", "toggle-file") }
    }
    onExited: function() { togglesDirWatcher.reload() }
  }

  Process {
    id: screensaverToggleWriter
    onExited: function() { root.refreshScreensaverToggle() }
  }

  FileView {
    id: togglesDirWatcher
    path: root.togglesDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshScreensaverToggle()
  }

  Component.onCompleted: {
    logEvent("service-ready")
    if (stockIdleEnabled) handleStockIdle()
    syncMonitors()
    refreshStayAwakeState()
    refreshScreensaverToggle()
  }

  // Same target as omarchy.idle so `omarchy-shell idle …` keeps working.
  IpcHandler {
    target: "idle"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }

    function enable(): string {
      return root.setIdleEnabled(true)
    }

    function disable(): string {
      return root.setIdleEnabled(false)
    }

    function toggle(): string {
      return root.setIdleEnabled(!root.idleEnabled)
    }

    // omarchy-shell idle stage <screensaver|lock|suspend> [on|off|toggle|status]
    function stage(name: string, action: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      var act = String(action || "status")
      if (act === "on" || act === "off") root.setStageEnabled(name, act === "on")
      else if (act === "toggle") root.setStageEnabled(name, !root.stageEnabled(name))
      else if (act !== "status") return "unknown action: " + act
      return root.stageEnabled(name) ? "on" : "off"
    }

    // omarchy-shell idle timeout <screensaver|lock|suspend> [seconds]
    function timeout(name: string, seconds: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      if (String(seconds || "") === "") return String(root.stageTimeout(name))
      return root.setStageTimeout(name, seconds) ? "ok" : "invalid timeout (min " + root.minTimeoutSeconds + " s)"
    }

    function suspend(): string {
      root.suspendSystem("ipc")
      return "ok"
    }

    // omarchy-shell idle standby  → monitors off now
    // omarchy-shell idle wake     → and back on
    function standby(): string {
      root.standbyDisplays("ipc")
      return "ok"
    }

    function wake(): string {
      root.wakeDisplays("ipc")
      return "ok"
    }
  }
}
