import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "IdleModel.js" as IdleModel

// Power-saving idle service in four stages, each with its own switch and
// timeout, grouped the way they are presented in the panel:
//   display: screensaver → standby (monitors off, DPMS)
//   system:  lock → suspend
// Derived from Omarchy's omarchy.idle service, which only knows screensaver +
// lock and has no way to switch either off, and extended; Panel.qml is the bar
// widget that drives it. It replaces omarchy.idle: the manifest declares it a
// clone of that service, so enabling this plugin has the host switch the stock
// one off and removing it brings the stock one back. On hosts without that
// clone handling (before Omarchy 4.0.3) this service still disables the stock
// one on sight (once per shell session) rather than lock and launch the
// screensaver twice; re-enable it by hand and this service says it is paused.
//
// Nothing in Omarchy ever turns a monitor off: the lock screen's "blank" is
// `omarchy-brightness-display off` (backlight/DDC on the focused monitor), and
// the only DPMS keys in the defaults are the ones that switch monitors back
// *on* for input. So the standby stage drives Hyprland's dpms dispatcher
// itself. Hyprland 0.56 dropped the plain-string dispatch form ("dpms off" now
// parses as Lua), which is why it goes through `hyprctl eval`.
//
// Config is stored inline on this plugin's bar entry in
// ~/.config/omarchy/shell.json (`omarchy bar set io.github.selfcrypto.power-saving
// suspend 1200` writes the same keys). That is the one place a third-party
// plugin may write since Omarchy 4.0.3 scoped the shell object handed to
// plugins (`mutateShellConfig` is reserved for full-bar plugins there). Keys
// missing from the entry fall back to the stock `idle` block, which the host
// shares with this plugin because it is a clone of omarchy.idle
// (`shell.idleConfig`), so an older install migrates on its first write:
//   screensaver / lock / suspend   seconds since idle began (stock keys)
//   standby                        seconds since idle began (ours)
//   lockEnabled / suspendEnabled / standbyEnabled
//                                  booleans (defaults: true / false / false)
// The screensaver switch is Omarchy's own `screensaver-off` toggle
// (`omarchy toggle screensaver`), so the menu and the panel agree. "Stay
// awake" (`omarchy toggle idle`) pauses all four stages.
//
// Screensaver and lock share one IdleMonitor armed at the earliest enabled
// deadline and are staggered with timers, exactly as upstream does, because
// locking ends that cycle (the lock plugin owns the screen from then on).
// Standby and suspend get an IdleMonitor each, so each can be the first to
// see the user go idle. Once that is known they run on timers counted from
// that moment (see the away section), because the compositor resets the
// monitors whenever this service opens or closes the screensaver or locks.
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
  readonly property string pluginId: "io.github.selfcrypto.power-saving"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  // shell.json as read from disk (null until loaded or when there is none).
  // The host does hand plugins `barConfig` / `idleConfig` snapshots, but in
  // Omarchy 4.0.3 it refreshes them inside its own config-change handler,
  // before the derived `barConfig` binding has caught up, so a plugin sees
  // its own write only at the next config event. Watching the file the way
  // the host itself does is what makes a panel edit take effect at once.
  property var fileConfig: null
  // Stock `idle` block: the file first, then whatever the host hands over
  // (the trusted shell on older hosts, the clone snapshot `shell.idleConfig`
  // on 4.0.3+). Read-only here: the fallback for keys the bar entry lacks.
  readonly property var idleConfig: fileConfig && IdleModel.isObject(fileConfig.idle) ? fileConfig.idle
    : (shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle
    : (shell && shell.idleConfig ? shell.idleConfig : ({})))
  // This plugin's own settings, inline on its bar entry in the layout.
  readonly property var entrySettings: IdleModel.barEntrySettings(
    fileConfig && IdleModel.isObject(fileConfig.bar) ? fileConfig.bar : (shell ? shell.barConfig : null), pluginId)
  readonly property var stageConfig: IdleModel.mergedStageConfig(entrySettings, idleConfig)
  readonly property int screensaverTimeoutSeconds: secondsFromConfig(stageConfig.screensaver, defaultScreensaverSeconds)
  readonly property int lockTimeoutSeconds: secondsFromConfig(stageConfig.lock, defaultLockSeconds)
  readonly property int standbyTimeoutSeconds: secondsFromConfig(stageConfig.standby, defaultStandbySeconds)
  readonly property int suspendTimeoutSeconds: secondsFromConfig(stageConfig.suspend, defaultSuspendSeconds)
  readonly property bool lockEnabled: IdleModel.boolFromConfig(stageConfig.lockEnabled, true)
  readonly property bool standbyEnabled: IdleModel.boolFromConfig(stageConfig.standbyEnabled, false)
  readonly property bool suspendEnabled: IdleModel.boolFromConfig(stageConfig.suspendEnabled, false)
  readonly property bool screensaverEnabled: screensaverToggleLoaded && !screensaverOff
  readonly property int firstIdleTimeoutSeconds: IdleModel.firstTimeout(screensaverEnabled, screensaverTimeoutSeconds, lockEnabled, lockTimeoutSeconds)
  readonly property int screensaverDelaySeconds: Math.max(0, screensaverTimeoutSeconds - firstIdleTimeoutSeconds)
  readonly property int lockDelaySeconds: Math.max(0, lockTimeoutSeconds - firstIdleTimeoutSeconds)
  // Only a host that hands this service the real registry (before Omarchy
  // 4.0.3) can answer this; from 4.0.3 the scoped shell carries no registry and
  // the host itself keeps omarchy.idle off while its clone is enabled, so this
  // stays false there. Re-evaluated on every registry change (registryRevision
  // is the tick).
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
  property var watchMonitor: null
  readonly property bool cycleIdle: cycleMonitor ? cycleMonitor.isIdle : false
  readonly property bool standbyIdle: standbyMonitor ? standbyMonitor.isIdle : false
  readonly property bool suspendIdle: suspendMonitor ? suspendMonitor.isIdle : false
  readonly property bool watchIdle: watchMonitor ? watchMonitor.isIdle : false

  property bool stayAwake: false
  property bool stayAwakeStateLoaded: false
  property bool hasPendingStayAwakePersist: false
  property bool pendingStayAwakePersist: false
  property bool screensaverOff: false
  property bool screensaverToggleLoaded: false
  property bool idledThisCycle: false
  property bool screensaverStartedThisCycle: false
  // "Away": the stretch from the moment the user went idle (awaySince, epoch
  // ms, 0 when they are here) until they touch something again. See the away
  // section below.
  property double awaySince: 0
  readonly property bool away: awaySince > 0
  property bool cycleDoneThisAway: false
  property bool standbyFiredThisAway: false
  property bool suspendFiredThisAway: false
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

  // Never onto dark monitors. A DisplayPort monitor in DPMS off can drop its
  // link and be reported unplugged: Hyprland then removes it, so a screensaver
  // started meanwhile opens into a one-monitor layout, and when the monitor
  // returns on input the window is carried back with a stale input box —
  // painted over the whole monitor, clicks falling through to the desktop.
  // Nothing is lost by skipping it: the input that wakes the monitors ends
  // the cycle anyway, and the lock stage keeps its own timer. The state is
  // read from sysfs at launch time (the one honest read, see standby below):
  // standbyActive only remembers this service's last dispatch, and Hyprland
  // wakes the monitors on input without telling anyone.
  // A connector without a readable dpms attribute counts as on, and so does
  // a system that exposes no connected connector at all: when the state
  // cannot be read the screensaver launches as it always did.
  readonly property string displaysOnCheck: "on=0 seen=0; for c in /sys/class/drm/card*-*; do [[ -r $c/status && $(<$c/status) == connected ]] || continue; seen=1; [[ -r $c/dpms && $(<$c/dpms) != On ]] || on=1; done; ((seen && !on)) && exit 3"
  readonly property int screensaverSkippedExitCode: 3

  function launchScreensaver() {
    root.screensaverStartedThisCycle = true
    screensaverLaunchGraceTimer.restart()
    markOwnAction()
    runProcess(screensaverProcess, "screensaver", root.displaysOnCheck
      + "; [[ $(omarchy-shell lock isLocked 2>/dev/null) == \"true\" ]] || omarchy-launch-screensaver")
  }

  // The screensaver on request (panel, IPC), outside any idle cycle: "force"
  // starts it with the stage switched off too. An idle cycle that begins
  // while it is still up adopts it — omarchy-launch-screensaver exits early
  // when one is running, and its windows are already tracked.
  function startScreensaver(reason) {
    logEvent("screensaver-now", reason || "requested")
    markOwnAction()
    runProcess(screensaverProcess, "screensaver", root.displaysOnCheck + "; omarchy-launch-screensaver force")
  }

  function handleScreensaverLaunchExit(exitCode) {
    if (exitCode !== root.screensaverSkippedExitCode) return
    logEvent("screensaver-skip", "displays off")
    screensaverLaunchGraceTimer.stop()
    root.screensaverStartedThisCycle = false
  }

  // Ends the screensaver/lock cycle without treating it as activity: no
  // omarchy-system-wake, and a screensaver window closing afterwards is
  // ignored because idledThisCycle is already false.
  function endIdleCycle() {
    screensaverTimer.stop()
    lockTimer.stop()
    screensaverLaunchGraceTimer.stop()
    root.idledThisCycle = false
    root.screensaverStartedThisCycle = false
    resetScreensaverWindows()
  }

  function lockSystem(reason) {
    logEvent("lock-system", reason || "requested")
    endIdleCycle()
    root.cycleDoneThisAway = root.away
    markOwnAction()
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
    // The tracked windows are kept: a screensaver started by hand may be up.

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
    syncWatchMonitor()
  }

  function setScreensaverWindow(address, visible) {
    var next = IdleModel.screensaverWindowsAfter(root.screensaverWindows, address, visible)
    root.screensaverWindows = next.windows
    root.screensaverWindowCount = next.count
    syncWatchMonitor()
  }

  function handleScreensaverWindowOpened(address) {
    markOwnAction()
    setScreensaverWindow(address, true)
    screensaverLaunchGraceTimer.stop()
  }

  function handleScreensaverWindowClosed(address) {
    setScreensaverWindow(address, false)
    if (root.screensaverWindowCount > 0) return

    // Windows this service closes itself are forgotten before they close, so
    // a tracked window closing is the user's doing (a key press).
    if (root.away) root.userReturned("screensaver-dismissed")
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

  // ------------------------------------------------------------------ away

  // The compositor resets every idle notification on input, and several
  // things this service does count as input there: the screensaver opening
  // (focus hops between monitors), the screensaver closing, the lock screen
  // coming up. Left alone, each stage would push the later ones back by a
  // full timeout, and standby would even wake the monitors again a moment
  // after switching them off, because closing the screensaver looked like the
  // user coming back.
  //
  // So the idle monitors only say when the user went away. From then on the
  // stages run on timers counted from that moment (awaySince), and what the
  // monitors report next is weighed: activity while an own action is under
  // way, or just after it, is that action and is ignored.
  //
  // The user coming back is seen by a watch monitor with a 1 s timeout, which
  // ignores idle inhibitors: after any activity, real or not, it goes idle
  // again a second later and so reports the next input, while the stage
  // monitors would stay silent until their long timeouts ran out again. It
  // is armed while the user is away and while a screensaver is up, which is
  // also what lets a mouse move end the screensaver: omarchy-screensaver
  // itself only exits on a key press or on losing focus.
  readonly property int watchIdleSeconds: 1
  readonly property bool ownActionRunning: screensaverProcess.running || screensaverStopProcess.running
    || standbyOffProcess.running || lockProcess.running
  readonly property bool ownActionRecent: ownActionRunning || ownActionTimer.running

  function markOwnAction() {
    ownActionTimer.restart()
  }

  onOwnActionRunningChanged: markOwnAction()

  function syncWatchMonitor() {
    root.watchMonitor = armMonitor(root.watchMonitor, root.away || root.screensaverWindowCount > 0,
      root.watchIdleSeconds, "watch")
  }

  function enterAway(since) {
    root.awaySince = since
    root.cycleDoneThisAway = false
    root.standbyFiredThisAway = false
    root.suspendFiredThisAway = false
    logEvent("away", "idle since " + new Date(since).toISOString())
    syncWatchMonitor()
  }

  // Ends the away state without treating it as the user coming back.
  function endAway(reason) {
    if (!root.away) return
    logEvent("away-end", reason || "requested")
    root.awaySince = 0
    root.cycleDoneThisAway = false
    root.standbyFiredThisAway = false
    root.suspendFiredThisAway = false
    standbyAwayTimer.stop()
    suspendAwayTimer.stop()
    syncWatchMonitor()
  }

  // A stage monitor went idle: `seconds` is its timeout, so the user has been
  // gone that long. Standby and suspend are (re)scheduled from awaySince.
  function noteIdle(seconds) {
    if (!root.away) enterAway(Date.now() - seconds * 1000)
    scheduleAwayStage(standbyAwayTimer, root.standbyArmed && !root.standbyFiredThisAway, root.standbyTimeoutSeconds)
    scheduleAwayStage(suspendAwayTimer, root.suspendArmed && !root.suspendFiredThisAway, root.suspendTimeoutSeconds)
  }

  function scheduleAwayStage(timer, wanted, seconds) {
    if (!root.away || !wanted) {
      timer.stop()
      return
    }
    // A stage that is already due fires on the next tick, not from inside
    // the monitor's signal handler.
    timer.interval = Math.max(1, root.awaySince + seconds * 1000 - Date.now())
    timer.restart()
  }

  function fireAwayStandby() {
    if (!root.away || !root.standbyArmed || root.standbyFiredThisAway) return
    root.standbyFiredThisAway = true
    standbyDisplays("standby-timeout")
  }

  function fireAwaySuspend() {
    if (!root.away || !root.suspendArmed || root.suspendFiredThisAway) return
    root.suspendFiredThisAway = true
    suspendSystem("suspend-timeout")
  }

  function stopScreensaver(reason) {
    if (root.screensaverWindowCount === 0) return
    logEvent("screensaver-stop", reason + " (windows=" + root.screensaverWindowCount + ")")
    resetScreensaverWindows()
    runProcess(screensaverStopProcess, "screensaver-stop", root.screensaverStopCommand)
  }

  function userReturned(reason) {
    logEvent("user-returned", reason)
    var hadScreensaver = root.screensaverWindowCount > 0
    if (hadScreensaver) stopScreensaver(reason)
    cancelIdleCycle(reason)
    endAway(reason)
    // Hyprland wakes the monitors on input by itself, but a return seen any
    // other way would leave them dark.
    wakeDisplays(reason)
  }

  // A monitor reported activity: `source` is its stage.
  function handleActivity(source) {
    if (root.ownActionRecent) {
      logEvent("activity-ignored", source + " (own action)")
      return
    }
    if (root.away) {
      userReturned("activity")
      return
    }
    // Not away: a screensaver started by hand, or monitors switched off from
    // the panel.
    if (source === "watch") stopScreensaver("activity")
    else if (source === "standby") wakeDisplays("activity")
  }

  function handleIdleChanged() {
    logEvent("idle-monitor", root.cycleIdle ? "idle" : "active")
    if (!root.cycleIdle) {
      handleActivity("cycle")
      return
    }
    if (!root.cycleEnabled) return
    noteIdle(root.firstIdleTimeoutSeconds)
    // Once the lock has fired there is nothing left for the cycle to do
    // until the user is back.
    if (!root.cycleDoneThisAway) startIdleCycle()
  }

  function handleWatchIdleChanged() {
    if (!root.watchIdle) handleActivity("watch")
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
  // the dispatch is idempotent, so a redundant "on" costs nothing — which is
  // also why neither call is gated on standbyActive: Hyprland wakes the
  // monitors itself on input, and a service that still believed them off
  // would refuse the next standby. standbyActive only records the last
  // dispatch, for the status output.
  //
  // Monitors also come back on their own on key press or mouse move —
  // misc.key_press_enables_dpms and misc.mouse_move_enables_dpms are on in
  // Omarchy's defaults — but a wake from anywhere else would leave a black
  // desktop, so activity turns them on explicitly too. Off and on run in their
  // own processes: a still-running "off" must never make the "on" that follows
  // it a no-op.
  readonly property string dpmsOffCommand: "hyprctl eval 'hl.dispatch(hl.dsp.dpms({action = \"off\"}))'"
  readonly property string dpmsOnCommand: "hyprctl eval 'hl.dispatch(hl.dsp.dpms({action = \"on\"}))'"

  // The IPC standby is what a Hyprland keybind would call, and binds fire on
  // the key press: with misc.key_press_enables_dpms on, the release that
  // follows would switch the monitors straight back on. A short deferral
  // lets the release land first. (The panel's own "o" key runs on release
  // for the same reason and needs no delay.)
  Timer {
    id: ipcStandbyTimer
    interval: 500
    repeat: false
    onTriggered: root.standbyDisplays("ipc")
  }

  // A running screensaver is closed when the monitors go dark, for the same
  // reason none is started while they are (see launchScreensaver): its windows
  // would ride the monitor that drops out and come back broken. Its windows
  // are forgotten first so the closewindow events that follow do not read as
  // the user dismissing it — the pending lock keeps its timer. The kill is
  // the one omarchy-system-lock does, a no-op when nothing is running, and it
  // runs in the same shell *ahead of* the DPMS off: omarchy-screensaver's
  // exit handler restores the cursor through a Hyprland config keyword, and a
  // config change has Hyprland re-apply monitor state, which switches DPMS
  // back on. So the shell waits for the screensaver scripts to be gone before
  // it turns the monitors off.
  readonly property string screensaverStopCommand: "pkill -x ttfx 2>/dev/null || true; timeout 1s pidwait -x ttfx 2>/dev/null || true; pkill -f '[o]rg.omarchy.screensaver' 2>/dev/null || true; timeout 2s pidwait -f '[o]marchy-screensaver$' 2>/dev/null || true"

  function standbyDisplays(reason) {
    root.standbyActive = true
    root.lastStandbyAt = nowIso()
    logEvent("standby", "displays off (" + (reason || "requested") + ")")
    markOwnAction()
    var tracked = root.screensaverWindowCount
    screensaverLaunchGraceTimer.stop()
    root.screensaverStartedThisCycle = false
    resetScreensaverWindows()
    logEvent("screensaver-stop", "standby (windows=" + tracked + ")")
    runProcess(standbyOffProcess, "standby-off", root.screensaverStopCommand + "; " + root.dpmsOffCommand)
  }

  function wakeDisplays(reason) {
    root.standbyActive = false
    logEvent("standby", "displays on (" + (reason || "requested") + ")")
    runProcess(standbyOnProcess, "standby-on", root.dpmsOnCommand)
  }

  function handleStandbyIdleChanged() {
    logEvent("standby-monitor", root.standbyIdle ? "idle" : "active")
    if (root.standbyIdle) {
      if (root.standbyArmed) noteIdle(root.standbyTimeoutSeconds)
      return
    }
    handleActivity("standby")
  }

  // --------------------------------------------------------------- suspend

  // Suspend is asked of logind directly: the org.freedesktop.login1 Suspend
  // call, which is what Omarchy's own Suspend menu entry ends up making too.
  readonly property string suspendCommand: "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Suspend b true"

  function suspendSystem(reason) {
    logEvent("suspend-system", reason || "requested")
    root.lastSuspendAt = nowIso()
    // Resume must not land on monitors this service left in DPMS off: the
    // machine would look dead until something happened to poke them.
    wakeDisplays("suspend")
    // omarchy-sleep-lock.service locks the session on PrepareForSleep, but
    // that path only locks: it leaves a running screensaver alone, and with
    // the lock stage off the screensaver used to outlive the suspend and greet
    // the user on the desktop after the unlock. So the cycle is ended and
    // omarchy-system-lock (lock + kill the screensaver, as the lock stage
    // does) runs first, in the same shell as the suspend call so the suspend
    // cannot overtake it. logind refuses the call while a sleep inhibitor is
    // held ("Operation denied due to active block inhibitor"); the exit code
    // lands in the log either way.
    endIdleCycle()
    // Whatever idle time there is after the resume counts from scratch.
    endAway("suspend")
    runProcess(suspendProcess, "suspend", "omarchy-system-lock; " + root.suspendCommand)
  }

  function handleSuspendIdleChanged() {
    logEvent("suspend-monitor", root.suspendIdle ? "idle" : "active")
    if (!root.suspendIdle) {
      handleActivity("suspend")
      return
    }
    if (root.suspendArmed) noteIdle(root.suspendTimeoutSeconds)
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
      away: root.away,
      awaySince: root.away ? new Date(root.awaySince).toISOString() : "",
      ownActionRecent: root.ownActionRecent,
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
        suspendTimeout: root.suspendMonitor ? root.suspendMonitor.timeout : null,
        watch: root.watchMonitor !== null
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

  // Writes go through the shell's own shell.json writer, as the inline
  // settings of this plugin's bar entry: the one config a scoped plugin may
  // write, and the same thing `omarchy bar set` edits. The entry is written
  // whole, so every stage key lands on it the first time and the stock `idle`
  // block stops mattering. The host pushes the new layout back into
  // `shell.barConfig`, which is what re-arms the monitors.
  function mutateIdleConfig(label, mutate) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") {
      logEvent("config-write-skipped", label + " (no shell)")
      return false
    }
    var next = IdleModel.stageSettingsFor(root.entrySettings, root.stageConfig)
    mutate(next)
    if (JSON.stringify(next) === JSON.stringify(root.entrySettings)) return true
    var written = root.shell.updateEntryInline(root.pluginId, next)
    logEvent(written === false ? "config-write-rejected" : "config", label)
    return written !== false
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

  function applyShellConfigText(text) {
    var parsed = null
    try {
      var candidate = JSON.parse(String(text || ""))
      if (IdleModel.isObject(candidate)) parsed = candidate
    } catch (error) {
    }
    root.fileConfig = parsed
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
      endAway("stay-awake")
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
      // "cycle" (screensaver + lock), "standby", "suspend" or "watch" (the
      // user coming back, see the away section); "retired" once replaced so a
      // signal from a monitor awaiting deletion cannot reach a handler.
      property string stage: ""
      onIsIdleChanged: {
        if (stage === "cycle") root.handleIdleChanged()
        else if (stage === "standby") root.handleStandbyIdleChanged()
        else if (stage === "suspend") root.handleSuspendIdleChanged()
        else if (stage === "watch") root.handleWatchIdleChanged()
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
    var monitor = monitorComponent.createObject(root, { stage: stage, timeout: timeoutSeconds, respectInhibitors: stage !== "watch" })
    if (!monitor) {
      logEvent("monitor-arm-failed", stage + " timeout=" + timeoutSeconds)
      return null
    }
    logEvent("monitor-arm", stage + " timeout=" + timeoutSeconds)
    return monitor
  }

  function syncMonitors() {
    var previousCycle = root.cycleMonitor
    var previousStandby = root.standbyMonitor
    var previousSuspend = root.suspendMonitor
    root.cycleMonitor = armMonitor(root.cycleMonitor, root.cycleEnabled, root.firstIdleTimeoutSeconds, "cycle")
    root.standbyMonitor = armMonitor(root.standbyMonitor, root.standbyArmed, root.standbyTimeoutSeconds, "standby")
    root.suspendMonitor = armMonitor(root.suspendMonitor, root.suspendArmed, root.suspendTimeoutSeconds, "suspend")
    // A cycle that was started by a monitor that no longer exists has nothing
    // to end it on activity; drop it and let the new monitor start afresh.
    if (root.idledThisCycle && root.cycleMonitor !== previousCycle) cancelIdleCycle("monitor-rearm")
    // The same goes for the away state: a stage was switched or retimed, so
    // the count starts over with the new monitors.
    if (root.cycleMonitor !== previousCycle || root.standbyMonitor !== previousStandby
      || root.suspendMonitor !== previousSuspend) endAway("monitor-rearm")
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

  // How long after an own action reported activity is still taken to be that
  // action. When it runs out while the user is away, the watch monitor must
  // be idle again; if it is not, there was input in the meantime that had
  // been ignored, and the user is back.
  Timer {
    id: ownActionTimer
    interval: 2500
    repeat: false
    onTriggered: {
      if (root.ownActionRunning) restart()
      else if (root.away && root.watchMonitor && !root.watchIdle) root.userReturned("activity during own action")
    }
  }

  Timer {
    id: standbyAwayTimer
    repeat: false
    onTriggered: root.fireAwayStandby()
  }

  Timer {
    id: suspendAwayTimer
    repeat: false
    onTriggered: root.fireAwaySuspend()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  // ------------------------------------------------------------ processes

  Process {
    id: screensaverProcess
    onExited: function(exitCode, exitStatus) {
      root.logEvent("process-exit", "screensaver exitCode=" + exitCode + " status=" + exitStatus)
      root.handleScreensaverLaunchExit(exitCode)
    }
  }
  Process {
    id: screensaverStopProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "screensaver-stop exitCode=" + exitCode + " status=" + exitStatus) }
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

  // Same watch the host keeps on its config: reload on every outside write
  // (the host's own writes included, they come from another FileView).
  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyShellConfigText(text())
    onLoadFailed: function(error) { root.fileConfig = null }
    onFileChanged: reload()
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

    // omarchy-shell idle stage <screensaver|standby|lock|suspend> [on|off|toggle|status]
    function stage(name: string, action: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      var act = String(action || "status")
      if (act === "on" || act === "off") root.setStageEnabled(name, act === "on")
      else if (act === "toggle") root.setStageEnabled(name, !root.stageEnabled(name))
      else if (act !== "status") return "unknown action: " + act
      return root.stageEnabled(name) ? "on" : "off"
    }

    // omarchy-shell idle timeout <screensaver|standby|lock|suspend> [seconds]
    function timeout(name: string, seconds: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      if (String(seconds || "") === "") return String(root.stageTimeout(name))
      return root.setStageTimeout(name, seconds) ? "ok" : "invalid timeout (min " + root.minTimeoutSeconds + " s)"
    }

    // omarchy-shell idle screensaver  → screensaver now, even with the stage off
    function screensaver(): string {
      root.startScreensaver("ipc")
      return "ok"
    }

    function suspend(): string {
      root.suspendSystem("ipc")
      return "ok"
    }

    // omarchy-shell idle standby  → monitors off now
    // omarchy-shell idle wake     → and back on
    function standby(): string {
      ipcStandbyTimer.restart()
      return "ok"
    }

    function wake(): string {
      root.wakeDisplays("ipc")
      return "ok"
    }
  }
}
