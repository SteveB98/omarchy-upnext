# Security

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/SteveB98/omarchy-upnext/security/advisories/new),
not in a public issue. Include what you saw, the commit or version, and how to
reproduce it. Don't include your Airtable token or real task data.

Things we treat as security bugs include anything that lets another account on
the same computer read your token or your task data. For example, a value you
typed appearing in a process's arguments (`/proc/<pid>/cmdline` is readable by
every local account) or a file with loose permissions.

What Up Next does with your data is described in the README's
[Privacy and security](README.md#privacy-and-security) section.
