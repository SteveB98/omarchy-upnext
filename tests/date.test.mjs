// Tests for DateParse.js (a QML ".pragma library" script) under node:
//   node tests/date.test.mjs
import { readFileSync } from "node:fs"
import vm from "node:vm"
import assert from "node:assert/strict"

const src = readFileSync(new URL("../DateParse.js", import.meta.url), "utf8").replace(/^\.pragma library$/m, "")
const D = {}
vm.runInNewContext(src, D)

let n = 0
const eq = (actual, expected, what) => { assert.equal(actual, expected, what); n++ }

// Wednesday 2026-10-28
const today = "2026-10-28"
eq(D.parseDate("", today), "", "blank")
eq(D.parseDate("today", today), today, "today")
eq(D.parseDate("tmrw", today), "2026-10-29", "tomorrow")
eq(D.parseDate("+3", today), "2026-10-31", "+3")
eq(D.parseDate("+2w", today), "2026-11-11", "+2w")
eq(D.parseDate("fri", today), "2026-10-30", "fri")
eq(D.parseDate("wed", today), today, "same weekday is today")
eq(D.parseDate("next fri", today), "2026-11-06", "next fri")
eq(D.parseDate("oct 20", today), "2026-10-20", "recent past stays this year")
eq(D.parseDate("aug 1", today), "2027-08-01", "over 60 days back rolls to next year")
eq(D.parseDate("20 nov", today), "2026-11-20", "day month")
eq(D.parseDate("11/3", today), "2026-11-03", "month/day")
eq(D.parseDate("2/30", today), null, "impossible date")
eq(D.parseDate("2027-01-05", today), "2027-01-05", "iso")
eq(D.parseDate("someday", today), null, "nonsense")

eq(D.weekEnd(today, "Monday"), "2026-11-01", "Monday weeks end Sunday")
eq(D.weekEnd(today, "Sunday"), "2026-10-31", "Sunday weeks end Saturday")
eq(D.weekEnd("2026-11-01", "Monday"), "2026-11-01", "Sunday is its own week end")
eq(D.weekEnd("2026-10-31", "Sunday"), "2026-10-31", "Saturday is its own week end")
eq(D.addDays(today, 31), "2026-11-28", "31-day window")

eq(D.profile("Auto", "team"), "live", "auto team")
eq(D.profile("Auto", "free"), "light", "auto free")
eq(D.profile("Live", "free"), "live", "override live")
eq(D.profile("Light", "team"), "light", "override light")
eq(D.refreshSeconds("live", 0, 0, 1000), 300, "live default")
eq(D.refreshSeconds("light", 0, 0, 1000), 1800, "light default")
eq(D.refreshSeconds("live", 60, 0, 1000), 300, "live floor")
eq(D.refreshSeconds("light", 300, 0, 1000), 900, "light floor")
eq(D.refreshSeconds("light", 0, 800, 1000), 7200, "light budget guard")
eq(D.refreshSeconds("live", 0, 5000, 1000), 300, "no guard on live")

console.log(`${n} passed`)
