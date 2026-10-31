#!/bin/bash
# Offline tests for the upnext bridge: fake curl and secret-tool on PATH,
# fixture config and replies. No network, no keyring. Run: tests/run.sh
cd "$(dirname "$0")" || exit 1
HERE=$PWD
UPNEXT=$HERE/../upnext
pass=0 failed=0

# tests/bin/jq logs every jq the helper runs; this script's own checks use the
# real one, so expected values never land in argv.log.
REAL_JQ=$(command -v jq)
case $REAL_JQ in "$HERE"/*|"") echo "real jq not found on PATH"; exit 1 ;; esac
export REAL_JQ
jq() { "$REAL_JQ" "$@"; }

# send <json> <command>: the helper reads what the user typed from stdin
send() { local json=$1; shift; printf '%s\n' "$json" | "$UPNEXT" "$@"; }

reset() {
  export FAKE_DIR=$HERE/.out
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  export PATH=$HERE/bin:$PATH
  export UPNEXT_CONFIG=$FAKE_DIR/config.json UPNEXT_STATE=$FAKE_DIR/state
  cp fixtures/config.json "$UPNEXT_CONFIG"
  unset FAKE_CODE FAKE_BODY FAKE_NO_TOKEN
}

# check <description> <jq expression that must be true> <json>
check() {
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then
    pass=$((pass + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1"; echo "      got: $3"
  fi
}

reset
out=$("$UPNEXT" fetch)
check "fetch ok" '.ok and .plan == "team"' "$out"
check "fetch drops tasks without a due date" '.tasks | length == 2' "$out"
check "fetch maps fields by id" '.tasks[0] | .name == "Write README" and .due == "2026-10-28" and .priority == "High" and .status == "Next"' "$out"
check "missing name becomes Untitled" '.tasks[1].name == "Untitled"' "$out"
check "dateTime due becomes a local date" '.tasks[1].due | test("^2026-10-(30|31)$")' "$out"
check "linked project shows its name" '.tasks[0].project == "Launch"' "$out"
check "calls are counted" '.calls >= 2' "$out"
formula=$(grep '^filterByFormula=' "$FAKE_DIR/params.log" | head -1)
# shellcheck disable=SC1003
check "formula escapes quotes, backslashes and braces" '. == "filterByFormula=AND(OR({Status}='"'"'Inbox'"'"',{Status}='"'"'Next'"'"',{Status}='"'"'Bob\\'"'"'s \\\\ stuff'"'"'),{Due {date\\}})"' "$(jq -Rn --arg f "$formula" '$f')"
if grep -q 'Bearer\|patFake' "$FAKE_DIR/argv.log"; then
  failed=$((failed + 1)); echo "FAIL: token appeared in curl arguments"
else pass=$((pass + 1)); fi

# second fetch reuses the project-name cache (team TTL 60s): one call, not two
before=$(grep -c -- --max-time "$FAKE_DIR/argv.log")  # curl calls only
"$UPNEXT" fetch >/dev/null
after=$(grep -c -- --max-time "$FAKE_DIR/argv.log")
check "project names are cached" ". == 1" "$((after - before))"

reset
out=$(send '{"id":"recTask0000000001","status":"Done"}' set)
check "set ok" '.ok and .status == "Done"' "$out"
check "set writes the status field by id" 'test("PATCH .*/recTask0000000001 .*\"fldStatus00000001\":\"Done\"")' "$(jq -Rs . "$FAKE_DIR/writes.log")"
check "set refuses unknown statuses" '.ok == false and .error == "args"' "$(send '{"id":"recTask0000000001","status":"Bogus"}' set)"
check "set refuses bad record ids" '.ok == false and .error == "args"' "$(send '{"id":"rec;rm -rf","status":"Done"}' set)"
check "set without stdin is refused" '.ok == false and .error == "args"' "$("$UPNEXT" set </dev/null)"
check "set with junk on stdin is refused" '.ok == false and .error == "args"' "$(send 'not json' set)"

reset
out=$("$UPNEXT" delete recTask0000000001)
check "delete ok" '.ok and .deleted and .id == "recTask0000000001"' "$out"
check "delete sends DELETE for that record" 'test("^DELETE https://api.airtable.com/v0/appTestBase000001/tblTestTasks00001/recTask0000000001\n$")' "$(jq -Rs . "$FAKE_DIR/writes.log")"
check "delete refuses bad record ids" '.ok == false and .error == "args"' "$("$UPNEXT" delete 'rec;rm -rf')"
check "delete reports Airtable errors" '.ok == false and .error == "access"' "$(FAKE_CODE=404 "$UPNEXT" delete recTask0000000001)"

# a record someone already removed: the table still reads, so it's just gone
reset
check "deleting a task that's already gone succeeds" '.ok and .deleted and .gone' "$(FAKE_WRITE_CODE=404 "$UPNEXT" delete recTask0000000001)"
check "the gone check reads the table once" '. == 1' "$(grep -cF -- '-G https://api.airtable.com/v0/appTestBase000001/tblTestTasks00001 ' "$FAKE_DIR/argv.log")"
check "a 403 for one record also means gone" '.ok and .gone' "$(FAKE_WRITE_CODE=403 "$UPNEXT" delete recTask0000000001)"
check "ticking a task that's gone says so" '.ok == false and .error == "gone"' "$(FAKE_WRITE_CODE=404 send '{"id":"recTask0000000001","status":"Done"}' set)"
check "a table out of reach is still an access error" '.ok == false and .error == "access"' "$(FAKE_CODE=403 send '{"id":"recTask0000000001","status":"Done"}' set)"

reset
out=$(send '{"name":"Ship it","project":"recProj0000000001","start":"2026-10-28","due":"2026-11-02"}' add)
check "add ok" '.ok and .id == "recNew00000000001"' "$out"
body=$(sed -n 's/^POST [^ ]* //p' "$FAKE_DIR/writes.log")
check "add uses the new-task status and all mapped fields" '.fields == {"fldName0000000001":"Ship it","fldDue00000000001":"2026-11-02","fldStatus00000001":"Next","fldStart000000001":"2026-10-28","fldProject0000001":["recProj0000000001"]}' "$body"
check "add rejects bad dates" '.ok == false' "$(send '{"name":"x","due":"11/02"}' add)"
check "add rejects bad project ids" '.ok == false' "$(send '{"name":"x","project":"recX\"","due":"2026-11-02"}' add)"
check "add refuses unknown statuses" '.ok == false and .error == "args"' "$(send '{"name":"x","due":"2026-11-02","status":"Bogus"}' add)"
check "add without stdin is refused" '.ok == false and .error == "args"' "$("$UPNEXT" add </dev/null)"
reset
send '{"name":"Bare","due":"2026-11-02"}' add >/dev/null
body=$(sed -n 's/^POST [^ ]* //p' "$FAKE_DIR/writes.log")
check "add leaves out an empty start and project" '.fields == {"fldName0000000001":"Bare","fldDue00000000001":"2026-11-02","fldStatus00000001":"Next"}' "$body"

reset
out=$("$UPNEXT" projects)
check "projects sorted, with client" '.ok and (.projects | map(.name)) == ["Alpha","zeta"] and .projects[1].client == "Acme"' "$out"
check "projects hides done statuses" 'test("NOT\\(OR\\(\\{Status\\}=.Completed.\\)\\)")' "$(grep '^filterByFormula=' "$FAKE_DIR/params.log" | jq -Rs .)"

reset
out=$(send '{"name":"New thing"}' newproject)
check "newproject ok" '.ok and .project.name == "New thing" and .project.id == "recNew00000000001"' "$out"
body=$(sed -n 's/^POST [^ ]* //p' "$FAKE_DIR/writes.log")
check "newproject sets status and start" '.fields.fldPStatus0000001 == "Active" and (.fields.fldPStart00000001 | test("^[0-9-]{10}$"))' "$body"

reset
out=$("$UPNEXT" config)
check "config for the widget" '.ok and .tableUrl == "https://airtable.com/appTestBase000001/tblTestTasks00001" and .done == "Done" and .projects and .plan == "team"' "$out"
check "plan switch" '.ok and .plan == "free"' "$("$UPNEXT" plan free)"
check "plan saved" '.plan == "free" and .planSource == "user"' "$(cat "$UPNEXT_CONFIG")"
check "plan rejects junk" '.ok == false' "$("$UPNEXT" plan gold)"
check "url builds from validated ids" '. == "https://airtable.com/appTestBase000001/tblTestTasks00001/recTask0000000001"' "$("$UPNEXT" url recTask0000000001 | jq -R .)"

# ---- errors
reset; export FAKE_NO_TOKEN=1
check "no token" '.error == "no-token"' "$("$UPNEXT" fetch)"
reset; rm "$UPNEXT_CONFIG"
check "no config" '.error == "no-config"' "$("$UPNEXT" fetch)"
reset; FAKE_CODE=401 check "401 -> auth" '.error == "auth"' "$(FAKE_CODE=401 "$UPNEXT" fetch)"
reset
check "403 -> access" '.error == "access"' "$(FAKE_CODE=403 "$UPNEXT" fetch)"
check "burst 429 -> rate, plan unchanged" '.error == "rate"' "$(FAKE_CODE=429 FAKE_BODY='{"errors":[{"error":"RATE_LIMIT_REACHED"}]}' "$UPNEXT" fetch)"
check "plan still team" '.plan == "team"' "$(cat "$UPNEXT_CONFIG")"
check "billing 429 -> monthly-limit" '.error == "monthly-limit"' "$(FAKE_CODE=429 FAKE_BODY='{"error":{"type":"PUBLIC_API_BILLING_LIMIT_EXCEEDED","message":"limit"}}' "$UPNEXT" fetch)"
check "billing error flips the plan to free" '.plan == "free" and .planSource == "billing-error"' "$(cat "$UPNEXT_CONFIG")"
check "config stays private" '. == "600"' "$(stat -c %a "$UPNEXT_CONFIG" | jq -R .)"

before=$("$UPNEXT" usage | jq .calls)
check "no connection -> network" '.error == "network"' "$(FAKE_EXIT=7 "$UPNEXT" fetch)"
check "a failed connection isn't counted as a call" ". == $before" "$("$UPNEXT" usage | jq .calls)"

# 600 long-named tasks over 6 pages: far past the 128 KiB argument limit
reset
out=$(FAKE_PAGES=6 "$UPNEXT" fetch)
check "big tables page through offsets" '.ok and (.tasks | length) == 600 and .tasks[599].id == "recBig00000000599"' "$out"
check "every page was asked for" '. == 6' "$(grep -cF -- '-G https://api.airtable.com/v0/appTestBase000001/tblTestTasks00001 ' "$FAKE_DIR/argv.log")"

# the project list can't load: the tasks still come back
reset
out=$(FAKE_PROJECTS_CODE=429 FAKE_BODY='{"errors":[{"error":"RATE_LIMIT_REACHED"}]}' "$UPNEXT" fetch)
check "a project-name hiccup keeps the tasks" '.ok and (.tasks | length) == 2 and .tasks[0].project == ""' "$out"
reset
check "a project-name auth error is reported" '.ok == false and .error == "auth"' "$(FAKE_PROJECTS_CODE=401 "$UPNEXT" fetch)"

# ---- nothing private on a command line: other local accounts can read every
# process's arguments. Task and project names, dates, statuses and Airtable's
# error text must reach curl and jq through stdin, files or the environment.
reset
canary="CANARY$RANDOM"
send "{\"name\":\"$canary-task\",\"project\":\"recProj0000000001\",\"start\":\"2026-10-28\",\"due\":\"2026-11-02\"}" add >/dev/null
send "{\"name\":\"$canary-project\"}" newproject >/dev/null
send '{"id":"recTask0000000001","status":"Bob'"'"'s \\ stuff"}' set >/dev/null
"$UPNEXT" fetch >/dev/null
"$UPNEXT" projects >/dev/null
out=$(FAKE_CODE=422 FAKE_BODY="{\"error\":{\"type\":\"INVALID_VALUE\",\"message\":\"Bad value $canary-error\"}}" send '{"name":"x","due":"2026-11-02"}' add)
check "Airtable's error text still reaches the widget" ".message | contains(\"$canary-error\")" "$out"
check "the canaries really were sent" ". == 2" "$(grep -c "$canary" "$FAKE_DIR/writes.log")"
check "the status filter was still sent" 'test("Bob")' "$(grep '^filterByFormula=' "$FAKE_DIR/params.log" | jq -Rs .)"
leaks=$(grep -nE "$canary|Bob|2026-10-28|2026-11-02" "$FAKE_DIR/argv.log")
check "no name, date, status or error text in any curl or jq arguments" '. == ""' "$(jq -Rn --arg l "$leaks" '$l')"
[ -n "$leaks" ] && echo "$leaks" | head -5

# usage rolls over by month
reset
mkdir -p "$UPNEXT_STATE"
echo '{"month":"1999-01","calls":{"appTestBase000001":900}}' > "$UPNEXT_STATE/usage.json"
check "usage resets in a new month" '.calls == 0' "$("$UPNEXT" usage)"

# a renamed field: the 422 triggers one name refresh from the schema, then a retry
reset
out=$(FAKE_422_ONCE=1 "$UPNEXT" fetch)
check "fetch recovers from a renamed field" '.ok and (.tasks | length) == 2' "$out"
check "renamed field picked up by id" '.fields.status.name == "State"' "$(cat "$UPNEXT_CONFIG")"

# setup, answered through stdin with every default, then Team
reset
rm "$UPNEXT_CONFIG"
# answers: keep token, 17 defaults (base, table, 6 fields, 3 statuses, priority order,
# 5 project questions), plan 1 = Team
out=$({ echo y; printf '\n%.0s' {1..17}; echo 1; } | "$UPNEXT" setup 2>&1)
if [ -s "$UPNEXT_CONFIG" ]; then
  cfgjson=$(cat "$UPNEXT_CONFIG")
  check "setup maps fields by type and name" '.fields | .name.id == "fldName0000000001" and .due.id == "fldDue00000000001" and .status.id == "fldStatus00000001" and .priority.id == "fldPriority000001" and .start.id == "fldStart000000001" and .project.id == "fldProject0000001"' "$cfgjson"
  check "setup finds the project-name lookup" '.fields.projectLabel.id == "fldPLabel00000001"' "$cfgjson"
  check "setup status defaults" '.statuses == {"open":["Inbox","Next","Bob'"'"'s \\ stuff"],"done":"Done","new":"Next"}' "$cfgjson"
  check "setup puts ascending priorities most urgent first" '.priorities == ["Urgent","High","Medium","Low"]' "$cfgjson"
  check "setup projects mapping" '.projects | .tableId == "tblTestProjects01" and .client.name == "Client" and .doneStatuses == ["Completed"] and .newStatus == "Active" and .start.id == "fldPStart00000001"' "$cfgjson"
  check "setup plan" '.plan == "team" and .planSource == "setup"' "$cfgjson"
  check "setup config is private" '. == "600"' "$(stat -c %a "$UPNEXT_CONFIG" | jq -R .)"
  check "setup ends with a working fetch" 'test("Done\\. 2 open tasks")' "$(jq -Rs . <<<"$out")"
  check "setup keeps status and field names off command lines" '. == ""' "$(grep -nE "Bob|Project Name" "$FAKE_DIR/argv.log" | jq -Rs 'rtrimstr("\n")')"
else
  failed=$((failed + 1)); echo "FAIL: setup wrote no config"; echo "$out" | tail -15
fi

# the published template base maps with every default accepted
reset
rm "$UPNEXT_CONFIG"
{ echo y; printf '\n%.0s' {1..17}; echo 1; } | FAKE_SCHEMA=template-schema "$UPNEXT" setup >/dev/null 2>&1
check "template base maps with no overrides" '
  (.fields | map_values(.name?)) == {"name":"Name","due":"Due","status":"Status","priority":"Priority","start":"Start","project":"Project","projectLabel":"Project Name"}
  and .statuses == {"open":["Inbox","Next","In Progress"],"done":"Done","new":"Next"}
  and .priorities == ["Urgent","High","Medium","Low"]
  and (.projects | .client.name == "Client" and .status.name == "Status" and .start.name == "Start" and .doneStatuses == ["Completed"] and .newStatus == "Active")' "$(cat "$UPNEXT_CONFIG" 2>/dev/null || echo '{}')"

# a token without schema.bases:read gets told exactly what to add
reset
rm "$UPNEXT_CONFIG"
out=$({ echo y; echo; } | FAKE_NO_SCHEMA=1 "$UPNEXT" setup 2>&1)
check "setup explains a missing schema scope" 'test("schema.bases:read")' "$(jq -Rs . <<<"$out")"
check "no config written without the scope" '. == false' "$([ -e "$UPNEXT_CONFIG" ] && echo true || echo false)"

echo "$pass passed, $failed failed"
rm -rf "$HERE/.out"
[ "$failed" -eq 0 ]
