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

// Firing order within a group is the panel's order (see GROUP_ORDER).
var STAGES = ["screensaver", "standby", "lock", "suspend", "hibernate"]

var STAGE_LABELS = {
  screensaver: "Screensaver",
  standby: "Standby",
  lock: "Lock",
  suspend: "Suspend",
  hibernate: "Hibernate"
}

function isStage(name) {
  return STAGES.indexOf(String(name)) !== -1
}

function stageLabel(name) {
  return STAGE_LABELS[name] || String(name)
}

// Within a group the earlier stage may not fire after the later one: the
// screensaver no later than standby, lock no later than suspend or hibernate.
// Equal times are allowed. Only stages that are on are held to it.
var GROUP_ORDER = [["screensaver", "standby"], ["lock", "suspend"], ["lock", "hibernate"]]

// Stages that cannot both be on: only the earlier would ever fire, since the
// machine is asleep when the later one's time comes. Turning one on turns
// the other off.
var EXCLUSIVE = { suspend: "hibernate", hibernate: "suspend" }

function exclusiveWith(name) {
  return EXCLUSIVE[name] || ""
}

// Seconds `name` may be set to while it is on, given `stages` as
// { key: { enabled, seconds } }: { min, max }, max -1 when there is no limit.
function timeoutBounds(name, stages, minSeconds) {
  var min = minSeconds
  var max = -1
  for (var i = 0; i < GROUP_ORDER.length; i++) {
    var earlier = GROUP_ORDER[i][0]
    var later = GROUP_ORDER[i][1]
    if (later === name && stages[earlier] && stages[earlier].enabled)
      min = Math.max(min, stages[earlier].seconds)
    if (earlier === name && stages[later] && stages[later].enabled)
      max = max < 0 ? stages[later].seconds : Math.min(max, stages[later].seconds)
  }
  return { min: min, max: max }
}

// `seconds` moved into `bounds`. The minimum wins over a neighbour's time
// written by hand below it.
function clampToBounds(seconds, bounds) {
  var s = bounds.max >= 0 ? Math.min(bounds.max, seconds) : seconds
  return Math.max(bounds.min, s)
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

// "Next: Screensaver after 2 min idle" for the earliest stage that is on,
// "" when none is.
function nextStageText(stages) {
  var next = null
  for (var i = 0; i < stages.length; i++) {
    if (stages[i].enabled && (next === null || stages[i].seconds < next.seconds)) next = stages[i]
  }
  return next ? "Next: " + stageLabel(next.key) + " after " + durationText(next.seconds) + " idle" : ""
}

// Why `name`'s time is bounded, given `stages` as { key: { enabled, seconds } }:
// "Lock cannot follow Suspend", "" when nothing bounds it. A stage that is
// off has no bounds.
function boundsReason(name, stages) {
  if (!stages[name] || !stages[name].enabled) return ""
  var reasons = []
  for (var i = 0; i < GROUP_ORDER.length; i++) {
    var earlier = GROUP_ORDER[i][0]
    var later = GROUP_ORDER[i][1]
    if (earlier === name && stages[later] && stages[later].enabled)
      reasons.push(stageLabel(name) + " cannot follow " + stageLabel(later))
    if (later === name && stages[earlier] && stages[earlier].enabled)
      reasons.push(stageLabel(name) + " cannot come before " + stageLabel(earlier))
  }
  return reasons.join(". ")
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

// ------------------------------------------------------------- hibernate

var TIMESPAN_UNITS = {
  us: 0.000001, usec: 0.000001, ms: 0.001, msec: 0.001,
  s: 1, sec: 1, second: 1, seconds: 1,
  m: 60, min: 60, minute: 60, minutes: 60,
  h: 3600, hr: 3600, hour: 3600, hours: 3600,
  d: 86400, day: 86400, days: 86400,
  w: 604800, week: 604800, weeks: 604800
}

// Seconds in a systemd time span ("2h", "1h 30min", "90"; systemd.time(7)),
// -1 when it is empty or not understood.
function timespanSeconds(text) {
  var rest = String(text || "").trim()
  if (rest === "") return -1
  var total = 0
  var re = /^(\d+(?:\.\d+)?)\s*([a-z]*)\s*/
  while (rest !== "") {
    var m = re.exec(rest)
    if (!m) return -1
    var unit = m[2] === "" ? 1 : TIMESPAN_UNITS[m[2]]
    if (unit === undefined) return -1
    total += Number(m[1]) * unit
    rest = rest.slice(m[0].length)
  }
  return Math.floor(total)
}

// A systemd boolean (systemd.syntax(7)); `fallback` when empty or unknown.
function systemdBool(value, fallback) {
  var v = String(value || "").trim().toLowerCase()
  if (["1", "yes", "y", "true", "t", "on"].indexOf(v) !== -1) return true
  if (["0", "no", "n", "false", "f", "off"].indexOf(v) !== -1) return false
  return fallback
}

// When suspend-then-hibernate hibernates, from systemd-sleep.conf(5):
// `delay` is HibernateDelaySec= ("" when unset), `onAC` HibernateOnACPower=.
// Without a battery: after the delay, 2 h when unset. With one: at low
// battery, or after the delay if that comes first; with HibernateOnACPower=no
// the delay only runs on battery (said in the hint).
// In the box beside "Then hibernate after": "2 h", "45 min", "Low battery",
// "45 min / battery".
function hibernateDelayText(delay, hasBattery) {
  var seconds = timespanSeconds(delay)
  var after = seconds > 0 ? durationText(seconds) : ""
  if (!hasBattery) return after || "2 h"
  return after ? after + " / battery" : "Low battery"
}

// The box's tooltip: the value in full, where it comes from, how to change it.
function hibernateDelayHint(delay, hasBattery, onAC) {
  var seconds = timespanSeconds(delay)
  var after = seconds > 0 ? durationText(seconds) : ""
  var when = !hasBattery ? (after || "2 h") : (after ? after + " or at low battery" : "At low battery")
  var text = when + (after ? " (System setting)" : " (System default)")
    + ". Set by systemd, not the plugin. To change it, as root: HibernateDelaySec= in /etc/systemd/sleep.conf.d/. Applies from the next suspend."
  if (hasBattery && onAC === false && after) text += " The delay starts after unplugging."
  return text
}

// ---------------------------------------------------------------- config

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

var STAGE_KEYS = ["screensaver", "standby", "lock", "suspend", "lockEnabled", "standbyEnabled", "suspendEnabled", "hibernate", "hibernateEnabled", "suspendThenHibernate"]

// Inline settings of one bar entry (`{ id, ...settings }` in bar.layout.*),
// without the id; {} when the entry is absent, so reads fall back.
function barEntrySettings(barConfig, id) {
  var layout = barConfig && barConfig.layout ? barConfig.layout : null
  if (!layout) return {}
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var entries = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || String(entry.id || "") !== String(id)) continue
      var out = {}
      for (var key in entry) if (key !== "id") out[key] = entry[key]
      return out
    }
  }
  return {}
}

// Stage keys in effect: the entry's value wins, then the stock idle block.
// A key missing from both stays missing so Service.qml's defaults apply.
function mergedStageConfig(entrySettings, idleConfig) {
  var out = {}
  for (var i = 0; i < STAGE_KEYS.length; i++) {
    var key = STAGE_KEYS[i]
    if (entrySettings && entrySettings[key] !== undefined) out[key] = entrySettings[key]
    else if (idleConfig && idleConfig[key] !== undefined) out[key] = idleConfig[key]
  }
  return out
}

// What a write puts on the entry: whatever else it carries, plus every stage
// key currently in effect, so the first write migrates the idle block.
function stageSettingsFor(entrySettings, stageConfig) {
  var out = {}
  for (var key in entrySettings || {}) out[key] = entrySettings[key]
  for (var i = 0; i < STAGE_KEYS.length; i++) {
    var stageKey = STAGE_KEYS[i]
    if (stageConfig && stageConfig[stageKey] !== undefined) out[stageKey] = stageConfig[stageKey]
  }
  return out
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
    GROUP_ORDER: GROUP_ORDER,
    EXCLUSIVE: EXCLUSIVE,
    exclusiveWith: exclusiveWith,
    timeoutBounds: timeoutBounds,
    clampToBounds: clampToBounds,
    firstTimeout: firstTimeout,
    durationText: durationText,
    nextStageText: nextStageText,
    boundsReason: boundsReason,
    summaryText: summaryText,
    timespanSeconds: timespanSeconds,
    hibernateDelayText: hibernateDelayText,
    hibernateDelayHint: hibernateDelayHint,
    systemdBool: systemdBool,
    isObject: isObject,
    STAGE_KEYS: STAGE_KEYS,
    barEntrySettings: barEntrySettings,
    mergedStageConfig: mergedStageConfig,
    stageSettingsFor: stageSettingsFor
  }
}
