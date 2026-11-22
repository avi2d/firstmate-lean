#!/usr/bin/env bash
# Regression tests for cleanup endpoint and worktree-slot identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
fixture=$(dirname "$0")
case "$*" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}'
    exit 0
    ;;
esac
[ "${@: -2:1}" = --session ] && [ "${@: -1}" = close-fixture ]
case "$1 $2" in
  'session list')
    jq -cn --arg socket "$fixture/herdr.sock" '{sessions:[{name:"close-fixture",running:true,socket_path:$socket}]}'
    ;;
  'pane get')
    [ "${FM_TEST_UNKNOWN_PANE:-0}" != 1 ] || exit 1
    if [ ! -f "$fixture/$3" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    jq -cn --arg pane "$3" --arg cwd "${FM_TEST_PANE_CWD:-$fixture}" '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}'
    ;;
  'pane close')
    printf 'herdr close <%s> <%s>\n' "$3" "${@: -1}" >> "${FM_RUNTIME_LOG:?}"
    [ "${FM_TEST_BLOCK_CLOSE:-0}" != 1 ] || exit 1
    rm -f -- "$fixture/$3"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/herdr" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  : > "$dir/worktree/sentinel"
}

claim_pool_slot() {  # <case> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home}
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/pool/1/.fm-slot-owner"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p3" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t3" "herdr_pane_id=w1:p3" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

# A record whose worktree identity is unusable refuses, and that refusal has to
# leave the operator somewhere: a message that only says what is missing sends
# the next reader hunting for a cause instead of restoring the line, and the
# refusal is unconditional, so no flag gets them out of it either.
# The refusal itself does not change: it still names what is wrong first, still
# preserves the record, and still refuses under --force.
test_worktree_identity_refusal_names_the_repair_path() {
  local dir id=repair-hint err printed shape

  dir=$(make_case repair-hint)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "project=$dir/project" "branch=fm/$id" "kind=ship"
  printf 'worktree=%s\n' "$dir/worktree" > "$dir/home/state/$id.control-relaunch.meta-prior"
  assert_refused_without_mutation "$dir" "$id" "worktree identity without a repair path"

  err=$(cat "$dir/stderr")
  assert_contains "$err" "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." \
    "the refusal must still name what is wrong and that the record is kept"
  assert_contains "$err" "exactly one worktree= line" \
    "the repair must name the end state all three refused shapes share"
  assert_contains "$err" "add it, fill it in, or keep only the right one of several" \
    "the repair must cover a line that is missing, empty, or duplicated, not only a missing one"
  assert_contains "$err" "git -C $dir/project worktree list" \
    "the repair path must name the listing that maps the recorded branch back to its copy"
  assert_contains "$err" "recorded branch fm/$id" \
    "the repair path must name the branch to look for"
  assert_contains "$err" "$dir/home/state/$id.control-relaunch.meta-prior" \
    "the repair path must name the preserved pre-relaunch record when one exists"
  assert_contains "$err" ".fm-slot-owner" \
    "the repair path must say how a reassigned pool slot is proved and why restoring stays safe"

  # Exercise the other two unusable shapes through the public teardown CLI.
  # In each case the refusal must preserve the exact hand-edited record and
  # explain how to reduce it to one correct worktree identity.
  for shape in empty duplicate; do
    dir=$(make_case "repair-hint-$shape")
    if [ "$shape" = empty ]; then
      fm_write_meta "$dir/home/state/$id.meta" \
        "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
        "worktree=" "project=$dir/project" "branch=fm/$id" "kind=ship"
    else
      fm_write_meta "$dir/home/state/$id.meta" \
        "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
        "worktree=$dir/worktree" "worktree=$dir/other-worktree" \
        "project=$dir/project" "branch=fm/$id" "kind=ship"
    fi
    cp "$dir/home/state/$id.meta" "$dir/meta.before"
    assert_refused_without_mutation "$dir" "$id" "$shape worktree identity"
    cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
      || fail "$shape worktree refusal changed the record"
    err=$(cat "$dir/stderr")
    assert_contains "$err" "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." \
      "$shape worktree refusal must stay unchanged"
    assert_contains "$err" "exactly one worktree= line" \
      "$shape worktree repair must name the required end state"
    assert_contains "$err" "add it, fill it in, or keep only the right one of several" \
      "$shape worktree repair must explain how to fix this shape"
    assert_contains "$err" "git -C $dir/project worktree list" \
      "$shape worktree repair must identify the listing to inspect"
    assert_contains "$err" "recorded branch fm/$id" \
      "$shape worktree repair must identify the recorded branch"
    assert_contains "$err" ".fm-slot-owner" \
      "$shape worktree repair must explain reassigned-slot safety"
  done

  # The listing is only useful if it can be copied and run as printed, which a
  # project path with a space breaks unless the command is quoted. Prove it by
  # running exactly what the refusal printed, against exactly such a path.
  dir=$(make_case repair-hint-spaced)
  mv "$dir/project" "$dir/project dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "project=$dir/project dir" "branch=fm/$id" "kind=ship"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  set -e
  printed=$(sed -n '/^git -C .* worktree list$/p' "$dir/stderr")
  [ "$(printf '%s\n' "$printed" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the refusal did not print exactly one standalone worktree listing: $(cat "$dir/stderr")"
  eval "$printed" > "$dir/listing" 2> "$dir/listing-err" \
    || fail "the printed listing did not run as printed: $printed"$'\n'"$(cat "$dir/listing-err")"
  assert_contains "$(cat "$dir/listing")" "$dir/project dir" \
    "the printed listing must inspect the project the record names"
  pass "fm-teardown: an unusable worktree identity refuses as before and names a repair path that runs as printed"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_non_pool_teardown_ignores_task_set_lock() {
  local dir id=non-pool-task lock ready holder i=0
  dir=$(make_case non-pool-task-set-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "non-pool teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "non-pool teardown left task metadata"
  assert_present "$lock" "non-pool teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: non-pool cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_herdr_endpoint_validation_rejects_a_different_pane() {
  local dir id=herdr-task meta
  dir=$(make_case endpoint-validation)
  meta="$dir/home/state/$id.meta"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_write_meta "$meta" "worktree=$dir/worktree" "project=$dir/project" \
    "window=close-fixture:w1:p2" "endpoint_task_id=$id" "backend=herdr" \
    "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$meta" "$id" || fail "valid Herdr endpoint refused"
  assert_equals 'herdr:close-fixture:w1:p2' "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" "validated endpoint"
  fm_write_meta "$meta" "worktree=$dir/worktree" "project=$dir/project" \
    "window=close-fixture:w1:p3" "endpoint_task_id=$id" "backend=herdr" \
    "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  if fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null; then
    fail "validation accepted two different pane identities"
  fi
  pass "Herdr endpoint validation requires matching pane identities"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

test_bare_relative_origin_shares_project_lock_with_clone() {
  local dir second_project primary_lock clone_lock
  dir=$(make_case bare-relative-origin-lock)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm lock-fixture
  mkdir -p "$dir/project/remotes"
  git clone -q --bare "$dir/project" "$dir/project/remotes/origin.git"
  git -C "$dir/project" remote add origin remotes/origin.git
  second_project="$dir/second-project"
  git clone -q "$dir/project/remotes/origin.git" "$second_project"

  primary_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project") \
    || fail "could not resolve the primary project's bare-origin lock"
  clone_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$second_project") \
    || fail "could not resolve the clone project's absolute-origin lock"
  [ "$primary_lock" = "$clone_lock" ] \
    || fail "bare and absolute forms of the same local origin resolved different project locks"

  pass "Treehouse locking resolves a bare local origin against its source project, matching the provisioned clone"
}

test_reused_pool_slot_refuses_before_touching_the_other_task() {
  local dir id=stale-task other=live-task worker rc

  dir=$(make_case slot-reuse)
  mark_case_as_treehouse_pool "$dir"
  # The reuse collision: the pool slot recorded for a finished task has already
  # been handed to another task, whose worker is live in it right now.
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=close-fixture:w1:p3" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t3" "herdr_pane_id=w1:p3" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a second task record still holds"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reused pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a second task record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the live task's record"
  assert_present "$dir/home/state/$id.meta" "teardown removed the stale task's record before refusing"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a contested pool slot: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "refusal should name the other task holding the slot"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # A second task record that is a hardlink of this one is still a second
  # claim on the slot, not this record reached through another spelling.
  dir=$(make_case slot-reuse-hardlink)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  ln "$dir/home/state/$id.meta" "$dir/home/state/$other.meta"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a hardlinked second task record still holds"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a hardlinked second task record still holds"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "hardlink refusal should name the other task record"

  pass "fm-teardown: a pool slot named by a second task record is never returned, killed, or reset"
}

test_sole_slot_record_still_tears_down() {
  local dir id=sole-task worker

  dir=$(make_case slot-sole)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # A neighbouring task on its OWN slot must not look like a collision.
  mkdir -p "$dir/other-worktree"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=close-fixture:w1:p3" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t3" "herdr_pane_id=w1:p3" "endpoint_task_id=neighbour" \
    "worktree=$dir/other-worktree" "project=$dir/project" "kind=scout"
  ( cd "$dir/other-worktree" && exec sleep 30 ) &
  worker=$!

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task that solely holds its slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "uncontested teardown left the task record"
  assert_present "$dir/home/state/neighbour.meta" "uncontested teardown removed the neighbour's record"
  kill -0 "$worker" 2>/dev/null || fail "uncontested teardown killed a worker in a different slot"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "uncontested teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "fm-teardown: a task that solely holds its slot still returns it"
}

test_recorded_endpoint_that_changed_directory_still_tears_down() {
  local dir id=moved-task

  dir=$(make_case slot-endpoint-moved)
  mark_case_as_treehouse_pool "$dir"
  mkdir -p "$dir/other-directory"
  touch "$dir/fakebin/w1:p2" "$dir/fakebin/w1:p3"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  FM_TEST_PANE_CWD="$dir/other-directory" run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown refused its recorded endpoint after it changed directory: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "moved-endpoint teardown left the task record"
  assert_present "$dir/fakebin/w1:p3" "teardown closed the neighboring pane"
  assert_absent "$dir/fakebin/w1:p2" "teardown left the recorded pane present"
  grep -Fxq "herdr close <w1:p2> <close-fixture>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not stop the exact recorded worker: $(cat "$dir/runtime.log")"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not return its uncontested pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: an exact recorded endpoint still tears down after changing cwd outside its worktree"
}

# The slot-reuse sequence with only ONE discoverable record: the finished task's
# worker exited, its slot was granted to another task, and that task leaves no
# record this home can enumerate. Nothing in the record scan contradicts the
# stale worktree= line, so the slot's own owner claim is the only evidence that
# it was reassigned. The slot is no longer this task's, so teardown finishes the
# task's own cleanup and leaves the slot - its worker, its copy, its claim -
# exactly as it found it.
assert_reassigned_slot_left_alone() {  # <case> <id> <other> <description>
  local dir=$1 id=$2 other=$3 description=$4
  assert_absent "$dir/home/state/$id.meta" "$description: the stale task's own record was not removed"
  assert_present "$dir/pool/1/.fm-slot-owner" "$description: another task's slot claim was removed"
  assert_contains "$(cat "$dir/pool/1/.fm-slot-owner")" "task=$other" \
    "$description: another task's slot claim was rewritten"
  assert_present "$dir/pool/1/project/.git" "$description: the reassigned slot's checkout was removed"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "$description: the reassigned slot was returned to the pool: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "$description: the warning should name the task the slot was reassigned to"
  assert_contains "$(cat "$dir/stderr")" "reassigned" \
    "$description: the warning should name the reassignment as the cause"
}

test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot() {
  local dir id=stale-task other=reassigned-task worker rc

  # Dirty slot, --force, and a live worker inside it: --force authorizes
  # discarding this task's unlanded work, which is already gone with the slot,
  # never the other task's live work.
  dir=$(make_case slot-reassigned)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown of a task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reassigned pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot another task had claimed"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "dirty reassigned slot with --force"
  assert_contains "$(cat "$dir/stderr")" "$dir/other-home" \
    "the warning should name the claimant's home"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same reassignment on a CLEAN slot: a landed ship task torn down without
  # --force, which is the shape of the real incident. A clean, fully landed copy
  # passes every unlanded-work check, so only the ownership determination can
  # keep this slot out of the pool; a guard keyed off dirtiness would return it
  # and destroy the live task's copy.
  dir=$(make_case slot-reassigned-clean)
  mark_case_as_treehouse_pool "$dir"
  rm -f "$dir/worktree/sentinel"
  [ -z "$(git -C "$dir/worktree" status --porcelain)" ] \
    || fail "clean-slot fixture is not clean: $(git -C "$dir/worktree" status --porcelain)"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a clean ship task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the clean reassigned pool slot"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "clean reassigned slot without --force"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # A claim that exists but cannot be read as a claim proves nothing either way,
  # so it refuses rather than guessing the slot is still this task's.
  dir=$(make_case slot-claim-unreadable)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot whose claim could not be read"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot whose claim could not be read"
  assert_present "$dir/pool/1/.fm-slot-owner" "teardown removed an unreadable slot claim"
  assert_present "$dir/home/state/$id.meta" "teardown removed the task record on an unreadable claim"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on an unreadable slot claim: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$dir/pool/1/.fm-slot-owner" \
    "unreadable-claim refusal should name the claim file to inspect"

  pass "fm-teardown: a pool slot claimed by another task is left alone while the task's own cleanup finishes"
}

# The claim proves the stale record's teardown is records-only, so the record
# scan must not refuse it; once it is gone, the claimant tears down normally.
test_stale_record_on_claimed_slot_retires_then_claimant_tears_down() {
  local dir id=stale-task other=live-task rc

  dir=$(make_case slot-reassigned-both-records)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=close-fixture:w1:p3" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t3" "herdr_pane_id=w1:p3" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "records-only teardown of a stale record on a claimed slot failed: $(cat "$dir/stderr")"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "stale record beside the claimant's record"
  assert_present "$dir/worktree/sentinel" "records-only teardown reset the claimant's slot"
  assert_present "$dir/home/state/$other.meta" "records-only teardown removed the claimant's record"

  : > "$dir/runtime.log"
  run_case "$dir" "$other" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "claimant teardown failed after the stale record retired: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$other.meta" "claimant teardown left its record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "claimant teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "claimant teardown did not return its pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a stale record on a claimed slot retires, then the claimant tears down"
}

# The two states that must never become a false refusal: the task's own claim,
# and no claim at all (a slot taken before claims existed, or already returned).
test_own_and_absent_slot_claims_still_tear_down() {
  local dir id=owned-task

  dir=$(make_case slot-claim-own)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task holding its own slot claim failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "own-claim teardown left the task record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "own-claim teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "own-claim teardown did not return its own pool slot: $(cat "$dir/runtime.log")"

  dir=$(make_case slot-claim-absent)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of an unclaimed slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "unclaimed-slot teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "unclaimed-slot teardown did not return its pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a task's own slot claim, and an unclaimed slot, both still tear down"
}

test_teardown_does_not_remove_records_without_confirmed_pane_absence() {
  local dir id=blocked-close mode
  for mode in present unknown; do
    dir=$(make_case "$mode-close")
    mark_case_as_treehouse_pool "$dir"
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=close-fixture:w1:p2" "endpoint_task_id=$id" \
      "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" \
      "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
    touch "$dir/fakebin/w1:p2"
    if FM_TEST_BLOCK_CLOSE=1 FM_TEST_UNKNOWN_PANE="$([ "$mode" = unknown ] && printf 1 || printf 0)" \
      run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"; then
      fail "$mode pane allowed teardown without evidence that it was gone"
    fi
    if [ "$mode" = unknown ]; then
      assert_grep "ambiguous structured presence; nothing was changed" "$dir/stderr" "$mode pane refusal"
      assert_no_grep "herdr close" "$dir/runtime.log" "$mode pane was closed although its presence was unreadable"
    else
      assert_grep "not confirmed gone" "$dir/stderr" "$mode pane refusal"
    fi
    assert_present "$dir/home/state/$id.meta" "$mode pane lost its record"
    assert_present "$dir/worktree/sentinel" "$mode pane lost its worktree content"
    assert_no_grep "treehouse <return>" "$dir/runtime.log" "$mode pane allowed a pool return"
  done
  pass "teardown preserves the record and worktree even with force when pane absence is not proved"
}

test_teardown_removes_link_without_following_its_target() {
  local failures=0 mode
  for mode in normal retargeted; do
    (
      local dir id=link-task target
      dir=$(make_case "link-$mode")
      mark_case_as_treehouse_pool "$dir"
      fm_write_meta "$dir/home/state/$id.meta" \
        "window=close-fixture:w1:p2" "backend=herdr" "herdr_session=close-fixture" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "endpoint_task_id=$id" \
        "worktree=$dir/worktree" "project=$dir/project" "kind=scout" "worker_name=$id"
      claim_pool_slot "$dir" "$id"
      mkdir -p "$dir/home/worktrees" "$dir/other"
      : > "$dir/other/sentinel"
      target="$dir/worktree"
      [ "$mode" != retargeted ] || target="$dir/other"
      ln -s "$target" "$dir/home/worktrees/$id"
      run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
        || fail "$mode link teardown failed: $(cat "$dir/stderr")"
      grep -Fq "treehouse <return> <--force> <$dir/worktree>" "$dir/runtime.log" \
        || fail "$mode link changed the returned worktree"
      [ -f "$dir/other/sentinel" ] || fail "$mode link target was touched"
      [ ! -L "$dir/home/worktrees/$id" ] || fail "$mode link survived teardown"
    ) || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "$failures task-link teardown checks failed"
  pass "teardown removes task links without following retargeted links"
}

test_teardown_removes_link_without_following_its_target
test_invalid_endpoint_records_refuse_before_mutation
test_herdr_endpoint_validation_rejects_a_different_pane
test_teardown_does_not_remove_records_without_confirmed_pane_absence
test_worktree_identity_refusal_names_the_repair_path
test_control_lock_contention_refuses_before_mutation
test_non_pool_teardown_ignores_task_set_lock
test_metadata_lock_serializes_destructive_cleanup
test_recorded_process_identity_cleanup_is_exact
test_bare_relative_origin_shares_project_lock_with_clone
test_reused_pool_slot_refuses_before_touching_the_other_task
test_sole_slot_record_still_tears_down
test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot
test_stale_record_on_claimed_slot_retires_then_claimant_tears_down
test_own_and_absent_slot_claims_still_tear_down
test_recorded_endpoint_that_changed_directory_still_tears_down
