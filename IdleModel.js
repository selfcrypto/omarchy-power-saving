// Pure helpers shared by Service.qml and Panel.qml. Cloned from
// omarchy.idle's IdleModel.js; the stage helpers at the bottom are ours.

function secondsFromConfig(value, fallback) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return fallback
  return Math.floor(n)
}

function boolFromConfig(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

function eventParts(event, count) {
  try {
    if (event && event.parse) return event.parse(count)
  } catch (error) {
  }
  return String(event && event.data ? event.data : "").split(",")
}

function screensaverWindowsAfter(windows, address, visible) {
  var key = String(address || "")
  if (!key) {
    var current = windows || {}
    var existingCount = 0
    for (var currentKey in current) {
      if (current[currentKey]) existingCount++
    }
    return { windows: current, count: existingCount }
  }

  var next = {}
  var count = 0
  for (var existing in windows || {}) {
    if (existing !== key && windows[existing]) {
      next[existing] = true
      count++
    }
  }

  if (visible) {
    next[key] = true
    count++
  }

  return {
    windows: next,
    count: count
  }
}

// ---------------------------------------------------------------- stages

// Firing order within a group is the panel's order; the config key of the
// sleep stage stays "suspend" (the stock key) even though it reads "Sleep".
var STAGES = ["screensaver", "standby", "lock", "suspend"]

var STAGE_LABELS = {
  screensaver: "Screensaver",
  standby: "Standby",
  lock: "Lock",
  suspend: "Sleep"
}

function isStage(name) {
  return STAGES.indexOf(String(name)) !== -1
}

function stageLabel(name) {
  return STAGE_LABELS[name] || String(name)
}

// Earliest deadline among the enabled screensaver/lock stages; those two
// share one idle monitor and are staggered with timers from that point.
// Falls back to the screensaver timeout when both are off (the monitor is
// disabled then, so the value never fires).
function firstTimeout(screensaverOn, screensaverSeconds, lockOn, lockSeconds) {
  var first = -1
  if (screensaverOn) first = screensaverSeconds
  if (lockOn && (first < 0 || lockSeconds < first)) first = lockSeconds
  return first < 0 ? screensaverSeconds : first
}

function durationText(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return s + " s"
  var m = Math.round(s / 60)
  if (m < 60) return m + " min"
  var h = Math.floor(m / 60)
  var rest = m % 60
  return rest === 0 ? h + " h" : h + " h " + rest + " min"
}

// "Screensaver 10 min → Lock 20 min → Suspend 30 min", enabled stages in
// firing order; "All stages off" when nothing is armed.
function summaryText(stages) {
  var on = []
  for (var i = 0; i < stages.length; i++) if (stages[i].enabled) on.push(stages[i])
  if (on.length === 0) return "All stages off"
  on.sort(function(a, b) { return a.seconds - b.seconds })
  var parts = []
  for (var j = 0; j < on.length; j++) parts.push(stageLabel(on[j].key) + " " + durationText(on[j].seconds))
  return parts.join(" → ")
}

// Same order, but "󱄄 10 min → 󰌾 20 min → 󰒲 30 min": short enough for the
// hero's letter-spaced caps line, where the words would be cut off.
function compactSummaryText(stages) {
  var on = []
  for (var i = 0; i < stages.length; i++) if (stages[i].enabled) on.push(stages[i])
  if (on.length === 0) return "All stages off"
  on.sort(function(a, b) { return a.seconds - b.seconds })
  var parts = []
  for (var j = 0; j < on.length; j++) parts.push(on[j].glyph + " " + durationText(on[j].seconds))
  return parts.join(" → ")
}

if (typeof module !== "undefined") {
  module.exports = {
    secondsFromConfig: secondsFromConfig,
    boolFromConfig: boolFromConfig,
    eventParts: eventParts,
    screensaverWindowsAfter: screensaverWindowsAfter,
    STAGES: STAGES,
    STAGE_LABELS: STAGE_LABELS,
    isStage: isStage,
    stageLabel: stageLabel,
    firstTimeout: firstTimeout,
    durationText: durationText,
    summaryText: summaryText,
    compactSummaryText: compactSummaryText
  }
}
