# Changelog

## 1.0.1 (2026-10-31)

Security: what you type no longer appears in process arguments, which other
accounts on the same computer can read.

- Adding a task or project, and ticking one, sends the name, dates and status
  to the `upnext` helper as JSON on stdin instead of as arguments.
- `upnext` passes request bodies and the status filter to `curl` on stdin or as
  `/dev/fd` files, and values to `jq` through stdin or the environment.
  Airtable's error text is handled the same way.
- Setup lists base, table, field and status names to `gum` on stdin.
- `upnext add`, `newproject` and `set` now read their details as one line of
  JSON on stdin (see the header of `upnext`).
- A canary test and a release check keep it that way.

## 1.0.0 (2026-10-30)

First public release.

- Bar widget: checklist icon and the number of tasks due today, red when
  anything is overdue. Left-click opens the panel, middle-click opens quick add,
  right-click opens the table in Airtable.
- Panel: Today / Tomorrow / Week / Month (next 31 days) tabs, overdue first,
  priority dots and project names, pages with pager, wheel and keys. Click the
  circle to mark a task done; click again to undo. Delete a task with the
  trash icon (or `x`), which asks once before it deletes.
- Quick add with natural dates (`fri`, `+3`, `oct 20`, `4 weeks from today`,
  `in 3 days`, `next month`), a project search and "+ New project".
- Open the panel from any window with a key you bind to
  `omarchy-shell io.github.steveb98.upnext toggle`.
- Works with any Airtable table: `upnext setup` reads the base's schema and
  matches name, status, due date, priority, start date and project fields.
  Ready-made template base for a two-minute start.
- Free and Team plans: Live sync (every 5 minutes) or Light sync (every 30 to
  120 minutes, paced to the calls left this month, usage shown in the panel).
  If Airtable reports the Free plan's monthly limit, it switches to Light and
  pauses background refreshes until the 1st.
- Settings: `maxRows`, `syncMode`, `refreshIntervalSec`, `weekStart`.
- Security: the token lives in the system keyring and reaches `curl` through
  `/dev/fd`, never the command line; IDs are validated and formula values
  escaped.
