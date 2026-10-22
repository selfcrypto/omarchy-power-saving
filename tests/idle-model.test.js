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
