#!/usr/bin/env bash
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-wait-declaration-tests)

# 2026-10-26T09:00:00Z: recheck=2026-10-24 fell due at 2026-10-25T00:00Z, 33 hours earlier.
NOW=1793005200

utc_day() {  # <epoch> -> YYYY-MM-DD
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d
}

scan() { scan_wait_declarations "$1" "$NOW"; }

reasons() {  # <scan items> -> one reason per item
  local item
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    wait_declaration_item_reason "$item"; printf '\n'
  done <<EOF
$1
EOF
}

record_all() {  # <state> <scan items>
  local item
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    wait_declaration_record_raised "$1" "$item" "$NOW" || fail "recording a raised wait failed"
  done <<EOF
$2
EOF
}

test_accepted_shape_quiet_before_recheck() {
  local dir state items
  dir=$(make_case wait-accepted); state="$dir/state"
  printf 'working: setup\npaused [at=1793000000]: release cut | owner=daily-release workflow | recheck=2026-10-26\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on a well-formed wait"
  [ -z "$items" ] || fail "a well-formed wait whose recheck day has not ended was raised: $items"
  printf 'paused [at=1793000000]: nm run | owner=the worker | recheck=2026-10-26T09:30Z\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on a timed recheck"
  [ -z "$items" ] || fail "a wait whose recheck time is still ahead was raised: $items"
  pass "a wait naming owner and a future recheck stays quiet"
}

test_refused_shape_flagged() {
  local dir state items text
  dir=$(make_case wait-refused); state="$dir/state"
  printf 'paused [at=1793000000]: waiting for the release to cut\n' > "$state/a.status"
  printf 'paused [at=1793000000]: waiting | owner=captain\n' > "$state/b.status"
  printf 'blocked [at=1793000000]: no credential | recheck=2026-10-30\n' > "$state/c.status"
  printf 'paused [at=1793000000]: waiting | owner=captain | recheck=tomorrow\n' > "$state/d.status"
  items=$(scan "$state") || fail "the scan failed on undeclared fields"
  text=$(reasons "$items")
  assert_contains "$text" "wait names no owner or recheck date: a paused: waiting for the release to cut" "a wait with neither field was not flagged"
  assert_contains "$text" "wait names no recheck date: b paused: waiting" "a wait with no recheck was not flagged"
  assert_contains "$text" "wait names no owner: c blocked: no credential" "a blocker with no owner was not flagged"
  assert_contains "$text" "wait names no recheck date: d paused: waiting" "an unreadable recheck date was accepted"
  [ "$(printf '%s\n' "$items" | grep -c '^undated')" -eq 4 ] || fail "expected four undated flags: $items"
  pass "a wait missing its owner or a readable recheck date is flagged"
}

test_overdue_raised_with_owner_and_time() {
  local dir state items text
  dir=$(make_case wait-overdue); state="$dir/state"
  printf 'paused [at=1792800000]: release cut | owner=daily-release workflow | recheck=2026-10-24\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on an overdue wait"
  text=$(reasons "$items")
  assert_contains "$text" "wait overdue: t paused waiting on daily-release workflow, recheck 2026-10-24 passed 1d 9h ago: release cut" "the overdue wait was not raised with its task, owner and overdue time"
  dir=$(make_case wait-overdue-blocker); state="$dir/state"
  printf 'blocked [key=cred] [at=1792800000]: no token | owner=captain | recheck=2026-10-26T08:00Z\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on an overdue blocker"
  assert_contains "$(reasons "$items")" "wait overdue: t blocked waiting on captain, recheck 2026-10-26T08:00Z passed 1h 0m ago: no token" "the overdue blocker was not raised"
  pass "an overdue wait is raised naming task, owner and overdue time"
}

test_cleared_wait_quiet() {
  local dir state items
  dir=$(make_case wait-cleared); state="$dir/state"
  {
    printf 'paused [at=1792800000]: release cut | owner=ci | recheck=2026-10-24\n'
    printf 'working [at=1792900000]: release shipped\n'
    printf 'blocked [key=cred] [at=1792800000]: no token | owner=captain | recheck=2026-10-24\n'
    printf 'resolved [key=cred] [at=1792900000]: token granted\n'
  } > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on cleared waits"
  [ -z "$items" ] || fail "a wait no longer declared was raised: $items"
  pass "a wait that cleared is not raised"
}

test_raised_once_then_rearmed_by_redeclaration() {
  local dir state items
  dir=$(make_case wait-once); state="$dir/state"
  printf 'paused [at=1792800000]: release cut | owner=release | recheck=2026-10-24\n' > "$state/t.status"
  items=$(scan "$state") || fail "the first scan failed"
  [ -n "$items" ] || fail "the first scan raised nothing"
  record_all "$state" "$items"
  items=$(scan "$state") || fail "the second scan failed"
  [ -z "$items" ] || fail "the same overdue wait was raised twice: $items"
  printf 'paused [at=1793000000]: release cut | owner=release | recheck=2026-10-25\n' >> "$state/t.status"
  items=$(scan "$state") || fail "the scan after redeclaring failed"
  assert_contains "$(reasons "$items")" "recheck 2026-10-25 passed 9h 0m ago" "a redeclared wait whose new recheck also passed was not raised"
  printf 'working [at=1793000100]: resumed\n' >> "$state/t.status"
  scan "$state" >/dev/null || fail "the scan after clearing failed"
  if compgen -G "$state/.wait-flag-*" >/dev/null; then
    fail "a raised marker outlived its wait: $(ls -a "$state")"
  fi
  pass "a wait is suppressed within the reminder interval and its marker goes when the wait clears"
}

test_overdue_reminder_does_not_stop_after_first_wake() {
  local dir state items
  dir=$(make_case wait-repeat); state="$dir/state"
  printf 'paused: release | owner=release | recheck=2020-01-01\n' > "$state/t.status"
  items=$(scan "$state")
  record_all "$state" "$items"
  [ -z "$(scan_wait_declarations "$state" "$((NOW + 3599))")" ] || fail "reminder fired too soon"
  [ -n "$(scan_wait_declarations "$state" "$((NOW + 3600))")" ] || fail "overdue reminder did not repeat"
  printf 'working: resumed\n' >> "$state/t.status"
  [ -z "$(scan_wait_declarations "$state" "$((NOW + 7200))")" ] || fail "cleared wait repeated"
  pass "an unchanged overdue pause repeats at a bounded interval"
}

test_ci_owner_without_run_id_is_flagged() {
  local dir state items
  dir=$(make_case wait-ci-missing); state="$dir/state"
  printf 'paused: waiting for checks | owner=GitHub CI | recheck=2030-01-01\n' > "$state/t.status"
  items=$(scan "$state")
  assert_contains "$(reasons "$items")" "run id" "a CI wait without a run id was not flagged"
  printf 'paused: CI run 123 | owner=GitHub CI | recheck=2030-01-01\n' > "$state/t.status"
  [ -z "$(scan "$state")" ] || fail "a CI wait with a run id was flagged"
  pass "a CI wait without a run id is flagged"
}

test_ci_run_completion_does_not_wake_for_in_progress() {
  local dir state items form
  dir=$(make_case wait-ci); state="$dir/state"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/example/repo.git
  printf 'project=%s\n' "$dir" > "$state/t.meta"
  cat > "$dir/fakebin/gh-axi" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *'.conclusion'*) printf 'api_response:\n  body: success\n' ;;
  *) printf 'api_response:\n  body: %s\n' "$CI_STATUS" ;;
esac
SCRIPT
  chmod +x "$dir/fakebin/gh-axi"
  for form in 'CI run 123' 'ci_run=123' 'https://github.com/example/repo/actions/runs/123'; do
    printf 'paused: %s | owner=GitHub CI | recheck=2030-01-01\n' "$form" > "$state/t.status"
    items=$(PATH="$dir/fakebin:$PATH" CI_STATUS=in_progress scan_wait_ci_completions "$state")
    [ -z "$items" ] || fail "an in-progress run woke firstmate"
    items=$(PATH="$dir/fakebin:$PATH" CI_STATUS=completed scan_wait_ci_completions "$state")
    assert_contains "$items" "$(printf 't\texample/repo\t123\t')" "completed run was missed"
  done
  pass "each supported run reference wakes only after completion"
}

test_completed_ci_failure_reaches_worker_once() {
  local dir state out pid body items
  dir=$(make_case wait-ci-delivery); state="$dir/state"
  mkdir -p "$dir/config"
  : > "$dir/config/wait-no-turns"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/example/repo.git
  fm_write_herdr_meta "$state/t.meta" "sess:w1:p1" "kind=ship" "harness=pi" "project=$dir"
  cat > "$dir/fakebin/herdr" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  'pane read') printf '%s\n' '╭────╮' '│    │' '╰────╯' ;;
  'pane send-text') printf '%s' "$4" >> "$FM_SEND_LOG" ;;
  'pane send-keys') : ;;
  *) exit 1 ;;
esac
SCRIPT
  chmod +x "$dir/fakebin/herdr"
  cat > "$dir/fakebin/gh-axi" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *'.conclusion'*) printf 'api_response:\n  body: failure\n' ;;
  *) printf 'api_response:\n  body: completed\n' ;;
esac
SCRIPT
  chmod +x "$dir/fakebin/gh-axi"
  printf 'paused: CI run 123 | owner=GitHub CI | recheck=2030-01-01\n' > "$state/t.status"
  prime_status_seen "$state" "$state/t.status" || fail "priming status failed"
  rm -f "$state/.last-check"
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$pid" 2>/dev/null || true; fail "watcher did not finish: $(cat "$out")"; }
  assert_contains "$(cat "$out")" "check: wait-ci: t CI run 123 completed" "supervisor wake missing"
  [ -f "$state/t.inbox/001.msg" ] || fail "completed run did not reach the worker inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state/t.inbox/001.msg")
  assert_contains "$body" "123" "run id missing"
  assert_contains "$body" "failure" "conclusion missing"
  assert_contains "$body" "gh run view 123 -R example/repo --log-failed" "failure command missing"
  assert_contains "$(cat "$dir/send.log")" "Firstmate instruction waiting" "worker doorbell missing"
  grep -Fqx 'delivery=fire-and-forget' "$state/t.inbox/001.msg" || fail "completion was not recorded as fire-and-forget"
  items=$(PATH="$dir/fakebin:$PATH" scan_wait_ci_completions "$state")
  [ -z "$items" ] || fail "the same run was sent twice"
  pass "a failed CI run reaches the worker once and preserves the supervisor wake"
}

make_remote_ci_case() {
  local dir=$1 host="$1/execution"
  mkdir -p "$dir/data" "$host/state" "$host/projects/repo"
  printf 'lab\n' > "$host/.fm-exec-home"
  git -C "$host/projects/repo" init -q || fail "remote project setup failed"
  git -C "$host/projects/repo" remote add origin https://github.com/example/remote-ci.git || fail "remote origin setup failed"
  printf '%s\n' "- lab - stub host (host: stub; root: $ROOT; home: $host; scope: tests; projects: repo; added 2026-01-01)" > "$dir/data/remote-homes.md"
  fm_write_meta "$dir/state/remote-ci.meta" "window=remote:remote-ci" "endpoint_task_id=remote-ci" "kind=ship" "mode=local-only" \
    "remote_host=stub" "remote_route=lab" "worktree=/remote-only/worktree" "project=/remote-only/project"
  fm_write_herdr_meta "$host/state/remote-ci.meta" 'fm-remote:w1:p1' 'kind=ship' 'harness=pi' "worktree=$host/worktree" "project=$host/projects/repo"
  printf 'paused: CI run 456 | owner=GitHub CI | recheck=2099-01-01\n' > "$dir/state/remote-ci.status"
  prime_status_seen "$dir/state" "$dir/state/remote-ci.status" || fail "priming remote status failed"

  cat > "$dir/fakebin/ssh" <<'SCRIPT'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = stub ] || exit 91
shift 2
args=$(printf '%s' "$4" | base64 --decode | tr '\000' '\n')
command=$(printf '%s\n' "$args" | head -1)
[ "$command" = fm-remote-worker-control.sh ] || exit 92
verb=$(printf '%s\n' "$args" | sed -n '2p')
task=$(printf '%s\n' "$args" | sed -n '3p')
extra=$(printf '%s\n' "$args" | sed -n '4p')
last=$(printf '%s\n' "$args" | sed -n '5p')
if [ "$verb" = fleet ] && [ -f "$CI_CASE/stop-after-retry" ] && [ -s "$CI_CASE/submitted" ]; then
  printf 'needs-decision: watched another poll after the remote doorbell landed\n' >> "$CI_CASE/state/probe.status"
fi
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
forward=("$verb")
[ -z "$task" ] || forward+=("$task")
[ -z "$extra" ] || forward+=("$extra")
[ -z "$last" ] || forward+=("$last")
FM_HOME="$CI_CASE/execution" "$CI_ROOT/bin/$command" "${forward[@]}"
SCRIPT
  cat > "$dir/fakebin/herdr" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  'pane read') printf '%s\n' '╭────╮' '│    │' '╰────╯' ;;
  'pane send-text')
    [ "${FM_HOME:-}" = "$CI_CASE/execution" ] || exit 90
    printf '%s\n' "$4" >> "$CI_CASE/attempts"
    [ -e "$CI_CASE/allow-submit" ]
    ;;
  'pane send-keys') printf 'Enter\n' >> "$CI_CASE/submitted" ;;
  *) exit 1 ;;
esac
SCRIPT
  cat > "$dir/fakebin/gh-axi" <<'SCRIPT'
#!/usr/bin/env bash
[ "$1 $2" = 'api repos/example/remote-ci/actions/runs/456' ] || exit 1
case "$4" in
  .status) printf 'api_response:\n  body: completed\n' ;;
  .conclusion) printf 'api_response:\n  body: failure\n' ;;
  *) exit 1 ;;
esac
SCRIPT
  chmod +x "$dir/fakebin/ssh" "$dir/fakebin/herdr" "$dir/fakebin/gh-axi"
}

remote_ci_watch() {
  local dir=$1 output=$2 pid
  CI_CASE="$dir" CI_ROOT="$ROOT" PATH="$dir/fakebin:$PATH" FM_SSH_BIN="$dir/fakebin/ssh" \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_REMOTE_FLEET_CACHE_SECS=0 FM_REMOTE_RING_GRACE=1 FM_REMOTE_RING_MAX="${3:-1}" \
    FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
    "$WATCH" > "$output" 2>&1 &
  pid=$!
  wait_for_watcher_lock "$pid" "$dir/state" || fail "remote CI watcher did not take its lock"
  wait_for_exit "$pid" 300 || fail "remote CI watcher did not finish: $(cat "$output")"
}

ack_remote_ci_wake() {
  local dir=$1
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" || fail "could not read the CI completion wake"
  FM_HOME="$dir" PATH="$dir/fakebin:$PATH" ack_drain_err "$dir/state" "$dir/drain.err" || fail "could not acknowledge the CI completion wake"
}

test_remote_ci_does_not_drop_a_failed_doorbell() {
  local dir inbox body
  dir=$(make_case wait-ci-remote-retry)
  make_remote_ci_case "$dir"
  inbox="$dir/execution/state/remote-ci.inbox"
  remote_ci_watch "$dir" "$dir/complete.out"
  assert_grep 'check: wait-ci: remote-ci CI run 456 completed in example/remote-ci' "$dir/complete.out" "the watcher did not find CI for a remote-only project"
  [ -f "$inbox/001.msg" ] || fail "the CI result was not recorded in the execution home"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$inbox/001.msg")
  assert_contains "$body" "CI run 456 in example/remote-ci completed with conclusion failure." "remote worker did not get the CI result"
  assert_grep 'Firstmate instruction waiting' "$dir/attempts" "initial ring was not attempted on the remote worker"
  [ ! -s "$dir/submitted" ] || fail "the initial failure fixture actually submitted"
  : > "$dir/allow-submit"
  : > "$dir/stop-after-retry"
  ack_remote_ci_wake "$dir"
  remote_ci_watch "$dir" "$dir/retry.out"
  grep -Eq 'signal:.*probe' "$dir/retry.out" || fail "the watcher did not reach the poll after the successful retry: $(cat "$dir/retry.out")"
  [ "$(grep -c 'Firstmate instruction waiting' "$dir/attempts")" -eq 2 ] || fail "the watcher dropped or repeated the remote retry"
  [ -s "$dir/submitted" ] || fail "the retry did not submit the doorbell"
  [ ! -e "$inbox/002.msg" ] || fail "the watcher enqueued the same CI result again"
  pass "a failed initial remote CI doorbell is retried without repeating a submitted doorbell or duplicating the message"
}

test_remote_ci_does_not_retry_forever() {
  local dir inbox
  dir=$(make_case wait-ci-remote-exhausted)
  make_remote_ci_case "$dir"
  inbox="$dir/execution/state/remote-ci.inbox"
  remote_ci_watch "$dir" "$dir/complete.out"
  assert_grep 'check: wait-ci: remote-ci CI run 456 completed' "$dir/complete.out" "the CI completion wake was missing"
  ack_remote_ci_wake "$dir"
  remote_ci_watch "$dir" "$dir/exhausted.out" 2
  grep -Eq 'stale: remote:remote-ci.*2 doorbell delivery attempts' "$dir/exhausted.out" || fail "exhausted retries did not name the remote task: $(cat "$dir/exhausted.out")"
  [ "$(grep -c 'Firstmate instruction waiting' "$dir/attempts")" -eq 3 ] || fail "the initial attempt and both retries did not reach the remote pane"
  [ -f "$inbox/001.msg" ] && [ ! -e "$inbox/002.msg" ] || fail "retry exhaustion lost or duplicated the CI result"
  [ ! -s "$dir/submitted" ] || fail "the exhausted failure fixture actually submitted"
  pass "a remote CI doorbell that never lands wakes the supervisor when the retry budget is spent"
}

test_remote_ci_retry_does_not_ring_an_acknowledged_record() {
  local dir inbox result
  dir=$(make_case wait-ci-remote-ack)
  make_remote_ci_case "$dir"
  inbox="$dir/execution/state/remote-ci.inbox"
  remote_ci_watch "$dir" "$dir/complete.out"
  [ -f "$inbox/001.msg" ] || fail "the completion was missing from the execution inbox"
  mv "$inbox/001.msg" "$inbox/handled/" || fail "the worker could not acknowledge the record"
  : > "$dir/allow-submit"
  result=$(CI_CASE="$dir" CI_ROOT="$ROOT" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/execution" \
    "$ROOT/bin/fm-remote-worker-control.sh" ring-record remote-ci 001.msg) || fail "a stale retry was not accepted as a no-op"
  [ "$result" = ring=0 ] || fail "the stale retry did not report that no more retries were needed"
  [ "$(grep -c 'Firstmate instruction waiting' "$dir/attempts")" -eq 1 ] || fail "a stale fleet result re-rang the acknowledged record"
  [ ! -s "$dir/submitted" ] || fail "a retry typed after acknowledgement"
  pass "an acknowledgement ends remote CI retries even when a stale fleet read schedules one more ring"
}

test_unchanged_log_is_not_folded_again() {
  local dir state probe items appended
  dir=$(make_case wait-unchanged); state="$dir/state"; probe="$dir/fold-probe"
  {
    printf 'working [at=1792700000]: setup\n'
    printf 'blocked [key=cred] [at=1792800000]: no token | owner=captain | recheck=2026-10-26T08:00Z\n'
  } > "$state/t.status"
  items=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$state") || fail "the first scan failed"
  [ "$(cut -f2 "$probe")" = "$(wc -c < "$state/t.status" | tr -d ' ')" ] \
    || fail "the first scan did not fold the whole log once: $(cat "$probe")"
  : > "$probe"
  items=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$state") || fail "the second scan failed"
  [ ! -s "$probe" ] || fail "a log with no new line was folded again: $(cat "$probe")"
  assert_contains "$(reasons "$items")" "wait overdue: t blocked waiting on captain, recheck 2026-10-26T08:00Z passed 1h 0m ago: no token" \
    "the open blocker was lost when its log was not folded again"
  appended='resolved [key=cred] [at=1793000000]: token granted'
  printf '%s\n' "$appended" >> "$state/t.status"
  items=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$state") || fail "the scan after an append failed"
  [ "$(cut -f2 "$probe")" = "$(( ${#appended} + 1 ))" ] \
    || fail "the scan after an append folded more than the appended line: $(cat "$probe")"
  [ -z "$items" ] || fail "a blocker resolved by an appended line was still raised: $items"
  pass "a scan folds only the lines appended since the last one"
}

test_older_line_flagged_once_and_still_read() {
  local dir state items until
  dir=$(make_case wait-older); state="$dir/state"
  printf 'working: setup\npaused: awaiting external CI until 2026-10-26T12:00Z\n' > "$state/t.status"
  printf 'blocked: launched in primary checkout\n' > "$state/u.status"
  items=$(scan "$state") || fail "the scan failed on older undated lines"
  assert_contains "$(reasons "$items")" "wait names no owner or recheck date: t paused: awaiting external CI until 2026-10-26T12:00Z" "an older paused line was not flagged as undated"
  assert_contains "$(reasons "$items")" "wait names no owner or recheck date: u blocked: launched in primary checkout" "an older blocked line was not flagged as undated"
  record_all "$state" "$items"
  items=$(scan "$state") || fail "the rescan failed"
  [ -z "$items" ] || fail "an older undated line was flagged twice: $items"
  status_is_paused "$(status_declared_wait_line "$state/t.status")" || fail "the older line no longer reads as a declared wait"
  until=$(status_paused_until "$(status_declared_wait_line "$state/t.status")") || fail "the older line's until time is no longer read"
  [ "$until" = 1793016000 ] || fail "the older line's until time changed: $until"
  pass "an older undated line is flagged once and keeps its existing reading"
}

test_watcher_raises_overdue_wait() {
  local dir state out pid day
  dir=$(make_case wait-watcher); state="$dir/state"
  day=$(utc_day "$(( $(date +%s) - 3 * 86400 ))")
  printf 'paused [at=1792800000]: release cut | owner=daily-release workflow | recheck=%s\n' "$day" > "$state/t.status"
  prime_status_seen "$state" "$state/t.status" || fail "priming the already-surfaced marker failed"
  out="$dir/watch.out"
  rm -f "$state/.last-check"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$pid" 2>/dev/null || true; fail "the watcher did not exit on an overdue wait: $(cat "$out")"; }
  grep -F "check: wait-declaration: wait overdue: t paused waiting on daily-release workflow, recheck $day passed" "$out" >/dev/null \
    || fail "the watcher did not raise the overdue wait: $(cat "$out")"
  pass "the watcher raises an overdue wait through the real entry point"
}

test_accepted_shape_quiet_before_recheck
test_refused_shape_flagged
test_overdue_raised_with_owner_and_time
test_cleared_wait_quiet
test_raised_once_then_rearmed_by_redeclaration
test_overdue_reminder_does_not_stop_after_first_wake
test_ci_owner_without_run_id_is_flagged
test_ci_run_completion_does_not_wake_for_in_progress
test_completed_ci_failure_reaches_worker_once
test_remote_ci_does_not_drop_a_failed_doorbell
test_remote_ci_does_not_retry_forever
test_remote_ci_retry_does_not_ring_an_acknowledged_record
test_unchanged_log_is_not_folded_again
test_older_line_flagged_once_and_still_read
test_watcher_raises_overdue_wait
