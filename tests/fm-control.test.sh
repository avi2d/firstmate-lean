#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-control)

make_case() {
  local name=$1 harness=${2:-pi} dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/fakebin"
  fm_git_worktree "$dir/project" "$dir/copy" "worker-$name"
  touch "$dir/alive"
  : > "$dir/delivery"
  fm_write_meta "$dir/home/state/worker.meta" \
    "window=control-fixture:w1:p2" "endpoint_task_id=worker" \
    "worktree=$dir/copy" "project=$dir/project" "kind=ship" "harness=$harness" \
    "backend=herdr" "herdr_session=control-fixture" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
dir=$(dirname "$(dirname "$0")")
if [ "$*" = 'status --json' ] || [ "$*" = 'status --json --session control-fixture' ]; then
  printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}'
  exit 0
fi
[ "${@: -2:1}" = --session ] && [ "${@: -1}" = control-fixture ]
case "$1 $2" in
  'pane get')
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}'
    ;;
  'pane read')
    if [ -e "$dir/pending" ]; then
      printf '%s\n' '╭──────────────╮' '│ drafted text │' '╰──────────────╯'
    else
      printf '%s\n' '╭────╮' '│    │' '╰────╯'
    fi
    ;;
  'agent get')
    if [ -e "$dir/alive" ]; then
      printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  'pane process-info')
    if [ -e "$dir/alive" ]; then
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"pi","argv":["pi"]}]}}}'
    else
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_processes":[]}}}'
    fi
    ;;
  'pane send-text')
    [ "$3" = w1:p2 ]
    printf 'text %s\n' "$4" >> "$dir/delivery"
    ;;
  'pane send-keys')
    [ "$3" = w1:p2 ]
    printf 'key %s\n' "$4" >> "$dir/delivery"
    if [ "$4" = enter ] && grep -qx 'text /quit' "$dir/delivery" && [ ! -e "$dir/keep-running" ]; then
      rm -f -- "$dir/alive"
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
  '-p 4242 -o args=') printf 'bash\n' ;;
  *) exec /bin/ps "$@" ;;
esac
SH
  chmod +x "$dir/fakebin/ps"
  printf '%s\n' "$dir"
}

run_control() {
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_EXIT_RETRIES=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_interrupt_does_not_claim_cancellation_or_stop_pi() {
  local dir harness out
  for harness in pi pi-signed; do
    dir=$(make_case "interrupt-$harness" "$harness")
    out=$(run_control "$dir" worker interrupt) || fail "$harness interrupt failed: $out"
    assert_contains "$out" "verified=agent-alive cancel=unconfirmed" "interrupt overstated its proof"
    assert_equals 'key escape' "$(cat "$dir/delivery")" "interrupt input"
    assert_present "$dir/alive" "interrupt stopped the agent"
  done
  pass "Pi interrupt sends Escape only and verifies the agent is still running"
}

test_exit_does_not_interrupt_an_idle_agent() {
  local dir state gen out
  dir=$(make_case idle-exit)
  state="$dir/home/state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" worker idle --gen "$gen" --source pi-ext --event stop \
    || fail "could not seed the idle record"
  out=$(run_control "$dir" worker exit) || fail "idle exit failed: $out"
  assert_contains "$out" 'stopped worker harness=pi backend=herdr' "exit did not prove the agent stopped"
  assert_equals "$(printf 'text /quit\nkey enter')" "$(cat "$dir/delivery")" "idle exit input"
  assert_absent "$dir/alive" "exit left the agent running"
  assert_present "$state/worker.meta" "exit erased the task record"
  out=$(run_control "$dir" worker exit) || fail "repeat exit failed: $out"
  assert_contains "$out" 'already-stopped worker' "a repeat exit must not type into the shell"
  assert_equals "$(printf 'text /quit\nkey enter')" "$(cat "$dir/delivery")" "repeat exit input"
  pass "idle exit submits /quit once and a repeat exit types nothing"
}

test_exit_does_not_submit_unrelated_composer_text() {
  local dir out rc=0
  dir=$(make_case pending)
  touch "$dir/pending"
  out=$(run_control "$dir" worker exit) || rc=$?
  expect_code 1 "$rc" "pending composer exit should refuse: $out"
  assert_contains "$out" 'refusing to type the /quit exit command' "pending composer refusal lacked the reason"
  [ ! -s "$dir/delivery" ] || fail "exit sent input into a pending composer"
  assert_present "$dir/alive" "pending composer refusal stopped the agent"
  pass "exit refuses without typing into a composer that holds text"
}

test_control_refuses_a_raw_pane_selector_and_foreign_task_binding() {
  local dir out rc=0 meta
  dir=$(make_case wrong-target)
  out=$(run_control "$dir" control-fixture:w1:p2 interrupt) || rc=$?
  expect_code 1 "$rc" "raw endpoint should refuse: $out"
  assert_contains "$out" 'exact task id only' "raw endpoint refusal did not name the task-id requirement"
  meta="$dir/home/state/worker.meta"
  sed 's/^endpoint_task_id=worker$/endpoint_task_id=other/' "$meta" > "$dir/foreign.meta"
  mv "$dir/foreign.meta" "$meta"
  rc=0
  out=$(run_control "$dir" worker interrupt) || rc=$?
  expect_code 1 "$rc" "foreign binding should refuse: $out"
  assert_contains "$out" 'belongs to task other' "foreign binding refusal did not name the binding"
  [ ! -s "$dir/delivery" ] || fail "a refused selector delivered input"
  pass "control accepts only a task id bound to the recorded endpoint"
}

test_busy_exit_does_not_type_quit_before_escape() {
  local dir state gen out
  dir=$(make_case busy-exit)
  state="$dir/home/state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker) || fail "could not seed the busy record"
  printf 'busy_gen=%s\n' "$gen" >> "$state/worker.meta"
  out=$(run_control "$dir" worker exit) || fail "busy exit failed: $out"
  assert_equals "$(printf 'key escape\ntext /quit\nkey enter')" "$(cat "$dir/delivery")" "busy exit input order"
  assert_not_contains "$(cat "$state/worker.meta")" 'busy_gen=' "exit retained the retired generation"
  pass "busy exit interrupts before submitting /quit and retires the generation"
}

test_exit_does_not_report_a_running_agent_as_stopped() {
  local dir out rc=0
  dir=$(make_case failed-exit)
  touch "$dir/keep-running"
  out=$(run_control "$dir" worker exit) || rc=$?
  expect_code 1 "$rc" "unconfirmed exit should refuse: $out"
  assert_contains "$out" 'agent-state=alive exit=unconfirmed' "exit did not report the live process"
  assert_present "$dir/home/state/worker.meta" "an unconfirmed exit erased the task record"
  pass "exit stays unconfirmed while the agent is still running"
}

test_interrupt_does_not_claim_cancellation_or_stop_pi
test_exit_does_not_interrupt_an_idle_agent
test_busy_exit_does_not_type_quit_before_escape
test_exit_does_not_report_a_running_agent_as_stopped
test_exit_does_not_submit_unrelated_composer_text
test_control_refuses_a_raw_pane_selector_and_foreign_task_binding
