import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "IdleModel.js" as IdleModel

// Power-saving idle service in five stages, each with its own switch and
// timeout, grouped the way they are presented in the panel:
//   display:     screensaver → standby (monitors off, DPMS)
//   system:      lock → suspend
//   hibernation: hibernate (only where logind can)
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
//   hibernate                      seconds since idle began (ours)
//   lockEnabled / suspendEnabled / standbyEnabled / hibernateEnabled
//                                  booleans (defaults: true / false / false / false)
// The screensaver switch is Omarchy's own `screensaver-off` toggle
// (`omarchy toggle screensaver`), so the menu and the panel agree. "Stay
// awake" (`omarchy toggle idle`) pauses all the stages.
//
// Screensaver and lock share one IdleMonitor armed at the earliest enabled
// deadline and are staggered with timers, exactly as upstream does, because
// locking ends that cycle (the lock plugin owns the screen from then on).
// Standby, suspend and hibernate get an IdleMonitor each, so each can be the first to
// see the user go idle. Once that is known they run on timers counted from
// that moment (see the away section), because the compositor resets the
// monitors whenever this service opens or closes the screensaver or locks.
// NOTE: after editing this file run `omarchy restart shell`. The hot reload
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
  readonly property int defaultHibernateSeconds: 3600
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
  readonly property int hibernateTimeoutSeconds: secondsFromConfig(stageConfig.hibernate, defaultHibernateSeconds)
  readonly property bool lockEnabled: IdleModel.boolFromConfig(stageConfig.lockEnabled, true)
  readonly property bool standbyEnabled: IdleModel.boolFromConfig(stageConfig.standbyEnabled, false)
  readonly property bool suspendEnabled: IdleModel.boolFromConfig(stageConfig.suspendEnabled, false)
  readonly property bool hibernateEnabled: IdleModel.boolFromConfig(stageConfig.hibernateEnabled, false)
  // Suspend through logind's SuspendThenHibernate: suspend, then hibernate when
  // systemd decides (HibernateDelaySec=, battery level). Plain suspend where
  // logind cannot.
  readonly property bool suspendThenHibernate: IdleModel.boolFromConfig(stageConfig.suspendThenHibernate, false)
  // logind's CanHibernate and CanSuspendThenHibernate answers: hibernation set
  // up (swap, resume=) and allowed.
  property bool canHibernate: false
  property bool canSuspendThenHibernate: false
  // systemd's sleep settings, read with the probe: HibernateDelaySec= (""
  // when unset), HibernateOnACPower=, and whether there is a battery.
  // hibernateDelayText says when suspend-then-hibernate hibernates.
  property string hibernateDelay: ""
  property bool hibernateOnAC: true
  property bool hasBattery: false
  readonly property string hibernateDelayText: IdleModel.hibernateDelayText(hibernateDelay, hasBattery)
  readonly property string hibernateDelayHint: IdleModel.hibernateDelayHint(hibernateDelay, hasBattery, hibernateOnAC)
  readonly property string hibernateDelaySource: IdleModel.hibernateDelaySource(hibernateDelay)
  // Suspend and hibernate are exclusive (IdleModel.EXCLUSIVE). Both on in
  // shell.json by hand: hibernate wins and suspend counts as off.
  readonly property bool suspendOverridden: suspendEnabled && hibernateEnabled && canHibernate
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
  readonly property bool suspendArmed: idleEnabled && suspendEnabled && !suspendOverridden
  readonly property bool hibernateArmed: idleEnabled && hibernateEnabled && canHibernate
  readonly property string screensaverClass: "org.omarchy.screensaver"
  property var cycleMonitor: null
  property var standbyMonitor: null
  property var suspendMonitor: null
  property var hibernateMonitor: null
  property var watchMonitor: null
  readonly property bool cycleIdle: cycleMonitor ? cycleMonitor.isIdle : false
  readonly property bool standbyIdle: standbyMonitor ? standbyMonitor.isIdle : false
  readonly property bool suspendIdle: suspendMonitor ? suspendMonitor.isIdle : false
  readonly property bool hibernateIdle: hibernateMonitor ? hibernateMonitor.isIdle : false
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
  property bool hibernateFiredThisAway: false
  property bool standbyActive: false
  property bool autoDisabledStockIdle: false
  property string lastEvent: "starting"
  property string lastEventAt: ""
  property string lastStandbyAt: ""
  property string lastSuspendAt: ""
  // Set when turning a stage on moved its timeout to keep the group order;
  // the panel shows it for a few seconds.
  property string orderNote: ""
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
  // returns on input the window is carried back with a stale input box,
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
  // while it is still up adopts it: omarchy-launch-screensaver exits early
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
    // A screensaver still on screen stays tracked, so the watch monitor ends
    // it on the next input. Stay awake switching on cancels the cycle without
    // closing it; forgetting its windows here left one up that only a key
    // press could close, and the next cycle's launch found it running and
    // added nothing.
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

  // A screensaver already open when the service starts (the shell restarted
  // under it) sent its openwindow before anyone listened. Untracked, input
  // never closed it and the next cycle's launch found it running and added
  // nothing. So the open windows are read once at start and adopted.
  function adoptScreensaverWindows(text) {
    var clients = []
    try {
      clients = JSON.parse(String(text || "[]"))
    } catch (error) {
      return
    }
    if (!Array.isArray(clients)) return
    for (var i = 0; i < clients.length; i++) {
      var client = clients[i]
      if (!client || String(client["class"] || "") !== root.screensaverClass) continue
      // Events name windows without the 0x that hyprctl prints.
      var address = String(client.address || "").replace(/^0x/, "")
      if (!address || root.screensaverWindows[address]) continue
      logEvent("screensaver-adopted", address)
      setScreensaverWindow(address, true)
    }
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
  // The user coming back is seen by a watch monitor with a 0.1 s timeout, which
  // ignores idle inhibitors: after any activity, real or not, it goes idle
  // again a moment later and so reports the next input, while the stage
  // monitors would stay silent until their long timeouts ran out again. It
  // is armed while the user is away and while a screensaver is up, which is
  // also what lets a mouse move end the screensaver: omarchy-screensaver
  // itself only exits on a key press or on losing focus.
  readonly property real watchIdleSeconds: 0.1
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
    root.hibernateFiredThisAway = false
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
    root.hibernateFiredThisAway = false
    standbyAwayTimer.stop()
    suspendAwayTimer.stop()
    hibernateAwayTimer.stop()
    syncWatchMonitor()
  }

  // A stage monitor went idle: `seconds` is its timeout, so the user has been
  // gone that long. Standby, suspend and hibernate are (re)scheduled from
  // awaySince.
  function noteIdle(seconds) {
    if (!root.away) enterAway(Date.now() - seconds * 1000)
    scheduleAwayStages()
  }

  function scheduleAwayStages() {
    scheduleAwayStage(standbyAwayTimer, root.standbyArmed && !root.standbyFiredThisAway, root.standbyTimeoutSeconds)
    scheduleAwayStage(suspendAwayTimer, root.suspendArmed && !root.suspendFiredThisAway, root.suspendTimeoutSeconds)
    scheduleAwayStage(hibernateAwayTimer, root.hibernateArmed && !root.hibernateFiredThisAway, root.hibernateTimeoutSeconds)
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

  function fireAwayHibernate() {
    if (!root.away || !root.hibernateArmed || root.hibernateFiredThisAway) return
    root.hibernateFiredThisAway = true
    hibernateSystem("hibernate-timeout")
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

  function handleInput(reason) {
    if (root.away) userReturned(reason)
    else stopScreensaver(reason)
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
  // the dispatch *toggles*. Verified against /sys/class/drm/*/dpms, which is
  // also the only trustworthy read of the state (`hyprctl monitors` reports
  // dpmsStatus a dispatch behind). A toggle would be silently wrong here: two
  // stages racing, or a lost wake, would leave the desktop dark. With `action`
  // the dispatch is idempotent, so a redundant "on" costs nothing. That is
  // also why neither call is gated on standbyActive: Hyprland wakes the
  // monitors itself on input, and a service that still believed them off
  // would refuse the next standby. standbyActive only records the last
  // dispatch, for the status output.
  //
  // Monitors also come back on their own on key press or mouse move
  // (misc.key_press_enables_dpms and misc.mouse_move_enables_dpms are on in
  // Omarchy's defaults), but a wake from anywhere else would leave a black
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
  // the user dismissing it; the pending lock keeps its timer. The kill is
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
  // Hibernate is the same path with logind's Hibernate call. With
  // suspendThenHibernate on, suspend calls SuspendThenHibernate, asked again
  // at that moment so a system where it has gone since still suspends.
  readonly property string logindCall: "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager"
  readonly property string suspendCall: root.suspendThenHibernate
    ? "if [ \"$(" + root.logindCall + " CanSuspendThenHibernate)\" = 's \"yes\"' ]; then "
      + root.logindCall + " SuspendThenHibernate b true; else " + root.logindCall + " Suspend b true; fi"
    : root.logindCall + " Suspend b true"

  function suspendSystem(reason) {
    sleepSystem("suspend", root.suspendCall, suspendProcess, reason)
  }

  function hibernateSystem(reason) {
    sleepSystem("hibernate", root.logindCall + " Hibernate b true", hibernateProcess, reason)
  }

  // It modifies suspend, so it is only switched on while suspend is on;
  // switching it off always works.
  function setSuspendThenHibernate(value) {
    var enabled = !!value
    if (root.suspendThenHibernate === enabled) return true
    if (enabled && !stageEnabled("suspend")) return false
    return mutateIdleConfig("suspendThenHibernate " + (enabled ? "on" : "off"), function(idle) {
      idle.suspendThenHibernate = enabled
    })
  }

  function sleepSystem(label, call, process, reason) {
    logEvent(label + "-system", reason || "requested")
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
    endAway(label)
    runProcess(process, label, "omarchy-system-lock; " + call)
  }

  // Asked at start and each time the panel opens, since hibernation can be
  // set up or removed while the shell runs.
  function refreshHibernate() {
    if (!hibernateProbe.running) hibernateProbe.running = true
  }

  function applyHibernateProbe(text) {
    var values = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf("=")
      if (at > 0) values[lines[i].slice(0, at)] = lines[i].slice(at + 1).trim()
    }
    root.canHibernate = values.hibernate === "s \"yes\""
    root.canSuspendThenHibernate = values.then === "s \"yes\""
    root.hibernateDelay = values.delay || ""
    root.hibernateOnAC = IdleModel.systemdBool(values.onac, true)
    root.hasBattery = values.battery === "yes"
  }

  function handleHibernateIdleChanged() {
    logEvent("hibernate-monitor", root.hibernateIdle ? "idle" : "active")
    if (!root.hibernateIdle) {
      handleActivity("hibernate")
      return
    }
    if (root.hibernateArmed) noteIdle(root.hibernateTimeoutSeconds)
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
    if (name === "suspend") return root.suspendEnabled && !root.suspendOverridden
    if (name === "hibernate") return root.hibernateEnabled
    return false
  }

  function stageTimeout(name) {
    if (name === "screensaver") return root.screensaverTimeoutSeconds
    if (name === "standby") return root.standbyTimeoutSeconds
    if (name === "lock") return root.lockTimeoutSeconds
    if (name === "suspend") return root.suspendTimeoutSeconds
    if (name === "hibernate") return root.hibernateTimeoutSeconds
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
        suspend: stageJson("suspend"),
        hibernate: stageJson("hibernate")
      },
      canHibernate: root.canHibernate,
      suspendThenHibernate: {
        enabled: root.suspendThenHibernate,
        available: root.canSuspendThenHibernate,
        hibernateDelay: root.hibernateDelay,
        hibernateOnAC: root.hibernateOnAC,
        battery: root.hasBattery,
        when: root.hibernateDelayText
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
        hibernate: root.hibernateMonitor !== null,
        hibernateTimeout: root.hibernateMonitor ? root.hibernateMonitor.timeout : null,
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
        suspend: suspendProcess.running,
        hibernate: hibernateProcess.running
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

  // Every stage as { key: { enabled, seconds } }, for IdleModel.timeoutBounds.
  function stageStates() {
    var out = {}
    for (var i = 0; i < IdleModel.STAGES.length; i++) {
      var key = IdleModel.STAGES[i]
      out[key] = { enabled: stageEnabled(key), seconds: stageTimeout(key) }
    }
    return out
  }

  // Seconds `name` may be set to: { min, max }, max -1 for no limit. A stage
  // that is off has no neighbour limit; it is moved into range when turned on.
  function stageTimeoutBounds(name) {
    if (!stageEnabled(name)) return { min: root.minTimeoutSeconds, max: -1 }
    return IdleModel.timeoutBounds(name, stageStates(), root.minTimeoutSeconds)
  }

  function setStageTimeout(name, seconds) {
    if (!IdleModel.isStage(name)) return false
    var n = Math.floor(Number(seconds))
    var bounds = stageTimeoutBounds(name)
    if (!isFinite(n) || n < bounds.min || (bounds.max >= 0 && n > bounds.max)) return false
    return mutateIdleConfig(name + "=" + n, function(idle) { idle[name] = n })
  }

  // The timeout `name` gets when it is turned on: its own, or the nearest one
  // that keeps it in order with the other stage of its group.
  function timeoutWhenEnabled(name) {
    var states = stageStates()
    states[name].enabled = true
    var bounds = IdleModel.timeoutBounds(name, states, root.minTimeoutSeconds)
    return IdleModel.clampToBounds(stageTimeout(name), bounds)
  }

  // Tells the panel a stage was moved; called only once the write went through.
  function noteMoved(name, seconds) {
    note(IdleModel.stageLabel(name) + " moved to " + IdleModel.durationText(seconds))
  }

  function note(text) {
    root.orderNote = text
    orderNoteTimer.restart()
  }

  function setStageEnabled(name, value) {
    var enabled = !!value
    if (name === "screensaver") {
      if (root.screensaverToggleLoaded && root.screensaverEnabled === enabled) return true
      // The switch is a toggle file, the timeout is config: two writes.
      // A move that cannot be written leaves the stage off rather than out of order.
      if (enabled) {
        var seconds = timeoutWhenEnabled(name)
        if (seconds !== stageTimeout(name)) {
          if (!mutateIdleConfig(name + "=" + seconds, function(idle) { idle[name] = seconds })) return false
          noteMoved(name, seconds)
        }
      }
      root.screensaverOff = !enabled
      root.screensaverToggleLoaded = true
      logEvent("stage", "screensaver " + (enabled ? "on" : "off"))
      screensaverToggleWriter.command = ["omarchy-toggle", "screensaver-off", enabled ? "off" : "on"]
      screensaverToggleWriter.running = true
      return true
    }
    if (name === "standby") {
      if (root.standbyEnabled === enabled) return true
      return setGatedStage("standby", enabled)
    }
    if (name === "lock") {
      if (root.lockEnabled === enabled) return true
      return setGatedStage("lock", enabled)
    }
    if (name === "suspend" || name === "hibernate") {
      if (stageEnabled(name) === enabled) return true
      if (name === "hibernate" && enabled && !root.canHibernate) return false
      return setGatedStage(name, enabled)
    }
    return false
  }

  // Standby, lock, suspend and hibernate: switch and timeout in one config write, since
  // a second write would start from config that has not reloaded yet.
  // Turning suspend or hibernate on turns the other off in the same write.
  function setGatedStage(name, enabled) {
    var seconds = enabled ? timeoutWhenEnabled(name) : stageTimeout(name)
    var other = enabled ? IdleModel.exclusiveWith(name) : ""
    var otherWasOn = other !== "" && stageEnabled(other)
    var written = mutateIdleConfig(name + " " + (enabled ? "on" : "off"), function(idle) {
      idle[name + "Enabled"] = enabled
      idle[name] = seconds
      if (other !== "") idle[other + "Enabled"] = false
    })
    if (!written) return false
    var notes = []
    if (seconds !== stageTimeout(name)) notes.push(IdleModel.stageLabel(name) + " moved to " + IdleModel.durationText(seconds))
    if (otherWasOn) notes.push(IdleModel.stageLabel(other) + " switched off")
    if (notes.length) note(notes.join(" · "))
    return true
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
  // needed to switch the stock service off: one `omarchy plugin add … --enable`
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
  // change and keeps watching the dead object, so the monitor never fires again
  // (verified standalone: Hyprland logs "marked idle", QML isIdle stays
  // false). So a monitor is never reconfigured here: every enabled/timeout
  // combination is a brand-new IdleMonitor with the timeout set at creation,
  // and the previous one is retired and destroyed.
  Component {
    id: monitorComponent

    IdleMonitor {
      // "cycle" (screensaver + lock), "standby", "suspend", "hibernate" or "watch" (the
      // user coming back, see the away section); "retired" once replaced so a
      // signal from a monitor awaiting deletion cannot reach a handler.
      property string stage: ""
      onIsIdleChanged: {
        if (stage === "cycle") root.handleIdleChanged()
        else if (stage === "standby") root.handleStandbyIdleChanged()
        else if (stage === "suspend") root.handleSuspendIdleChanged()
        else if (stage === "hibernate") root.handleHibernateIdleChanged()
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
    var previousHibernate = root.hibernateMonitor
    root.hibernateMonitor = armMonitor(root.hibernateMonitor, root.hibernateArmed, root.hibernateTimeoutSeconds, "hibernate")
    // A cycle that was started by a monitor that no longer exists has nothing
    // to end it on activity; drop it and let the new monitor start afresh.
    if (root.idledThisCycle && root.cycleMonitor !== previousCycle) cancelIdleCycle("monitor-rearm")
    // The same goes for the away state when the cycle monitor changed, or
    // when nothing is armed any more. A standby, suspend or hibernate change
    // alone keeps it and reschedules those from awaySince: ending it left a
    // running cycle behind, so input only closed the screensaver and the lock
    // fired on the user later.
    if (root.cycleMonitor !== previousCycle
      || (!root.cycleMonitor && !root.standbyMonitor && !root.suspendMonitor && !root.hibernateMonitor)) {
      endAway("monitor-rearm")
    } else if (root.away && (root.standbyMonitor !== previousStandby || root.suspendMonitor !== previousSuspend
      || root.hibernateMonitor !== previousHibernate)) {
      logEvent("away-reschedule", "monitor-rearm")
      scheduleAwayStages()
    }
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
  onHibernateArmedChanged: syncMonitors()
  onHibernateTimeoutSecondsChanged: syncMonitors()

  Timer {
    id: orderNoteTimer
    interval: 6000
    onTriggered: root.orderNote = ""
  }

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
  // action. The watch monitor only reports the step from idle to active, so
  // input that began meanwhile and has not paused would go unseen: a mouse
  // kept moving while the screensaver came up would never end it. So when
  // the time runs out and the watch monitor is not idle, there is input
  // right now (within its 0.1 s), and it is acted on.
  Timer {
    id: ownActionTimer
    interval: 1500
    repeat: false
    onTriggered: {
      if (root.ownActionRunning) restart()
      else if ((root.away || root.screensaverWindowCount > 0) && root.watchMonitor && !root.watchIdle) root.handleInput("activity")
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

  Timer {
    id: hibernateAwayTimer
    repeat: false
    onTriggered: root.fireAwayHibernate()
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
    id: hibernateProcess
    onExited: function(exitCode, exitStatus) { root.logEvent("process-exit", "hibernate exitCode=" + exitCode + " status=" + exitStatus) }
  }
  Process {
    id: screensaverAdoptProbe
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.adoptScreensaverWindows(text)
    }
  }
  Process {
    id: hibernateProbe
    // One key=value per line. cat-config prints sleep.conf and its drop-ins
    // in order, so the last assignment wins, as in systemd.
    command: ["bash", "-c", "echo \"hibernate=$(" + root.logindCall + " CanHibernate 2>/dev/null)\"; "
      + "echo \"then=$(" + root.logindCall + " CanSuspendThenHibernate 2>/dev/null)\"; "
      + "conf=$(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null); "
      + "echo \"delay=$(sed -n 's/^[[:space:]]*HibernateDelaySec=[[:space:]]*//p' <<< \"$conf\" | tail -n 1)\"; "
      + "echo \"onac=$(sed -n 's/^[[:space:]]*HibernateOnACPower=[[:space:]]*//p' <<< \"$conf\" | tail -n 1)\"; "
      + "for t in /sys/class/power_supply/*/type; do [ \"$(cat \"$t\" 2>/dev/null)\" = Battery ] && { echo battery=yes; break; }; done; true"]
    stdout: StdioCollector {
      onStreamFinished: root.applyHibernateProbe(this.text)
    }
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
    refreshHibernate()
    screensaverAdoptProbe.running = true
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

    // omarchy-shell idle stage <screensaver|standby|lock|suspend|hibernate> [on|off|toggle|status]
    function stage(name: string, action: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      var act = String(action || "status")
      if (act === "on" || act === "off") root.setStageEnabled(name, act === "on")
      else if (act === "toggle") root.setStageEnabled(name, !root.stageEnabled(name))
      else if (act !== "status") return "unknown action: " + act
      return root.stageEnabled(name) ? "on" : "off"
    }

    // omarchy-shell idle timeout <screensaver|standby|lock|suspend|hibernate> [seconds]
    function timeout(name: string, seconds: string): string {
      if (!IdleModel.isStage(name)) return "unknown stage: " + name
      if (String(seconds || "") === "") return String(root.stageTimeout(name))
      if (root.setStageTimeout(name, seconds)) return "ok"
      var bounds = root.stageTimeoutBounds(name)
      return "invalid timeout (" + (bounds.max >= 0 ? bounds.min + " s to " + bounds.max + " s" : "min " + bounds.min + " s") + ")"
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

    // omarchy-shell idle suspendThenHibernate <on|off|toggle|status>
    function suspendThenHibernate(action: string): string {
      var act = String(action || "status")
      if (act === "on" || act === "off") root.setSuspendThenHibernate(act === "on")
      else if (act === "toggle") root.setSuspendThenHibernate(!root.suspendThenHibernate)
      else if (act !== "status") return "unknown action: " + act
      return (root.suspendThenHibernate ? "on" : "off") + (root.canSuspendThenHibernate ? "" : " (not available here, suspends instead)")
    }

    function hibernate(): string {
      if (!root.canHibernate) return "hibernation not available"
      root.hibernateSystem("ipc")
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
