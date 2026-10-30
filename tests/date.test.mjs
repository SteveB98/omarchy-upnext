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
eq(D.parseDate("4 weeks from today", today), "2026-11-25", "weeks from today")
eq(D.parseDate("in 3 days", today), "2026-10-31", "in N days")
eq(D.parseDate("two weeks", today), "2026-11-11", "word number")
eq(D.parseDate("in a week", today), "2026-11-04", "in a week")
eq(D.parseDate("10 days later", today), "2026-11-07", "later")
eq(D.parseDate("a month from now", today), "2026-11-28", "month from now")
eq(D.parseDate("1 week from tomorrow", today), "2026-11-05", "from tomorrow")
eq(D.parseDate("+2m", today), "2026-12-28", "+2m")
eq(D.parseDate("in a year", today), "2027-10-28", "in a year")
eq(D.parseDate("next week", today), "2026-11-04", "next week")
eq(D.parseDate("next month", today), "2026-11-28", "next month")
eq(D.parseDate("mon", today), "2026-11-02", "mon is still Monday")
eq(D.parseDate("may 3", today), "2027-05-03", "may is still a month")
eq(D.parseDate("3", today), null, "bare number")
eq(D.parseDate("and", today), null, "word that starts like a number word")
eq(D.parseDate("weeks from today", today), null, "no amount")
eq(D.parseDate("4 bananas", today), null, "unknown unit")
eq(D.addMonths("2027-01-31", 1), "2027-02-28", "month end clamps")
eq(D.addMonths("2028-01-31", 1), "2028-02-29", "leap year clamp")
eq(D.addMonths("2026-12-15", 1), "2027-01-15", "month rolls the year")
eq(D.parseDate("+0", today), today, "+0 is today")
eq(D.parseDate("0 days", today), today, "0 days is today")
eq(D.parseDate("feb 29", "2028-01-15"), "2028-02-29", "leap day ahead")
eq(D.parseDate("feb 29", "2028-06-01"), null, "leap day past has no next-year twin")

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
const day = 86400
eq(D.refreshSeconds("light", 0, 0, 1000, 30 * day), 5184, "a fresh month: half of 1,000 calls over 30 days")
eq(D.refreshSeconds("light", 0, 500, 1000, 1 * day), 1800, "plenty left near month end: the 30-minute floor")
eq(D.refreshSeconds("light", 0, 700, 1000, 15 * day), 7200, "running low: the two-hour cap")
eq(D.refreshSeconds("light", 3600, 0, 1000, 1 * day), 3600, "a longer override wins")
eq(D.refreshSeconds("live", 0, 0, 1000, 30 * day), 300, "live isn't paced")
eq(D.secondsToMonthEnd(new Date(2026, 9, 31, 23, 0, 0)), 3600, "an hour to the 1st")
eq(D.nextMonthStart("2026-12-15"), "2027-01-01", "next month's 1st rolls the year")

console.log(`${n} passed`)
