# Changelog

## 1.0.0 (unreleased)

First public release.

- Bar widget: checklist icon and the number of tasks due today, red when
  anything is overdue. Left-click opens the panel, middle-click opens quick add,
  right-click opens the table in Airtable.
- Panel: Today / Tomorrow / Week / Month (next 31 days) tabs, overdue first,
  priority dots and project names, pages with pager, wheel and keys. Click the
  circle to mark a task done; click again to undo. Delete a task with the
  trash icon (or `x`), which asks once before it deletes.
- Quick add with natural dates (`fri`, `+3`, `oct 20`, `4 weeks from today`,
  `in 3 days`, `next month`), a project search and
  "+ New project".
- Works with any Airtable table: `upnext setup` reads the base's schema and
  matches name, status, due date, priority, start date and project fields.
  Ready-made template base for a two-minute start.
- Free and Team plans: Live sync (every 5 minutes) or Light sync (every 30
  minutes, usage shown in the panel). Switches to Light automatically if
  Airtable reports the Free plan's monthly API limit.
- Settings: `maxRows`, `syncMode`, `refreshIntervalSec`, `weekStart`.
- Security: the token lives in the system keyring and reaches `curl` through
  `/dev/fd`, never the command line; IDs are validated and formula values
  escaped.
