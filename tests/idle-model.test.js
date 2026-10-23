// Stage order within a group: `node --test tests/`.
const test = require("node:test")
const assert = require("node:assert")
const M = require("../IdleModel.js")

function states(ss, sb, lk, su) {
  return {
    screensaver: { enabled: ss[0], seconds: ss[1] },
    standby: { enabled: sb[0], seconds: sb[1] },
    lock: { enabled: lk[0], seconds: lk[1] },
    suspend: { enabled: su[0], seconds: su[1] }
  }
}

const all = states([true, 300], [true, 600], [true, 900], [true, 1200])

test("the later stage of a group starts at the earlier one's time", () => {
  assert.deepStrictEqual(M.timeoutBounds("standby", all, 10), { min: 300, max: -1 })
  assert.deepStrictEqual(M.timeoutBounds("suspend", all, 10), { min: 900, max: -1 })
})

test("the earlier stage of a group ends at the later one's time", () => {
  assert.deepStrictEqual(M.timeoutBounds("screensaver", all, 10), { min: 10, max: 600 })
  assert.deepStrictEqual(M.timeoutBounds("lock", all, 10), { min: 10, max: 1200 })
})

test("lock and standby are in different groups", () => {
  const s = states([false, 300], [true, 1800], [true, 60], [false, 1200])
  assert.deepStrictEqual(M.timeoutBounds("lock", s, 10), { min: 10, max: -1 })
  assert.deepStrictEqual(M.timeoutBounds("standby", s, 10), { min: 10, max: -1 })
})

test("a stage that is off sets no limit", () => {
  const s = states([false, 300], [true, 600], [true, 900], [false, 1200])
  assert.deepStrictEqual(M.timeoutBounds("standby", s, 10), { min: 10, max: -1 })
  assert.deepStrictEqual(M.timeoutBounds("lock", s, 10), { min: 10, max: -1 })
})

test("clampToBounds moves a time into range", () => {
  assert.strictEqual(M.clampToBounds(60, { min: 300, max: -1 }), 300)
  assert.strictEqual(M.clampToBounds(2000, { min: 10, max: 1200 }), 1200)
  assert.strictEqual(M.clampToBounds(500, { min: 10, max: 1200 }), 500)
})

test("the minimum wins over a neighbour's time set below it by hand", () => {
  const s = states([false, 300], [true, 5], [true, 900], [false, 1200])
  const b = M.timeoutBounds("screensaver", Object.assign({}, s, { screensaver: { enabled: true, seconds: 300 } }), 10)
  assert.deepStrictEqual(b, { min: 10, max: 5 })
  assert.strictEqual(M.clampToBounds(300, b), 10)
})

test("summaryText lists stages that are on, in firing order", () => {
  const list = [{ key: "lock", enabled: true, seconds: 600 }, { key: "standby", enabled: false, seconds: 60 },
    { key: "screensaver", enabled: true, seconds: 120 }]
  assert.strictEqual(M.summaryText(list), "Screensaver 2 min → Lock 10 min")
})

test("hibernate only follows lock", () => {
  assert.ok(M.isStage("hibernate"))
  const s = Object.assign(states([true, 300], [true, 600], [true, 900], [true, 1200]), { hibernate: { enabled: true, seconds: 60 } })
  assert.deepStrictEqual(M.timeoutBounds("hibernate", s, 10), { min: 900, max: -1 })
  assert.deepStrictEqual(M.timeoutBounds("suspend", s, 10), { min: 900, max: -1 })
})

test("the hibernate keys are carried on every write", () => {
  const out = M.stageSettingsFor({}, { hibernate: 3600, hibernateEnabled: true })
  assert.strictEqual(out.hibernate, 3600)
  assert.strictEqual(out.hibernateEnabled, true)
})

test("lock comes no later than suspend or hibernate, whichever is earlier", () => {
  const s = Object.assign(states([false, 300], [false, 600], [true, 600], [true, 1200]), { hibernate: { enabled: true, seconds: 900 } })
  assert.deepStrictEqual(M.timeoutBounds("lock", s, 10), { min: 10, max: 900 })
  assert.deepStrictEqual(M.timeoutBounds("hibernate", s, 10), { min: 600, max: -1 })
})

test("suspend and hibernate exclude each other", () => {
  assert.strictEqual(M.exclusiveWith("suspend"), "hibernate")
  assert.strictEqual(M.exclusiveWith("hibernate"), "suspend")
  assert.strictEqual(M.exclusiveWith("lock"), "")
})

test("systemd time spans", () => {
  assert.strictEqual(M.timespanSeconds("2h"), 7200)
  assert.strictEqual(M.timespanSeconds("1h 30min"), 5400)
  assert.strictEqual(M.timespanSeconds("1h30min"), 5400)
  assert.strictEqual(M.timespanSeconds("90"), 90)
  assert.strictEqual(M.timespanSeconds(""), -1)
  assert.strictEqual(M.timespanSeconds("soon"), -1)
})

test("systemd booleans", () => {
  assert.strictEqual(M.systemdBool("no", true), false)
  assert.strictEqual(M.systemdBool("On", false), true)
  assert.strictEqual(M.systemdBool("", true), true)
  assert.strictEqual(M.systemdBool("maybe", true), true)
})

test("the then-hibernate delay line", () => {
  assert.strictEqual(M.hibernateDelayText("", false), "2 h (System default)")
  assert.strictEqual(M.hibernateDelayText("45min", false), "45 min (System setting)")
  assert.strictEqual(M.hibernateDelayText("45min", true), "45 min or at low battery (System setting)")
  assert.strictEqual(M.hibernateDelayText("", true), "Low battery (System default)")
  assert.ok(M.hibernateDelayHint("45min", true, false).endsWith("The delay starts after unplugging."))
  assert.ok(!M.hibernateDelayHint("45min", false, false).includes("unplugging"))
})

test("next stage", () => {
  assert.strictEqual(M.nextStageText([{ key: "lock", enabled: true, seconds: 600 }, { key: "screensaver", enabled: true, seconds: 120 }]), "Next: Screensaver after 2 min idle")
  assert.strictEqual(M.nextStageText([{ key: "lock", enabled: false, seconds: 600 }]), "")
})

test("why a time is bounded", () => {
  const s = Object.assign(states([true, 300], [true, 600], [true, 900], [true, 1200]), { hibernate: { enabled: false, seconds: 3600 } })
  assert.strictEqual(M.boundsReason("screensaver", s), "Screensaver cannot follow Standby")
  assert.strictEqual(M.boundsReason("suspend", s), "Suspend cannot come before Lock")
  assert.strictEqual(M.boundsReason("lock", s), "Lock cannot follow Suspend")
  assert.strictEqual(M.boundsReason("hibernate", s), "")
})
