.pragma library
// Date helpers for Up Next. Dates are local "YYYY-MM-DD" strings, which
// compare correctly as text. Every function takes "today" so the widget and
// the tests (tests/date.test.mjs) decide what day it is.

function pad(n) { return n < 10 ? "0" + n : String(n) }
function iso(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
function parseIso(s) {
  var p = String(s).split("-")
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
}

function addDays(today, n) {
  var d = parseIso(today)
  d.setDate(d.getDate() + n)
  return iso(d)
}

// Last day of the current week: Sunday when weeks start on Monday,
// Saturday when they start on Sunday.
function weekEnd(today, weekStart) {
  var day = parseIso(today).getDay()
  return addDays(today, weekStart === "Sunday" ? 6 - day : (7 - day) % 7)
}

function buildDate(today, y, m, d, explicitYear) {
  var dt = new Date(y, m - 1, d)
  if (isNaN(dt) || dt.getMonth() !== m - 1 || dt.getDate() !== d) return null
  // "oct 3" said in October means this year; said in December, next year.
  if (!explicitYear && iso(dt) < addDays(today, -60)) dt.setFullYear(y + 1)
  return iso(dt)
}

var monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
var dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

function monthIndex(word) {
  var i = monthNames.indexOf(word.slice(0, 3))
  return i >= 0 && word.length >= 3 ? i + 1 : 0
}

// Loose date input -> "YYYY-MM-DD", "" for blank, or null if unreadable.
// today, tomorrow, +3, +2w, fri, next fri, oct 20, 20 oct, 10/20, 2026-10-20
function parseDate(input, today) {
  var s = String(input || "").trim().toLowerCase().replace(/,/g, " ").replace(/\s+/g, " ")
  if (s === "") return ""
  if (s === "today" || s === "tod" || s === "now") return today
  if (/^(tomorrow|tom|tmr|tmrw)$/.test(s)) return addDays(today, 1)
  var m = s.match(/^\+(\d{1,3}) ?(d|days?|w|wks?|weeks?)?$/)
  if (m) return addDays(today, Number(m[1]) * (m[2] && m[2][0] === "w" ? 7 : 1))
  m = s.match(/^(next )?([a-z]{3,})$/)
  if (m) {
    for (var w = 0; w < 7; w++) {
      if (dayNames[w].indexOf(m[2]) === 0) {
        var delta = (w - parseIso(today).getDay() + 7) % 7
        return addDays(today, m[1] ? delta + 7 : delta)
      }
    }
    return null
  }
  var y = parseIso(today).getFullYear()
  m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
  if (m) return buildDate(today, Number(m[1]), Number(m[2]), Number(m[3]), true)
  m = s.match(/^(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2}|\d{4}))?$/)  // month/day, North American
  if (m) return buildDate(today, m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : y, Number(m[1]), Number(m[2]), !!m[3])
  m = s.match(/^([a-z]{3,})\.? (\d{1,2})(?: (\d{4}))?$/)
  if (m && monthIndex(m[1])) return buildDate(today, m[3] ? Number(m[3]) : y, monthIndex(m[1]), Number(m[2]), !!m[3])
  m = s.match(/^(\d{1,2}) ([a-z]{3,})(?: (\d{4}))?$/)
  if (m && monthIndex(m[2])) return buildDate(today, m[3] ? Number(m[3]) : y, monthIndex(m[2]), Number(m[1]), !!m[3])
  return null
}

// Sync profiles. Live suits Airtable Team and up (no enforced monthly cap);
// Light keeps a Free workspace well under its 1,000 calls a month.
//   mode: "Auto" | "Light" | "Live" (the setting); plan: "free" | "team"
function profile(mode, plan) {
  if (mode === "Light") return "light"
  if (mode === "Live") return "live"
  return plan === "team" ? "live" : "light"
}

// Background refresh in seconds. override 0 means the profile default; a
// smaller override is raised to the profile minimum. Light slows to two
// hours once 80% of the Free plan's monthly calls are used.
function refreshSeconds(prof, override, calls, freeMonthly) {
  var live = prof === "live"
  var base = override > 0 ? Math.max(override, live ? 300 : 900) : (live ? 300 : 1800)
  if (!live && freeMonthly > 0 && calls >= 0.8 * freeMonthly) return Math.max(base, 7200)
  return base
}
