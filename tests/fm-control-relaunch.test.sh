#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

new_case() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/$1.XXXXXX") || return 1
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake" "$dir/fakebin"
  printf 'off\n' > "$dir/home/config/herdr-presentation-spaces"
  fm_fake_exit0 "$dir/fakebin" pi
  printf '%s\n' "$dir"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then
  rm -f "$D/herdr-stopped"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  # Every operational call against a stopped server fails at the transport,
  # with no JSON body to classify.
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
        "${3:-}" "$(cat "$D/cwd")"
    else
      # Only the pane this case says survived can be read back. Any other pane
      # id is structurally gone, which is herdr's `pane_not_found`.
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-registration" ]; then
      cat "$D/herdr-agent-registration"
    elif [ -f "$D/herdr-agent-live" ]; then
      # The agent came back with its server. Nothing here is reclaimable.
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      # A pane that comes back holding no agent is the adoptable state.
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session, and
    # a pane with no registration and no agent is the bare shell it reads as.
    if [ -f "$D/herdr-agent-registration" ] || [ ! -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "$(cat "$D/herdr-pane")"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"pi","argv":["pi"],"cmdline":"pi"}]}}}\n' \
        "$(cat "$D/herdr-pane")"
    fi
    exit 0 ;;
  'pane report-agent')
    # Herdr drops a binding on a sessionless report from the source it bound.
    reg=$D/herdr-agent-registration
    if [ -f "$reg" ] && [ ! -f "$D/herdr-keeps-binding" ]; then
      case " $* " in
        *' --agent-session-'*) ;;
        *" --source $(jq -r '.result.agent.agent_session.source // empty' "$reg") "*)
          jq -c 'del(.result.agent.agent_session)' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg" ;;
      esac
    fi
    exit 0 ;;
  'pane send-text')
    payload=${4:-}
    case "$payload" in
      " . '"*"'") staged=${payload#" . '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[]}}\n'
    exit 0 ;;
  'workspace create')
    if [ -f "$D/herdr-workspace-create-fails" ]; then
      echo 'error: workspace create failed' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # The re-created endpoint. Recording it lets a case prove the pane the
    # record ends up naming is the one this call minted.
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    # From here on the new pane is the one that reads back.
    printf '%s' '%9' > "$D/herdr-pane"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_DIR/herdr-agent-registration" ] || [ ! -f "$FM_FAKE_DIR/herdr-agent-live" ]; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
    '-p 4242 -o args=') printf 'bash\n' ;;
    *) exec /bin/ps "$@" ;;
  esac
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$fb/ps"
}

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a herdr reclaim safely.

## Firstmate spec
Keep the recorded endpoint when it outlives its server.
EOF
  {
    echo "window=$ses:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=pi"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$ses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$survivor" > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
  TASK_TMPS+=("/tmp/fm-$id")
}

# Sets HERDR_CASE_DIR rather than echoing it, so callers invoke it as a plain
# statement. A `dir=$(herdr_case_or_skip ...)` would run add_herdr_ship_task in
# a command-substitution subshell, where its TASK_TMPS registration would
# mutate a discarded copy and the EXIT trap would never remove the
# out-of-tmproot /tmp/fm-<id> root the spawn creates.
HERDR_CASE_DIR=
herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

test_herdr_relaunch_must_not_resume_the_prior_pi_session() {
  local dir out rc=0 command log keeps
  for keeps in no yes; do
    herdr_case_or_skip "fresh-$keeps" "fresh-$keeps" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    # Herdr still binds the pane's status to the previous agent's session,
    # while process-info proves that agent has exited.
    printf '{"result":{"agent":{"agent":"pi","agent_status":"idle","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      > "$dir/fake/herdr-agent-registration"
    [ "$keeps" = no ] || : > "$dir/fake/herdr-keeps-binding"
    out=$(run_spawn "$dir" "fresh-$keeps" --relaunch --harness pi 2>&1) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete (binding kept: $keeps)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    assert_not_contains "$command" "--session" \
      "the replacement Pi must start a fresh session, never the one its predecessor left bound"
    assert_not_contains "$command" "pi-bound-session" \
      "the replacement Pi must not be handed its predecessor's conversation"
    log=$(cat "$dir/fake/herdr-log")
    printf '%s\n' "$log" | grep -n -m1 -- '^pane report-agent %7 --source herdr:pi --agent pi --state idle --seq [0-9]* --session fmlab$' > "$dir/report-line" \
      || fail "the relaunch must clear the stale binding with a sessionless report from herdr:pi"$'\n'"$log"
    [ "$(cut -d: -f1 "$dir/report-line")" -lt "$(printf '%s\n' "$log" | grep -n -m1 '^pane send-text %7 ' | cut -d: -f1)" ] \
      || fail "the stale binding must be cleared before the fresh launch is typed"$'\n'"$log"
    if [ "$keeps" = no ]; then
      assert_not_contains "$out" "still binds its previous agent's session" \
        "a cleared binding needs no warning"
    else
      assert_contains "$out" "still binds its previous agent's session" \
        "a binding Herdr kept must be reported while the relaunch still starts fresh"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: a Herdr Pi relaunch starts a fresh session and clears the stale status binding"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir out rc=0 log stray
  herdr_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl68 --relaunch --harness pi) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" rl68 herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" rl68 herdr_pane_id)"
  [ "$(meta_field "$dir" rl68 herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" rl68 herdr_tab_id)"
  [ "$(meta_field "$dir" rl68 window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" rl68 window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir out rc=0
  herdr_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  herdr_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl73 --relaunch --harness pi) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" rl73 herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" rl73 herdr_session)"
  [ "$(meta_field "$dir" rl73 window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" rl73 window)"
  [ "$(meta_field "$dir" rl73 herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" rl73 herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" rl74 --relaunch --harness pi); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" rl74 herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir out rc=0 head_before
  herdr_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/rl75.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/rl75.check.sh"
  chmod 0700 "$dir/home/state/rl75.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" rl75 >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/rl75.status"

  out=$(run_control "$dir" rl75 relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-rl75" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" rl75 worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" rl75 pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/rl75.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/rl75.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/rl75.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/rl75/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" rl75 exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  herdr_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" rl77 --relaunch --harness pi); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_relaunch_refuses_a_recorded_worktree_that_is_the_primary_home() {
  local dir out rc
  herdr_case_or_skip homewt rl11 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  sed -i.bak "s#^worktree=.*#worktree=$dir/home#" "$dir/home/state/rl11.meta"
  out=$(run_spawn "$dir" rl11 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "a worktree that is the primary home should refuse"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary home"
  [ ! -s "$dir/fake/launched-command" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: a recorded worktree that is the primary home refuses"
}

test_relaunch_refuses_a_recorded_worktree_that_is_the_project_primary_checkout() {
  local dir out rc
  herdr_case_or_skip projwt rl12 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  sed -i.bak "s#^worktree=.*#worktree=$dir/proj#" "$dir/home/state/rl12.meta"
  out=$(run_spawn "$dir" rl12 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "a worktree that is the project primary checkout should refuse"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary checkout"
  [ ! -s "$dir/fake/launched-command" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: a recorded worktree that is the project primary checkout refuses"
}

# Inherited Git location overrides must not disguise the primary checkout:
# a linked worktree's GIT_DIR plus the primary checkout as GIT_WORK_TREE would
# make the git-dir and common-dir probes disagree.
test_relaunch_refuses_the_primary_checkout_under_inherited_git_overrides() {
  local dir out rc linked_gd
  herdr_case_or_skip projwtenv rl13 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  linked_gd=$(git -C "$dir/wt" rev-parse --absolute-git-dir)
  sed -i.bak "s#^worktree=.*#worktree=$dir/proj#" "$dir/home/state/rl13.meta"
  out=$(GIT_DIR="$linked_gd" GIT_WORK_TREE="$dir/proj" run_spawn "$dir" rl13 --relaunch 2>&1); rc=$?
  expect_code 1 "$rc" "the primary checkout should refuse even under inherited GIT_DIR/GIT_WORK_TREE"
  assert_contains "$out" "primary home or checkout" "the refusal should name the primary checkout"
  [ ! -s "$dir/fake/launched-command" ] || fail "a refused relaunch must launch nothing"
  pass "fm-spawn --relaunch: inherited Git overrides do not hide the project primary checkout"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  herdr_case_or_skip bytes rl12 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  herdr_case_or_skip symlink-meta rl37 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  out=$(run_spawn "$dir" rl37 --relaunch --harness pi); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  [ ! -s "$dir/fake/herdr-log" ] || fail \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  herdr_case_or_skip pending-close rl36 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  printf 'prior wiring\n' > "$dir/home/state/rl36.pi-ext.ts"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"

  out=$(run_spawn "$dir" rl36 --relaunch --harness pi); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/home/state/rl36.pi-ext.ts" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  herdr_case_or_skip flags rl16 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  herdr_case_or_skip norecord rl17 || return 0
  dir=$HERDR_CASE_DIR
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}


test_herdr_relaunch_must_not_resume_the_prior_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
test_herdr_rebind_stays_in_the_recorded_session
test_herdr_reclaim_refuses_an_agent_that_came_back
test_herdr_reclaim_keeps_the_task_whole
test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
test_relaunch_refuses_a_recorded_worktree_that_is_the_primary_home
test_relaunch_refuses_a_recorded_worktree_that_is_the_project_primary_checkout
test_relaunch_refuses_the_primary_checkout_under_inherited_git_overrides
test_checkpoint_refusal_leaves_the_record_byte_identical
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task

echo "all fm-control relaunch tests passed"
