#!/usr/bin/env bash
# fm-spawn.sh on the Herdr backend: a fresh task copy is leased durably and the
# pane's TOP-LEVEL shell is moved into it.
#
# Herdr restores a pane from the cwd of its top-level shell, and the pane's
# `cwd` field does not follow a nested shell (only `foreground_cwd` does). The
# interactive `treehouse get` runs a subshell, so the later `cd` landed inside
# it and a host restart reopened every worker in the primary clone. These cases
# pin the replacement: `treehouse get --lease`, then a cd the stub applies to
# the top-level shell, never the interactive form.
#
# Canned/stateful fakes only - never a real herdr session or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_lease_case <name>: a home, a project, and the leased task copy.
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" pi
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; }
    printf '%s\n' "$FM_FAKE_SLOT" ;;
  'get') printf '%s' "$FM_FAKE_SLOT" > "$D/fg" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'session list')
    if [ -f "$D/fail-task-tab-create" ]; then
      jq -cn --arg socket "$D/herdr.sock" '{sessions:[{name:"fixture-lease",running:true,socket_path:$socket}]}'
    fi
    exit 0 ;;
  'terminal title') printf '{"result":{"reason":"no_foreground_client"}}\n'; exit 0 ;;
  'pane close')
    if [ "${3:-}" = '%1' ]; then rm -f "$D/workspace-label"; fi
    : > "$D/pane-gone"; exit 0 ;;
  'pane get')
    [ ! -f "$D/pane-gone" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 0; }
    if [ -f "$D/workspace-label" ] && [ "${3:-}" = '%1' ]; then
      printf '{"result":{"pane":{"pane_id":"%%1","workspace_id":"wsnew","tab_id":"seedtab"}}}\n'
      exit 0
    fi
    if [ -f "$D/cd-sent" ] && [ -f "$D/delay-reads" ]; then
      reads=$(cat "$D/reads" 2>/dev/null || printf 0)
      reads=$((reads + 1)); printf '%s' "$reads" > "$D/reads"
      if [ "$reads" -ge "$(cat "$D/delay-reads")" ]; then
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$FM_FAKE_SLOT" "$D/fg"
      fi
    fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${3:-}" "$(cat "$D/cwd")" "$(cat "$D/fg")"
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    payload=${payload# }
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        sends=$(cat "$D/cd-sends" 2>/dev/null || printf 0)
        sends=$((sends + 1)); printf '%s' "$sends" > "$D/cd-sends"
        : > "$D/cd-sent"
        [ ! -f "$D/never-moves" ] || exit 0
        [ ! -f "$D/delay-reads" ] || exit 0
        [ ! -f "$D/drop-first-cd" ] || [ "$sends" -gt 1 ] || exit 0
        bash -c 'cd -- "$1" && pwd -P > "$2"' bash "$path" "$D/cwd"
        cp "$D/cwd" "$D/fg" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        [ ! -f "$D/launch-send-fails" ] || exit 1
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"result":{"agent":{"agent_status":"shell-starting"}}}\n'
    fi
    exit 0 ;;
  'workspace list')
    if [ -f "$D/workspace-label" ]; then
      jq -cn --arg label "$(cat "$D/workspace-label")" \
        '{result:{workspaces:[{workspace_id:"wsnew",label:$label,focused:true,active_tab_id:"seedtab"}]}}'
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    exit 0 ;;
  'workspace create')
    if [ -f "$D/fail-task-tab-create" ]; then
      for ((i=3; i<$#; i++)); do
        [ "${!i}" = --label ] || continue
        next=$((i + 1))
        printf '%s\n' "${!next}" > "$D/workspace-label"
        break
      done
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\n'
    exit 0 ;;
  'tab list')
    if [ -f "$D/workspace-label" ]; then
      printf '{"result":{"tabs":[{"tab_id":"seedtab","label":"1","focused":true}]}}\n'
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    exit 0 ;;
  'tab create')
    [ ! -f "$D/fail-task-tab-create" ] || exit 1
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr"
  fm_fake_exit0 "$fb" pi
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" HERDR_SESSION=fixture-lease \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend herdr --harness pi --mode no-mistakes --yolo off "$@" 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    "the task copy was not leased durably under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get opened a nested shell the restore cannot see"
  [ "$(cat "$dir/fake/cwd")" = "$dir/slot" ] \
    || fail "the pane's restorable top-level cwd is '$(cat "$dir/fake/cwd")', not the task copy"
  [ "$(cat "$dir/fake/cd-sends")" = 1 ] || fail "an immediately ready pane received a redundant cd"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  pass "a fresh herdr spawn leases the copy and moves the pane's top-level shell into it"
}

test_failed_lease_refuses_without_a_record() {
  local id=lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the spawn and falls back to nothing"
}

test_failed_remote_flat_spawn_does_not_leave_a_home_workspace() {
  local id=remote-flat-abort dir out status list
  dir=$(make_lease_case "$id")
  printf 'execution\n' > "$dir/home/.fm-exec-home"
  printf 'off\n' > "$dir/home/config/herdr-presentation-spaces"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  : > "$dir/fake/fail-task-tab-create"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 1 "$status" "the task tab failure should abort the execution machine launch"$'\n'"$out"
  assert_grep '^tab create ' "$dir/fake/herdr-log" "spawn never reached the injected tab failure"
  list=$(FM_FAKE_DIR="$dir/fake" "$dir/fakebin/herdr" workspace list --session fixture-lease)
  [ "$(jq -c '.result.workspaces' <<< "$list")" = '[]' ] || fail "failed launch left an idle workspace: $list"
  ! grep -q '^workspace create .* --label firstmate ' "$dir/fake/herdr-log" \
    || fail "flat launch created a home-labelled workspace on an execution machine"
  pass "failed flat launch on an execution machine neither creates a home workspace nor leaves an idle workspace"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the pane"
  assert_contains "$out" "treehouse return --force $dir/slot" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "an aborted spawn keeps the lease and names the command that releases it"
}

test_rolled_back_spawn_after_launch_names_the_lease_it_keeps() {
  local id=lease-after-launch dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_contains "$out" "stays leased to $id" "a rolled-back spawn after its launch left the lease unnamed"
  assert_contains "$out" "treehouse return --force $dir/slot" "a rolled-back spawn after its launch did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "a spawn rolled back after its launch keeps the lease and names the command that releases it"
}

abort_pi_spawn() {
  local id=$1 dir
  dir=$(make_lease_case "$id")
  case "$2" in
    dirty) echo dirty >> "$dir/slot/README.md" ;;
    launch-fails) : > "$dir/fake/launch-send-fails" ;;
  esac
  LEASE_OUT=$(run_lease_spawn "$dir" "$id")
  LEASE_STATUS=$?
  LEASE_DIR=$dir
}

test_abort_keeps_the_lease_while_the_pane_is_present() {
  local id=lease-close-refused
  abort_pi_spawn "$id" dirty
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  ! grep -q 'pane close' "$LEASE_DIR/fake/herdr-log" || fail "the kill closed the pane without its presentation lock"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned the lease while its pane is still present"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort with its pane still present did not name the lease it keeps"
  pass "an abort whose pane is still present keeps the lease and names it"
}

test_delayed_worktree_entry() {
  local id=lease-delayed-cd dir out status
  dir=$(make_lease_case "$id")
  printf 25 > "$dir/fake/delay-reads"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "delayed cwd should settle after the old 20-read limit"$'\n'"$out"
  [ "$(cat "$dir/fake/reads")" -ge 25 ] || fail "the delay was not exercised"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr waits past the former deadline for a delayed shell cwd"
}

test_dropped_worktree_entry() {
  local id=lease-dropped-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/drop-first-cd"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  expect_code 0 "$status" "a dropped first cd should recover"$'\n'"$out"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "cd was not resent exactly once"
  pass "Herdr recovers a dropped initial cd with one resend"
}

test_never_moving_worktree_entry() {
  local id=lease-stuck-cd dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/never-moves"
  out=$(run_lease_spawn "$dir" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pane that never moves was accepted"
  assert_contains "$out" "not its recorded worktree" "wrong cwd did not refuse"
  assert_contains "$out" "Herdr pane 'fixture-lease:%9'" "refusal did not identify the pane"
  assert_contains "$out" "last foreground_cwd='$dir/project'" "refusal lost the last cwd"
  assert_contains "$out" "agent_status='shell-starting'" "refusal lost agent status"
  [ "$(cat "$dir/fake/cd-sends")" = 2 ] || fail "a stuck pane received more than one retry"
  [ ! -e "$dir/fake/launched-command" ] || fail "a harness started outside its copy"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published metadata"
  pass "Herdr refuses a never-moving pane with diagnostic context and no launch"
}

test_delayed_worktree_entry
test_dropped_worktree_entry
test_never_moving_worktree_entry

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_failed_lease_refuses_without_a_record
test_failed_remote_flat_spawn_does_not_leave_a_home_workspace
test_aborted_spawn_names_the_lease_it_keeps
test_rolled_back_spawn_after_launch_names_the_lease_it_keeps
test_abort_keeps_the_lease_while_the_pane_is_present

echo "# all fm-spawn-herdr-lease tests passed"
