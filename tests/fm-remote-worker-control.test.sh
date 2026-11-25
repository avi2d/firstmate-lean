#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-control)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
printf 'exec-route\n' > "$HOME_DIR/.fm-exec-home"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capabilities)
[ "$out" = 'fm-remote-worker-control.v2' ] || fail "capability handshake differs from protocol"
pass "remote worker advertises launch protocol"
mkdir -p "$HOME_DIR/state"
fm_write_meta "$HOME_DIR/state/scout-a.meta" \
  "window=fm-remote:w1:p1" "endpoint_task_id=scout-a" \
  "backend=herdr" "herdr_session=fm-remote" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
  "worktree=$TMP_ROOT/worktree" "project=$TMP_ROOT/project" "kind=scout" "harness=pi"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" route scout-a)
printf '%s\n' "$out" | grep -Fx 'target=fm-remote:w1:p1' >/dev/null || fail "route loses its recorded target"
printf '%s\n' "$out" | grep -Fx 'backend=herdr' >/dev/null || fail "route loses its backend"
pass "remote route reads the task endpoint"
mkdir -p "$HOME_DIR/config"
printf 'fm-remote\n' > "$HOME_DIR/config/herdr-session"
printf 'window=fm-other:pane1\nworktree=/tmp/worktree\nproject=/tmp/project\nbackend=herdr\nendpoint_task_id=scout-wrong\nherdr_session=fm-other\nherdr_workspace_id=workspace1\nherdr_tab_id=tab1\nherdr_pane_id=pane1\nkind=scout\nharness=pi\n' > "$HOME_DIR/state/scout-wrong.meta"
if FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" route scout-wrong >/dev/null 2>&1; then fail "route accepted an endpoint outside the execution home session"; fi
pass "route rejects an endpoint from a different Herdr session"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" state absent)
[ "$out" = missing ] || fail "missing task was reported as $out"
if FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capture scout-a 101 >/dev/null 2>&1; then fail "capture accepted an unbounded line count"; fi
pass "state reports an absent task and capture bounds its output"
mkdir -p "$TMP_ROOT/fake-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/fake-bin/herdr"
chmod +x "$TMP_ROOT/fake-bin/herdr"
if PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capture scout-a >/dev/null 2>&1; then fail "capture reported success when the backend refused"; fi
pass "capture propagates backend failure"
printf 'needs-decision [key=pick] [at=1700000000]: pick one\n' > "$HOME_DIR/state/scout-a.status"
close='resolved [key=pick] [at=1700000001]: answered: first'
out=$(printf '%s\n' "$close" | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" resolve-stdin scout-a) || fail "resolve-stdin refused a keyed close"
[ "$out" = 'resolved appended=1' ] || fail "resolve-stdin reported $out"
out=$(printf '%s\n' "$close" | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" resolve-stdin scout-a) || fail "a repeated close was refused"
[ "$out" = 'resolved appended=0' ] || fail "a repeated close was appended twice: $out"
[ "$(grep -cFx -- "$close" "$HOME_DIR/state/scout-a.status")" = 1 ] || fail "the close line was duplicated"
pass "resolve_stdin_appends_a_keyed_close_once_instead_of_duplicating_it_on_retry"
for bad in 'done: forged completion' 'resolved: no key' 'needs-decision [key=pick]: reopened'; do
  printf '%s\n' "$bad" | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" resolve-stdin scout-a >/dev/null 2>&1 && fail "resolve-stdin accepted: $bad"
  grep -Fx -- "$bad" "$HOME_DIR/state/scout-a.status" >/dev/null && fail "resolve-stdin wrote: $bad"
done
pass "resolve_stdin_refuses_any_line_other_than_a_keyed_close_instead_of_forging_worker_status"
out=$(printf 'test\n' | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" launch scout-b missing scout - - fm/ - pi - - herdr 2>&1) && fail "launch accepted a missing project"
printf '%s\n' "$out" | grep -F 'project is unavailable' >/dev/null || fail "missing project refusal does not identify the cause: $out"
[ ! -e "$HOME_DIR/data/scout-b" ] || fail "missing project created task data"
pass "launch refuses a missing project before writing task data"
mkdir -p "$HOME_DIR/projects"
out=$(printf 'test\n' | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" launch scout-b . scout - - fm/ - pi - - herdr 2>&1) && fail "launch accepted the projects directory as a project"
printf '%s\n' "$out" | grep -F 'invalid task or project id' >/dev/null || fail "dot project was not rejected before reading input: $out"
pass "launch rejects the projects directory as a project"
FAKE_ROOT="$TMP_ROOT/code"
mkdir -p "$FAKE_ROOT" "$HOME_DIR/projects/alpha" "$HOME_DIR/config" "$HOME_DIR/data"
cp -R "$ROOT/bin" "$FAKE_ROOT/bin"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
cat > "$FAKE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
if [ -n "${FM_TEST_MARKER_CASE:-}" ]; then
  case "$FM_TEST_MARKER_CASE" in
    differs) printf 'other-attempt\n' > "$FM_HOME/data/$id/launch-marker" ;;
    missing) rm "$FM_HOME/data/$id/launch-marker" ;;
  esac
  if [ "${FM_TEST_WRONG_CLEANUP:-0}" = 1 ]; then
    rm -f "$FM_HOME/data/$id/brief.md"
  fi
  : > "$FM_REMOTE_SPAWN_PRELAUNCH_RECEIPT"
  exit 1
fi
if [ "${FM_TEST_SPAWN_ERROR:-0}" = 1 ]; then
  printf 'notice: starting\nerror: missing required account\nerror: secondary failure\n' >&2
  exit 1
fi
if [ -f "$FM_HOME/config/crew-dispatch.json" ] && [ ! -f "$FM_HOME/data/$id/dispatch-resolution.json" ]; then exit 8; fi
kind=ship
for arg in "$@"; do [ "$arg" != --scout ] || kind=scout; done
printf '%s\n' "$@" > "$FM_HOME/state/$id.args"
printf 'window=fm-remote:w1:fm-%s\nbackend=herdr\nendpoint_task_id=%s\nherdr_session=fm-remote\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:fm-%s\nworktree=/tmp/worktree\nproject=/tmp/project\nkind=%s\nharness=pi\n' "$id" "$id" "$id" "$kind" > "$FM_HOME/state/$id.meta"
printf 'working: reading brief\n' > "$FM_HOME/state/$id.status"
SH
chmod +x "$FAKE_ROOT/bin/fm-spawn.sh"
printf '# Task\n## Captain\x27s intent\nIndependent request.\n\n## Firstmate spec\nExact constraints.\n' > "$TMP_ROOT/brief"
out=$(FM_TEST_SPAWN_ERROR=1 FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-error alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief" 2>&1) && fail "failed spawn reported success"
printf '%s\n' "$out" | grep -Fx 'error: host-local worker launch failed: error: missing required account' >/dev/null || fail "host launch failure did not name its first error: $out"
pass "failed remote spawn identifies its first error instead of only a generic failure"
marker_cleanup_case() {
  local marker_case=$1 wrong_cleanup=$2 id="marker-$1-$2" rc=0
  FM_TEST_MARKER_CASE="$marker_case" FM_TEST_WRONG_CLEANUP="$wrong_cleanup" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" \
    bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch "$id" alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief" > "$TMP_ROOT/$id.out" 2>&1 || rc=$?
  case "$marker_case" in
    matches) [ "$rc" -eq 76 ] && [ ! -e "$HOME_DIR/data/$id/brief.md" ] ;;
    differs|missing) [ "$rc" -eq 1 ] && [ -f "$HOME_DIR/data/$id/brief.md" ] ;;
  esac
}
marker_cleanup_case differs 1 && fail "marker check accepted cleanup that deletes a differently owned brief"
marker_cleanup_case missing 1 && fail "marker check accepted cleanup that deletes an unmarked brief"
for marker_case in matches differs missing; do
  marker_cleanup_case "$marker_case" 0 || fail "cleanup violated ownership for $marker_case"
done
pass "failed launch removes only the matching scaffold instead of another or unmarked brief"
out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-c alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief") || fail "remote launch refused a valid scout"
assert_grep 'Independent request.' "$HOME_DIR/data/scout-c/brief.md" "remote scaffold dropped intent"
assert_grep 'Exact constraints.' "$HOME_DIR/data/scout-c/brief.md" "remote scaffold dropped specification"
assert_grep '--local' "$HOME_DIR/state/scout-c.args" "host spawn did not override remote placement"
assert_grep "$HOME_DIR/state/scout-c.status" "$HOME_DIR/data/scout-c/brief.md" "remote scaffold retained main paths"
printf '%s\n' "$out" | grep -Fx 'target=fm-remote:w1:fm-scout-c' >/dev/null || fail "launch omitted route"
pass "remote launch rebuilds the brief and returns the host endpoint"
{ printf '# Task\n'; sleep 0.2; printf '## Captain\x27s intent\nComplete request.\n\n## Firstmate spec\nComplete constraints.\n'; } | \
  FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-d alpha scout - - fm/ - pi - - herdr >/dev/null \
  || fail "launch dropped a brief split across pipe writes"
assert_grep 'Complete constraints.' "$HOME_DIR/data/scout-d/brief.md" "split brief lost its second write"
pass "launch reads every part of a streamed brief"
mkdir -p "$TMP_ROOT/main/data"
FM_HOME="$TMP_ROOT/main" "$ROOT/bin/fm-brief.sh" scout-e alpha --scout --herdr-lab >/dev/null
awk '$0 == "{TASK}" {print "Inspect the session."; next} $0 == "{FIRSTMATE_SPEC}" {print "Use the lab."; next} {print}' "$TMP_ROOT/main/data/scout-e/brief.md" > "$TMP_ROOT/lab-brief"
FM_ROOT_OVERRIDE="$TMP_ROOT/main" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-e alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/lab-brief" >/dev/null || fail "lab brief launch failed"
assert_grep "This brief was explicitly scaffolded with \`--herdr-lab\`" "$HOME_DIR/data/scout-e/brief.md" "host scaffold dropped Herdr isolation"
assert_grep "HERDR_LAB_HELPER='$FAKE_ROOT/bin/fm-herdr-lab.sh'" "$HOME_DIR/data/scout-e/brief.md" "host scaffold retained the parent Herdr helper path"
assert_grep "LAB_HOME_HELPER='$FAKE_ROOT/bin/fm-lab-home.sh'" "$HOME_DIR/data/scout-e/brief.md" "host scaffold retained the parent lab home helper path"
[ -x "$FAKE_ROOT/bin/fm-herdr-lab.sh" ] && [ -x "$FAKE_ROOT/bin/fm-lab-home.sh" ] || fail "execution host helpers are missing"
pass "remote lab scaffold rejects parent helper paths in favor of execution host paths"
FM_HOME="$TMP_ROOT/main" "$ROOT/bin/fm-brief.sh" ship-one alpha --mode direct-PR --forge forgejo >/dev/null
awk '$0 == "{TASK}" {print "Implement the request."; next} $0 == "{FIRSTMATE_SPEC}" {print "Use the selected forge."; next} {print}' "$TMP_ROOT/main/data/ship-one/brief.md" > "$TMP_ROOT/ship-brief"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch ship-one alpha ship direct-PR off fm/ - pi - - herdr < "$TMP_ROOT/ship-brief" >/dev/null || fail "remote ship launch failed"
assert_grep 'Delivery contract: mode=direct-PR forge=forgejo' "$HOME_DIR/data/ship-one/brief.md" "host scaffold lost the selected forge"
pass "remote ship preserves the forge delivery contract"
printf '{}\n' > "$HOME_DIR/config/crew-dispatch.json"
cat > "$FAKE_ROOT/bin/fm-dispatch-resolve.sh" <<'SH'
#!/usr/bin/env bash
printf '{"status":"off"}\n' > "$(dirname "$1")/dispatch-resolution.json"
SH
chmod +x "$FAKE_ROOT/bin/fm-dispatch-resolve.sh"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-f alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief" >/dev/null || fail "remote launch skipped execution-home dispatch resolution"
[ -f "$HOME_DIR/data/scout-f/dispatch-resolution.json" ] || fail "execution-home dispatch record was not created"
pass "remote launch resolves the execution-home dispatch record before spawning"
out=$(printf 'inspect the session\n' | PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" send-stdin scout-a) || fail "remote send-stdin refused a valid steer: $out"
assert_grep 'inspect the session' "$HOME_DIR/state/scout-a.inbox/001.msg" "host inbox record lost the steer text"
pass "remote send-stdin records the steer in the host inbox before ringing"
if printf '   \n' | PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" send-stdin scout-a >/dev/null 2>&1; then fail "remote send-stdin accepted a blank steer"; fi
pass "remote send-stdin refuses a blank steer without touching the inbox"
if PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" send-stdin ghost < "$TMP_ROOT/brief" >/dev/null 2>&1; then fail "remote send-stdin accepted a task the execution home does not know"; fi
pass "remote send-stdin refuses a task the execution home does not know"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" fleet) || fail "remote fleet refused: $out"
printf '%s\n' "$out" | grep -Ex $'scout-a\tunreadable\tunknown\t-\t001\\.msg:[0-9]+\t-' >/dev/null || fail "fleet misreported the probe contract: $out"
pass "remote fleet reports agent, busy, hash, oldest unread steer, and pending CI record without listing an ordinary steer as CI"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" done-gate scout-a 'done: all green') || fail "remote done gate refused a scout: $out"
[ "$out" = ok ] || fail "remote done gate misreported its verdict: $out"
pass "remote done gate answers from the execution home"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" done-gate ghost 'done: x' 2>&1) && fail "remote done gate accepted a task the execution home does not know"
printf '%s\n' "$out" | grep -F 'no worker ghost' >/dev/null || fail "remote done gate did not identify the task it refused: $out"
pass "remote done gate refuses a task the execution home does not know"
rm -f "$HOME_DIR/state/holder.meta"
printf 'alpha 1\n@heavy-limit 20\n' > "$HOME_DIR/config/project-capacity"
printf 'window=lab:fm-holder\nworktree=/tmp\nproject=/tmp/alpha\nkind=ship\nharness=pi\n' > "$HOME_DIR/state/holder.meta"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" admit new-task alpha 2>&1) && fail "remote admit accepted a worker past the declared host capacity"
printf '%s\n' "$out" | grep -F 'defer: host already holds 1 alpha worker(s) at its declared limit 1' >/dev/null || fail "remote admit refusal did not name the project capacity: $out"
pass "remote admit defers past the declared host capacity instead of launching blind"
rm "$HOME_DIR/state/holder.meta"
printf 'alpha 5\n@heavy-limit 20\n' > "$HOME_DIR/config/project-capacity"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" admit new-task alpha) || fail "remote admit refused room the host has: $out"
case "$out" in 'admit project=alpha holders=0/5 load='*) ;;
  *) fail "remote admit misreported its admission: $out" ;;
esac
pass "remote admit reports its host-scoped admission"
printf 'alpha 5\n@heavy-limit 2\n' > "$HOME_DIR/config/project-capacity"
rc=0
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" admit new-task alpha 2>&1) || rc=$?
[ "$rc" -eq 75 ] || fail "remote admit at the host heavy limit answered exit $rc instead of 75: $out"
printf '%s\n' "$out" | grep -E '^defer: host already runs [0-9]+ heavy worker\(s\) at its limit 2 ' >/dev/null || fail "remote admit did not name the heavy limit: $out"
rm "$HOME_DIR/config/project-capacity"
pass "remote_admit_at_host_heavy_limit_defers_75_instead_of_admitting_a_launch_the_host_spawn_refuses"
if PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" admit new-task 'bad name' >/dev/null 2>&1; then fail "remote admit accepted an invalid project name"; fi
pass "remote admit refuses an invalid project name"
out=$(PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" crew-state scout-a) || fail "remote crew-state refused: $out"
case "$out" in 'state: '*) ;;
  *) fail "remote crew-state did not relay a state line: $out" ;;
esac
pass "remote crew-state relays the execution-home state line"
