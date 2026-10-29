import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DateParse.js" as DateParse

// Up Next: upcoming tasks from an Airtable table.
// The bar shows a checklist icon plus how many open tasks are due today or
// overdue; the panel lists them under Today / Tomorrow / Week / Month tabs and
// ticking one sets its status to the mapped "done" status in Airtable.
//
// All Airtable traffic goes through ./upnext (curl + jq, token from the
// desktop keyring). `upnext setup` maps the table's fields and statuses into
// ~/.config/upnext/config.json; `upnext config` hands this widget the parts it
// needs. One fetch pulls every open task with a due date; the tabs are just
// local date windows over that list, so switching is instant.
//
// Sync follows the Airtable plan: Live (Team and up) refreshes every 5
// minutes and on open/close; Light (Free, 1,000 API calls a month per
// workspace) every 30 minutes and on open when the list is over 2 minutes old.
//
// "+" swaps the list for an add form (Name, Project, Start, Due) in the same
// panel. Typing a project name that doesn't exist offers a "New project" row;
// the project is created in Airtable just before the task.
Panel {
  id: root
  moduleName: "io.github.steveb98.upnext"
  ipcTarget: "io.github.steveb98.upnext"

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.8)
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string listGlyph: String.fromCodePoint(0xF0756)
  readonly property string openGlyph: String.fromCodePoint(0xF0130)
  readonly property string doneGlyph: String.fromCodePoint(0xF0133)
  readonly property string refreshGlyph: String.fromCodePoint(0xF0450)
  readonly property string addGlyph: String.fromCodePoint(0xF0415)

  readonly property int maxRows: setting("maxRows", 5)
  readonly property int refreshIntervalSec: setting("refreshIntervalSec", 0)
  readonly property string syncMode: setting("syncMode", "Auto")
  readonly property string weekStart: setting("weekStart", "Monday")

  readonly property string helper: String(Qt.resolvedUrl("upnext")).replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- config
  // From `upnext config`; empty until setup has run.

  property bool configured: false
  property string tableUrl: ""
  property string doneStatus: "Done"
  property string newStatus: ""
  property var priorities: []
  property bool projectsEnabled: false
  property string plan: "free"
  property string planSource: ""
  property int calls: 0
  property int freeMonthly: 1000

  readonly property string profile: DateParse.profile(syncMode, plan)
  readonly property bool live: profile === "live"
  readonly property int refreshSec: DateParse.refreshSeconds(profile, refreshIntervalSec, calls, freeMonthly)
  property double lastFetchAt: 0

  // ---------------------------------------------------------------- state

  property var tasks: []
  property bool loaded: false
  property bool loading: false
  property string errorCode: ""
  property string errorMessage: ""
  property string tab: "today"
  property int cursor: 0
  property int page: 0
  property real rowHeight: 0   // measured from a delegate; all rows are one size
  property var queue: []       // pending status changes: { id, status, prev }

  property string mode: "list" // "list" or "add"
  property string flash: ""    // brief confirmation shown in the header
  property var projects: []    // { id, name, client, status }, not Completed
  property double projectsFetchedAt: 0
  property var selectedProject: null
  property int projCursor: 0
  property string formError: ""

  // Date strings are local "YYYY-MM-DD", which compare correctly as text.
  property string today: iso(new Date())
  readonly property string weekEnd: DateParse.weekEnd(today, weekStart)
  // "Month" is a rolling window (today through the next 31 days), not the
  // calendar month, so late in a month it still looks a few weeks ahead.
  readonly property string monthEnd: addDays(31)

  readonly property var tabs: [
    { value: "today", label: "Today" },
    { value: "tomorrow", label: "Tomorrow" },
    { value: "week", label: "Week" },
    { value: "month", label: "Month" }
  ]

  readonly property var openTasks: tasks.filter(function(t) { return t.status !== root.doneStatus })
  readonly property int overdueCount: openTasks.filter(function(t) { return t.due < today }).length
  readonly property int dueNowCount: openTasks.filter(function(t) { return t.due <= today }).length

  readonly property var tabTasks: tasksFor(tab)
  // Pages of maxRows. The list keeps a full page's height on every page so
  // the panel never resizes while flipping.
  readonly property int pageCount: Math.max(1, Math.ceil(tabTasks.length / maxRows))
  readonly property var shownTasks: tabTasks.slice(page * maxRows, (page + 1) * maxRows)

  // ---------------------------------------------------------------- helpers

  function iso(d) { return DateParse.iso(d) }
  function parseIso(s) { return DateParse.parseIso(s) }

  readonly property string tomorrow: addDays(1)

  function rangeEnd(which) {
    return which === "today" ? today : which === "week" ? weekEnd : monthEnd
  }

  // Today / This Week / This Month are "due by" windows, so overdue tasks
  // head them. Tomorrow is just the tasks due tomorrow.
  function inTab(which, due) {
    return which === "tomorrow" ? due === tomorrow : due <= rangeEnd(which)
  }

  // Priority options rank in their Airtable order (first = most urgent).
  function priorityRank(p) {
    var r = priorities.indexOf(p)
    return r < 0 ? priorities.length : r
  }

  // Overdue first, then by due date, then priority. Tasks ticked this
  // session stay in place (struck through) so a mis-click can be undone.
  function tasksFor(which) {
    return tasks.filter(function(t) { return inTab(which, t.due) })
      .sort(function(a, b) {
        if (a.due !== b.due) return a.due < b.due ? -1 : 1
        return priorityRank(a.priority) - priorityRank(b.priority)
      })
  }

  function openCountFor(which) {
    return openTasks.filter(function(t) { return inTab(which, t.due) }).length
  }

  function dueLabel(due) {
    if (due === today) return "Today"
    var days = Math.round((parseIso(due) - parseIso(today)) / 86400000)
    if (days < 0) return days === -1 ? "Overdue · yesterday" : "Overdue · " + (-days) + " days"
    if (days === 1) return "Tomorrow"
    var d = parseIso(due)
    if (due <= weekEnd) return d.toLocaleDateString(Qt.locale(), "dddd")
    return d.toLocaleDateString(Qt.locale(), "ddd MMM d")
  }

  // Up to four colors from the least urgent end, so a High/Medium/Low base
  // gets purple/yellow/blue and only a fourth, top option gets the alarm red.
  readonly property var priorityColors: [root.urgent, "#b48ead", "#ebcb8b", "#81a1c1"]
  function priorityColor(p) {
    var r = priorities.indexOf(p)
    if (r < 0) return root.faint
    var i = r + Math.max(0, 4 - priorities.length)
    return i < 4 ? priorityColors[i] : root.faint
  }

  readonly property bool needsSetup: errorCode === "no-token" || errorCode === "no-config"
    || errorCode === "auth" || errorCode === "access" || errorCode === "config"

  function errorHint(code) {
    if (code === "no-token" || code === "no-config") return "Connect an Airtable table to see your tasks here. It takes about 2 minutes."
    if (code === "auth") return "Airtable rejected the saved token. Run setup to paste a new one."
    if (code === "access") return "The token needs data.records:read, data.records:write and schema.bases:read, with access to this base."
    if (code === "config") return "A field or status changed in Airtable. Run setup to match them again."
    if (code === "monthly-limit") return "It resets on the 1st. Up Next has switched to light sync; see the README's \"Free or Team?\" section."
    return ""
  }

  // ---------------------------------------------------------------- dates

  function addDays(n) { return DateParse.addDays(today, n) }

  // Loose date input -> "YYYY-MM-DD", "" for blank, or null if unreadable.
  // today, tomorrow, +3, +2w, fri, next fri, oct 20, 20 oct, 10/20, 2026-10-20
  function parseDate(input) { return DateParse.parseDate(input, today) }

  function prettyDate(isoDate) {
    var d = parseIso(isoDate).toLocaleDateString(Qt.locale(), "ddd MMM d")
    if (isoDate === today) return "Today · " + d
    if (isoDate === addDays(1)) return "Tomorrow · " + d
    return d
  }

  // ---------------------------------------------------------------- add form

  readonly property var startParsed: parseDate(startField.text)
  readonly property var dueParsed: parseDate(dueField.text)
  readonly property string addProblem: {
    if (nameField.text.trim() === "") return "Name the task"
    if (dueParsed === "") return "Pick a due date"
    if (dueParsed === null) return "Due date isn't a date"
    if (startParsed === null) return "Start date isn't a date"
    if (startParsed !== "" && startParsed > dueParsed) return "Start is after the due date"
    if (projectsEnabled && projField.text.trim() !== "" && !selectedProject) return "Pick a project from the list, or clear it"
    return ""
  }

  // Up to 4 existing projects, then a "New project" row (isNew, no id yet)
  // unless the typed text already names one.
  readonly property var projMatches: {
    if (selectedProject && projField.text === selectedProject.name) return []
    var typed = projField.text.trim()
    var q = typed.toLowerCase()
    var found = projects.filter(function(p) {
      return q === "" || (p.name + " " + p.client).toLowerCase().indexOf(q) !== -1
    }).slice(0, 4)
    var exists = projects.some(function(p) { return p.name.toLowerCase() === q })
    if (q !== "" && !exists) found.push({ id: "", name: typed, client: "", status: "", isNew: true })
    return found
  }
  readonly property bool showMatches: mode === "add" && projField.activeFocus && projMatches.length > 0

  function startAdd() {
    root.formError = ""
    root.selectedProject = null
    root.projCursor = 0
    nameField.text = ""
    projField.text = ""
    startField.text = "today"
    dueField.text = ""
    root.mode = "add"
    // Project list: 10 minutes old is fine on Live, an hour on Light.
    var projectsTtl = (root.live ? 10 : 60) * 60 * 1000
    if (projectsEnabled && Date.now() - projectsFetchedAt > projectsTtl && !projProc.running) projProc.running = true
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function endAdd() {
    root.mode = "list"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Middle-click on the bar icon lands straight in the form.
  function openAdd() {
    if (!root.opened) root.open()
    startAdd()
  }

  function pickProject(p) {
    if (!p) return
    root.selectedProject = p
    projField.text = p.name
    startField.forceActiveFocus()
    startField.selectAll()
  }

  function submitAdd() {
    if (addProblem !== "" || addProc.running || newProjProc.running) {
      root.formError = addProblem
      return
    }
    root.formError = ""
    // A new project is created first; applyNewProject() then calls back here
    // with the real record, so a failed task add never duplicates the project.
    if (selectedProject && selectedProject.isNew) {
      newProjProc.command = [root.helper, "newproject", selectedProject.name]
      newProjProc.running = true
      return
    }
    addProc.due = dueParsed
    addProc.name = nameField.text.trim()
    addProc.command = [root.helper, "add", addProc.name,
      selectedProject ? selectedProject.id : "-",
      startParsed !== "" ? startParsed : "-",
      dueParsed]
    addProc.running = true
  }

  function applyNewProject(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Unexpected reply from upnext" } }
    if (!r.ok) {
      root.formError = r.message || "Couldn't create the project"
      return
    }
    root.projects = root.projects.concat([r.project]).sort(function(a, b) {
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    })
    root.selectedProject = r.project
    submitAdd()
  }

  function applyAdd(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Unexpected reply from upnext" } }
    if (!r.ok) {
      root.formError = r.message || "Couldn't add the task"
      return
    }
    var due = addProc.due
    root.tab = due <= today ? "today" : due === tomorrow ? "tomorrow" : due <= weekEnd ? "week" : "month"
    root.flash = "Added: " + addProc.name
    flashTimer.restart()
    endAdd()
    root.refresh()
  }

  Timer {
    id: flashTimer
    interval: 4000
    onTriggered: root.flash = ""
  }

  Process {
    id: configProc
    command: [root.helper, "config"]
    stdout: StdioCollector {
      onStreamFinished: root.applyConfig(text)
    }
  }

  function loadConfig() {
    if (!configProc.running) configProc.running = true
  }

  function applyConfig(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false } }
    root.configured = !!r.ok
    if (!r.ok) {
      if (r.error === "no-config") {
        root.errorCode = "no-config"
        root.errorMessage = r.message || "Up Next isn't set up yet"
        root.tasks = []
      }
      return
    }
    root.tableUrl = r.tableUrl
    root.doneStatus = r.done
    root.newStatus = r.new
    root.priorities = r.priorities || []
    root.projectsEnabled = !!r.projects
    root.plan = r.plan
    root.planSource = r.planSource || ""
    root.calls = r.calls || 0
    root.freeMonthly = r.freeMonthly || 1000
    if (root.errorCode === "no-config") {
      root.errorCode = ""
      root.errorMessage = ""
      root.refresh()
    }
  }

  // Setup is interactive (browser + pasting a token and picking fields), so
  // it runs in Omarchy's floating terminal rather than in the panel.
  function shq(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }

  function runSetup() {
    // Quoted twice: bar.run's bash, then the launcher's own bash -c.
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation " + shq(shq(root.helper) + " setup"))
    root.close()
  }

  Process {
    id: projProc
    command: [root.helper, "projects"]
    stdout: StdioCollector {
      onStreamFinished: {
        var r
        try { r = JSON.parse(text) } catch (e) { r = { ok: false } }
        if (r.ok) {
          root.projects = r.projects || []
          root.projectsFetchedAt = Date.now()
        }
      }
    }
  }

  Process {
    id: newProjProc
    stdout: StdioCollector {
      onStreamFinished: root.applyNewProject(text)
    }
  }

  Process {
    id: addProc
    property string due: ""
    property string name: ""
    stdout: StdioCollector {
      onStreamFinished: root.applyAdd(text)
    }
  }

  // ---------------------------------------------------------------- airtable

  Process {
    id: fetchProc
    command: [root.helper, "fetch"]
    stdout: StdioCollector {
      onStreamFinished: root.applyFetch(text)
    }
    onRunningChanged: root.loading = running
  }

  function refresh() {
    root.today = iso(new Date())
    if (fetchProc.running || setProc.running || queue.length > 0) return
    fetchProc.running = true
  }

  // Light sync skips a fetch when the list is under 2 minutes old.
  function refreshIfStale() {
    if (root.live || Date.now() - root.lastFetchAt > 2 * 60 * 1000) root.refresh()
    else root.today = iso(new Date())
  }

  function applyFetch(text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, error: "parse", message: "Unexpected reply from upnext" } }
    if (r.ok) {
      root.tasks = r.tasks || []
      root.errorCode = ""
      root.errorMessage = ""
      root.loaded = true
      root.lastFetchAt = Date.now()
      if (r.plan) root.plan = r.plan
      if (r.calls !== undefined) root.calls = r.calls
    } else {
      root.errorCode = r.error || "unknown"
      root.errorMessage = r.message || "Couldn't load tasks"
      if (root.needsSetup) root.tasks = []
      // upnext has already switched the saved plan to free.
      if (root.errorCode === "monthly-limit") {
        root.plan = "free"
        root.planSource = "billing-error"
      }
      if (root.errorCode === "no-config") root.configured = false
    }
    root.clampCursor()
  }

  Process {
    id: setProc
    property var job: null
    stdout: StdioCollector {
      onStreamFinished: root.applySet(setProc.job, text)
    }
  }

  function withStatus(id, status) {
    root.tasks = root.tasks.map(function(t) {
      if (t.id !== id) return t
      return { id: t.id, name: t.name, project: t.project, due: t.due, priority: t.priority,
               status: status, prev: status === root.doneStatus ? t.status : undefined }
    })
  }

  // Optimistic: the row flips immediately, and is flipped back if Airtable
  // refuses. Ticking a Done row restores the status it had before.
  function toggleDone(task) {
    if (!task) return
    var next = task.status === root.doneStatus ? (task.prev || root.newStatus) : root.doneStatus
    withStatus(task.id, next)
    root.queue = root.queue.concat([{ id: task.id, status: next, prev: task.status, prevPrev: task.prev }])
    pumpQueue()
  }

  function pumpQueue() {
    if (setProc.running || queue.length === 0) return
    setProc.job = queue[0]
    root.queue = queue.slice(1)
    setProc.command = [root.helper, "set", setProc.job.id, setProc.job.status]
    setProc.running = true
  }

  function applySet(job, text) {
    var r
    try { r = JSON.parse(text) } catch (e) { r = { ok: false, message: "Unexpected reply from upnext" } }
    if (!r.ok && job) {
      root.tasks = root.tasks.map(function(t) {
        if (t.id !== job.id) return t
        return { id: t.id, name: t.name, project: t.project, due: t.due, priority: t.priority,
                 status: job.prev, prev: job.prevPrev }
      })
      root.errorCode = r.error || "unknown"
      root.errorMessage = r.message || "Couldn't update the task"
    }
    Qt.callLater(root.pumpQueue)
  }

  // Only Airtable links (built by upnext from validated ids) are opened.
  function openUrl(url) {
    if (!/^https:\/\/airtable\.com\/[A-Za-z0-9\/]+$/.test(url)) return
    if (bar) bar.run("omarchy-launch-webapp " + shq(url))
    root.close()
  }
  function openTask(task) { if (task && tableUrl !== "") openUrl(tableUrl + "/" + task.id) }

  Component.onCompleted: loadConfig()

  Timer {
    interval: root.refreshSec * 1000
    repeat: true
    running: root.configured
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Opening shows a current list (on Light, unless it's under 2 minutes
  // old). Closing drops ticked rows; Live also refetches then.
  onOpenedChanged: {
    root.page = 0
    root.cursor = 0
    if (root.opened) {
      root.loadConfig()
      if (root.configured) root.refreshIfStale()
      return
    }
    root.mode = "list"
    root.tasks = root.tasks.filter(function(t) { return t.status !== root.doneStatus })
    if (root.live && root.configured) root.refresh()
  }
  onTabChanged: {
    root.page = 0
    root.cursor = 0
  }

  function clampCursor() {
    root.page = Math.max(0, Math.min(root.page, root.pageCount - 1))
    root.cursor = Math.max(0, Math.min(root.cursor, root.shownTasks.length - 1))
  }

  function flipPage(direction) {
    var next = Math.max(0, Math.min(root.pageCount - 1, root.page + direction))
    if (next === root.page) return
    root.page = next
    clampCursor()
  }

  // j/k past the edge of a page carries on into the next or previous one.
  function moveCursor(dy) {
    var c = root.cursor + dy
    if (c >= root.shownTasks.length && root.page < root.pageCount - 1) {
      root.page++
      root.cursor = 0
    } else if (c < 0 && root.page > 0) {
      root.page--
      root.cursor = root.shownTasks.length - 1
    } else {
      root.cursor = Math.max(0, Math.min(root.shownTasks.length - 1, c))
    }
  }

  function switchTab(direction) {
    var i = 0
    for (var k = 0; k < tabs.length; k++) if (tabs[k].value === tab) i = k
    i = Math.max(0, Math.min(tabs.length - 1, i + direction))
    root.tab = tabs[i].value
  }

  // ---------------------------------------------------------------- bar

  implicitWidth: root.vertical ? root.barSize : barRow.implicitWidth + Style.space(14)
  implicitHeight: root.vertical ? Style.bar.iconSlot : root.barSize

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.listGlyph
      color: root.overdueCount > 0 ? root.urgent
           : root.errorCode !== "" && !root.loaded ? Qt.darker(root.barForeground, 1.6)
           : root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      Behavior on color { ColorAnimation { duration: 160 } }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.vertical && root.dueNowCount > 0
      text: String(root.dueNowCount)
      color: root.overdueCount > 0 ? root.urgent : root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.openUrl(root.tableUrl)
      else if (mouse.button === Qt.MiddleButton && root.configured) root.openAdd()
      else root.toggle()
    }
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root,
      root.errorCode !== "" && !root.loaded ? "Up Next: " + root.errorMessage
      : root.dueNowCount === 0 ? "Nothing due today"
      : root.dueNowCount + (root.dueNowCount === 1 ? " task" : " tasks") + " due today"
        + (root.overdueCount > 0 ? " (" + root.overdueCount + " overdue)" : ""))
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.mode === "add" ? nameField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // In the form, keys belong to the text fields.
      blocked: root.mode === "add"

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.switchTab(dx)
        else root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.needsSetup) root.runSetup()
        else root.toggleDone(root.shownTasks[root.cursor])
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "o" || t === "O") root.openTask(root.shownTasks[root.cursor])
        else if (t === "a" || t === "A") root.openUrl(root.tableUrl)
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "1") root.tab = "today"
        else if (t === "2") root.tab = "tomorrow"
        else if (t === "3") root.tab = "week"
        else if (t === "4") root.tab = "month"
        else if (t === "n" || t === "N" || t === "]") root.flipPage(1)
        else if (t === "p" || t === "P" || t === "[") root.flipPage(-1)
        else if ((t === "+" || t === "c" || t === "C") && root.configured) root.startAdd()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Header ----------
        Item {
          width: parent.width
          height: Math.max(heading.implicitHeight, refreshButton.implicitHeight)

          Text {
            id: heading
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            width: parent.width - headerButtons.width - Style.space(8)
            elide: Text.ElideRight
            text: root.mode === "add" ? "NEW TASK" : root.flash !== "" ? root.flash : "UPCOMING TASKS"
            color: root.flash !== "" && root.mode === "list" ? Color.accent : root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
            font.bold: true
          }

          Row {
            id: headerButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            visible: root.mode === "list" && root.configured

            Button {
              iconText: root.addGlyph
              tooltipText: "Add task (+)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.startAdd()
            }

            Button {
              id: refreshButton
              iconText: root.refreshGlyph
              iconSpinning: root.loading
              tooltipText: "Refresh (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }
        }

        // ================================================== list view
        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.mode === "list"

          // ---------- Tabs ----------
          // Each tab is as wide as its label plus an equal share of the
          // leftover width, so the row fills the panel and long labels
          // ("Tomorrow  12") never touch their border. If the labels can't
          // fit at all, the row drops to the smaller font.
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(6)
            visible: root.configured

            readonly property real naturalWidth: {
              var w = spacing * Math.max(0, tabRepeater.count - 1)
              for (var i = 0; i < tabRepeater.count; i++) {
                var item = tabRepeater.itemAt(i)
                if (item) w += item.implicitWidth
              }
              return w
            }
            property bool compact: false
            onNaturalWidthChanged: if (naturalWidth > width) compact = true
            readonly property real slack: Math.max(0, (width - naturalWidth) / Math.max(1, tabRepeater.count))

            Repeater {
              id: tabRepeater
              model: root.tabs

              delegate: Button {
                required property var modelData
                readonly property int count: root.openCountFor(modelData.value)
                width: implicitWidth + tabRow.slack
                horizontalPadding: Style.space(8)
                fontSize: tabRow.compact ? Style.font.bodySmall : Style.font.body
                text: modelData.label + (count > 0 ? "  " + count : "")
                bordered: true
                selected: root.tab === modelData.value
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.tab = modelData.value
              }
            }
          }

          // ---------- Error ----------
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.errorCode !== ""

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.errorMessage
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: text !== ""
              text: root.errorHint(root.errorCode)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          Button {
            width: parent.width
            visible: root.needsSetup
            text: root.configured ? "Run setup again" : "Set up Up Next"
            iconText: root.listGlyph
            bordered: true
            selected: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.runSetup()
          }

          // ---------- Empty ----------
          Text {
            width: parent.width
            visible: root.loaded && root.shownTasks.length === 0
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(6)
            bottomPadding: Style.space(6)
            text: root.tab === "today" ? "Nothing due today" : root.tab === "tomorrow" ? "Nothing due tomorrow" : root.tab === "week" ? "Nothing due this week" : "Nothing due in the next 31 days"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---------- Rows ----------
          Column {
            id: rows
            width: parent.width
            spacing: Style.space(2)
            visible: root.shownTasks.length > 0
            height: root.pageCount > 1 && root.rowHeight > 0
              ? root.maxRows * root.rowHeight + (root.maxRows - 1) * spacing
              : implicitHeight

            // Wheel / two-finger scroll flips pages. Touchpads send many small
            // deltas, so flip once per notch's worth (120).
            WheelHandler {
              property real acc: 0
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) {
                acc += event.angleDelta.y
                if (acc <= -120) { acc = 0; root.flipPage(1) }
                else if (acc >= 120) { acc = 0; root.flipPage(-1) }
              }
            }

            Repeater {
              model: root.shownTasks

              delegate: Rectangle {
                id: row
                required property var modelData
                required property int index

                onHeightChanged: if (height > root.rowHeight) root.rowHeight = height

                readonly property bool done: modelData.status === root.doneStatus
                readonly property bool overdue: !done && modelData.due < root.today
                readonly property bool hot: rowMouse.containsMouse || checkMouse.containsMouse || root.cursor === index

                width: parent.width
                height: rowContent.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                // Whole row opens the record; only the circle completes it,
                // so a stray click never marks something done.
                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = row.index
                  onClicked: root.openTask(row.modelData)
                }

                Row {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(10)

                  Text {
                    id: check
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: row.done ? root.doneGlyph : root.openGlyph
                    color: row.done ? Color.accent : checkMouse.containsMouse ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.iconLarge

                    MouseArea {
                      id: checkMouse
                      anchors.fill: parent
                      anchors.margins: -Style.space(6)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: root.cursor = row.index
                      onClicked: root.toggleDone(row.modelData)
                    }
                  }

                  Column {
                    width: parent.width - check.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: row.modelData.name
                      color: row.done ? root.faint : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: row.done
                      elide: Text.ElideRight
                    }

                    Row {
                      width: parent.width
                      spacing: Style.space(6)
                      opacity: row.done ? 0.6 : 1.0

                      Text {
                        id: dot
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.modelData.priority !== ""
                        textFormat: Text.PlainText
                        text: "●"
                        color: root.priorityColor(row.modelData.priority)
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        id: due
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: root.dueLabel(row.modelData.due)
                        color: row.overdue ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: row.overdue
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width - due.width - (dot.visible ? dot.width + parent.spacing : 0) - parent.spacing)
                        visible: row.modelData.project !== ""
                        textFormat: Text.PlainText
                        text: "·  " + row.modelData.project
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- Pager ----------
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)
            visible: root.pageCount > 1

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0141)
              tooltipText: "Previous page (p)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.page > 0
              opacity: enabled ? 1.0 : 0.35
              onClicked: root.flipPage(-1)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: (root.page + 1) + " / " + root.pageCount
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0142)
              tooltipText: "Next page (n)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.page < root.pageCount - 1
              opacity: enabled ? 1.0 : 0.35
              onClicked: root.flipPage(1)
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Button {
            width: parent.width
            visible: root.configured
            text: "Open in Airtable"
            iconText: root.listGlyph
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openUrl(root.tableUrl)
          }

          // ---------- Sync ----------
          // Light sync shows the month's API calls against the Free plan cap
          // (Up Next's own calls; other tools share the workspace's cap).
          Text {
            width: parent.width
            visible: root.configured && !root.live
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: (root.planSource === "billing-error" ? "Airtable's monthly limit was reached, so sync is light. " : "Light sync · ")
              + root.calls.toLocaleString(Qt.locale(), "f", 0) + " API calls this month"
              + (root.plan === "free" ? " (Free plan: " + root.freeMonthly.toLocaleString(Qt.locale(), "f", 0) + " per workspace)" : "")
            color: root.calls >= 0.8 * root.freeMonthly && root.plan === "free" ? root.urgent : root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ================================================== add form
        Item {
          id: addForm
          width: parent.width
          height: formColumn.implicitHeight
          visible: root.mode === "add"

          // Esc backs out of the form (or just closes the project matches).
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (root.showMatches) startField.forceActiveFocus()
              else root.endAdd()
              event.accepted = true
            }
          }

          Column {
            id: formColumn
            width: parent.width
            spacing: Style.space(10)

            // ---------- Name ----------
            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Name"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: nameField
                width: parent.width
                placeholderText: "What needs doing?"
                foreground: root.foreground
                font.family: root.fontFamily
                KeyNavigation.tab: root.projectsEnabled ? projField : startField
                Keys.onReturnPressed: (root.projectsEnabled ? projField : startField).forceActiveFocus()
                Keys.onEnterPressed: (root.projectsEnabled ? projField : startField).forceActiveFocus()
              }
            }

            // ---------- Project ----------
            // The match list floats over the fields below it so the panel
            // doesn't grow while typing.
            Item {
              width: parent.width
              height: visible ? projColumn.implicitHeight : 0
              visible: root.projectsEnabled
              z: 10

              Column {
                id: projColumn
                width: parent.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  height: projLabel.implicitHeight

                  Text {
                    id: projLabel
                    textFormat: Text.PlainText
                    text: "Client / Project"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.right: parent.right
                    width: parent.width - projLabel.width - Style.space(10)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.selectedProject ? (root.selectedProject.isNew ? "New project, no client"
                          : root.selectedProject.client || "No client")
                        : projProc.running && root.projects.length === 0 ? "Loading projects…"
                        : "Optional"
                    color: root.selectedProject ? Color.accent : root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                TextField {
                  id: projField
                  width: parent.width
                  placeholderText: "Search, or type a new project"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  KeyNavigation.tab: startField
                  KeyNavigation.backtab: nameField
                  onTextEdited: {
                    root.selectedProject = null
                    root.projCursor = 0
                  }
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Down && root.projMatches.length > 0) {
                      root.projCursor = Math.min(root.projMatches.length - 1, root.projCursor + 1)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up && root.projMatches.length > 0) {
                      root.projCursor = Math.max(0, root.projCursor - 1)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      if (root.showMatches) root.pickProject(root.projMatches[root.projCursor])
                      else startField.forceActiveFocus()
                      event.accepted = true
                    }
                  }
                }
              }

              Rectangle {
                id: matchList
                y: projColumn.height + Style.space(2)
                width: parent.width
                height: matchColumn.implicitHeight + Style.space(6)
                visible: root.showMatches
                radius: Style.cornerRadius
                color: Color.popups.background
                border.color: Qt.darker(root.foreground, 1.8)
                border.width: 1

                Column {
                  id: matchColumn
                  x: Style.space(3)
                  y: Style.space(3)
                  width: parent.width - Style.space(6)

                  Repeater {
                    model: root.projMatches

                    delegate: Rectangle {
                      required property var modelData
                      required property int index
                      width: parent.width
                      height: matchRow.implicitHeight + Style.space(10)
                      radius: Style.cornerRadius
                      color: root.projCursor === index || matchMouse.containsMouse
                        ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                      Row {
                        id: matchRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                          id: matchName
                          width: Math.min(implicitWidth, parent.width * 0.6)
                          textFormat: Text.PlainText
                          text: modelData.name
                          color: root.foreground
                          elide: Text.ElideRight
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }
                        Text {
                          width: parent.width - matchName.width - parent.spacing
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: modelData.isNew ? root.addGlyph + " New project" : modelData.client
                          color: modelData.isNew ? Color.accent : root.faint
                          elide: Text.ElideRight
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      MouseArea {
                        id: matchMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.projCursor = index
                        onClicked: root.pickProject(modelData)
                      }
                    }
                  }
                }
              }
            }

            // ---------- Start / Due ----------
            Row {
              width: parent.width
              spacing: Style.space(10)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Start"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: startField
                  // Typing replaces the pre-filled date rather than appending to it.
                  onActiveFocusChanged: if (activeFocus) selectAll()
                  width: parent.width
                  placeholderText: "today"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  KeyNavigation.tab: dueField
                  KeyNavigation.backtab: root.projectsEnabled ? projField : nameField
                  Keys.onReturnPressed: dueField.forceActiveFocus()
                  Keys.onEnterPressed: dueField.forceActiveFocus()
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.startParsed === null ? "Not a date I know"
                      : root.startParsed === "" ? "Optional"
                      : root.prettyDate(root.startParsed)
                  color: root.startParsed === null ? root.urgent : root.startParsed === "" ? root.faint : Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Due"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                TextField {
                  id: dueField
                  // Typing replaces the pre-filled date rather than appending to it.
                  onActiveFocusChanged: if (activeFocus) selectAll()
                  width: parent.width
                  placeholderText: "e.g. fri"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  KeyNavigation.tab: nameField
                  KeyNavigation.backtab: startField
                  Keys.onReturnPressed: root.submitAdd()
                  Keys.onEnterPressed: root.submitAdd()
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.dueParsed === null ? "Not a date I know"
                      : root.dueParsed === "" ? "fri, +3, oct 20, 10/20"
                      : root.prettyDate(root.dueParsed)
                  color: root.dueParsed === null ? root.urgent : root.dueParsed === "" ? root.faint : Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---------- Error + actions ----------
            Text {
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.formError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Item {
              width: parent.width
              height: addButton.implicitHeight

              Button {
                anchors.left: parent.left
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.endAdd()
              }

              Button {
                id: addButton
                anchors.right: parent.right
                text: newProjProc.running ? "Creating project…" : addProc.running ? "Adding…" : "Add Task"
                iconText: root.addGlyph
                bordered: true
                selected: root.addProblem === ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                opacity: root.addProblem === "" && !addProc.running && !newProjProc.running ? 1.0 : 0.5
                tooltipText: root.addProblem
                onClicked: root.submitAdd()
              }
            }
          }
        }
      }
    }
  }
}
