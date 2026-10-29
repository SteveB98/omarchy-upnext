# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Running the tests

Everything runs offline, with a fake `curl` and keyring:

```bash
tests/run.sh               # the upnext bridge, setup included
node tests/date.test.mjs   # date parsing and sync timing
shellcheck -x upnext tests/run.sh tests/bin/* tools/hooks/* tools/demo/upnext tools/release-check
```

## Trying UI changes without Airtable

`tools/demo/upnext` prints made-up tasks. Copy it over the `upnext` in your
installed plugin folder (it's a git checkout, so `git checkout upnext` puts the
real one back), and pick a state with
`echo light > "$XDG_RUNTIME_DIR/upnext-demo"` (`live`, `light`, `limit`, `setup`).

## Pull requests

- Keep the widget free of network code: Airtable calls belong in `upnext`,
  which prints one line of JSON per command.
- Add or update tests for bridge changes.
- Run `tools/hooks/enable` once after cloning. The hooks keep commit trailers
  that credit AI tools out of the history; commits are credited to people.
