#!/usr/bin/env bash
# Behavior tests for project ownership across two homes on one machine.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TASKS="$ROOT/bin/fm-tasks-axi.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
HANDOFF="$ROOT/bin/fm-handoff.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
READY_CAPACITY="$ROOT/bin/fm-ready-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-ownership)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_TASK_ID \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

make_pair() {  # <name>; prints a directory holding the homes mine and theirs
  local dir="$TMP_ROOT/$1" home
  for home in mine theirs; do
    mkdir -p "$dir/$home/data" "$dir/$home/state" "$dir/$home/config" "$dir/$home/projects"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/$home/data/backlog.md"
  done
  printf '%s\n' "$dir"
}

write_record() {  # <dir>
  printf '# owners\nshared-site %s\nown-tool %s\n' "$1/theirs" "$1/mine" > "$1/owners"
}

in_home() {  # <dir> <home> <command...>
  local dir=$1 home=$2
  shift 2
  FM_PROJECT_OWNERS_FILE="$dir/owners" FM_HOME="$dir/$home" "$@"
}

ready_ids() {
  awk '/^ready\[/ { on = 1; next } on && /^  / { sub(/^  /, ""); sub(/,.*/, ""); print; next } { on = 0 }' | paste -sd' ' -
}

test_add_does_not_file_a_project_another_home_owns() {
  local dir out status before args argv
  dir=$(make_pair add)
  in_home "$dir" mine "$TASKS" add shared-site-1 "early" --repo shared-site --priority 1 >/dev/null \
    || fail "with no ownership record, add refused a project"
  write_record "$dir"
  before=$(cat "$dir/mine/data/backlog.md")

  for args in "shared-site-2|x|--repo|shared-site" "x|--mint|--prefix|shared-site" "shared-site-3|x" "x|--repo=shared-site"; do
    IFS='|' read -r -a argv <<EOF
$args
EOF
    status=0
    out=$(in_home "$dir" mine "$TASKS" add "${argv[@]}" 2>&1) || status=$?
    expect_code 2 "$status" "add $args"
    assert_contains "$out" "backlog add refused: project shared-site is owned by the Firstmate home at $dir/theirs" \
      "the refusal of add $args did not name the owning home"
    assert_contains "$out" "bin/fm-handoff.sh 'shared-site'" "the refusal of add $args did not name the handoff command"
  done
  assert_equals "$before" "$(cat "$dir/mine/data/backlog.md")" "a refused add changed this home's backlog"

  in_home "$dir" mine "$TASKS" add own-tool-1 "mine" --repo own-tool --priority 1 >/dev/null \
    || fail "add refused a project this home owns"
  in_home "$dir" mine "$TASKS" add other-1 "unrecorded" --repo other --priority 1 >/dev/null \
    || fail "add refused a project the record does not name"
  in_home "$dir" theirs "$TASKS" add shared-site-1 "theirs" --repo shared-site --priority 1 >/dev/null \
    || fail "add refused the owning home its own project"
  pass "backlog add refuses a project another home owns by repo, prefix, or ID, and leaves the backlog unchanged"
}

test_ready_does_not_offer_another_homes_project_for_dispatch() {
  local dir out status
  dir=$(make_pair ready)
  in_home "$dir" mine "$TASKS" add shared-site-1 "early" --repo shared-site --priority 1 >/dev/null
  in_home "$dir" mine "$TASKS" add shared-site-2 "no repo column" --priority 1 >/dev/null
  in_home "$dir" mine "$TASKS" add own-tool-1 "mine" --repo own-tool --priority 1 >/dev/null
  out=$(in_home "$dir" mine "$TASKS" ready | ready_ids)
  assert_equals "shared-site-1 shared-site-2 own-tool-1" "$out" "with no record, ready did not list every item"

  write_record "$dir"
  out=$(in_home "$dir" mine "$TASKS" ready)
  assert_equals "own-tool-1" "$(printf '%s\n' "$out" | ready_ids)" "ready still offered another home's project"
  assert_contains "$out" "count: 1" "the count line still counted another home's items"
  assert_contains "$out" "refused_other_home[2]{id,repo,owner_home}" "ready hid the refused items instead of listing them"
  assert_contains "$out" "  shared-site-1,shared-site,$dir/theirs" "the refused item did not name its owning home"
  assert_equals "own-tool-1" "$(in_home "$dir" mine "$READY_CAPACITY" | paste -sd' ' -)" \
    "the ready-capacity heartbeat still offered another home's project"

  printf 'shared-site\n' > "$dir/owners"
  status=0
  out=$(in_home "$dir" mine "$TASKS" ready 2>&1) || status=$?
  expect_code 2 "$status" "ready over a malformed record"
  assert_contains "$out" "line 1 is not '<project-name> <absolute-home-path>'" "the malformed record line was not named"
  status=0
  out=$(in_home "$dir" mine "$TASKS" add own-tool-2 "x" --repo own-tool 2>&1) || status=$?
  expect_code 2 "$status" "add over a malformed record"
  pass "ready moves another home's items out of the dispatchable table and refuses a malformed record"
}

test_spawn_does_not_launch_into_another_homes_project() {
  local dir out status
  dir=$(make_pair spawn)
  write_record "$dir"
  fm_git_init_commit "$dir/mine/projects/shared-site"
  status=0
  out=$(in_home "$dir" mine "$SPAWN" shared-site-1 projects/shared-site --mode direct-PR --yolo off 2>&1) || status=$?
  expect_code 1 "$status" "spawn into another home's project"
  assert_contains "$out" "spawn of shared-site-1 refused: project shared-site is owned by the Firstmate home at $dir/theirs" \
    "the spawn refusal did not name the owning home"
  assert_contains "$out" "bin/fm-handoff.sh 'shared-site'" "the spawn refusal did not name the handoff command"
  assert_equals "" "$(ls -A "$dir/mine/state")" "a refused spawn left records in this home's state"
  pass "spawn refuses another home's project before it writes any record"
}

test_handoff_delivers_to_the_owners_inbox_not_its_backlog() {
  local dir out status before note
  dir=$(make_pair handoff)
  write_record "$dir"
  printf 'first line\nsecond line\n' > "$dir/body"
  before=$(cat "$dir/theirs/data/backlog.md")
  out=$(in_home "$dir" mine "$HANDOFF" shared-site "Fix the footer" --body-file "$dir/body") \
    || fail "handoff to the owning home failed: $out"
  assert_contains "$out" "handed off to $dir/theirs: Fix the footer" "handoff did not report its delivery"
  out=$(in_home "$dir" mine "$HANDOFF" shared-site "Fix the footer" --body-file "$dir/body") \
    || fail "a retried handoff failed: $out"
  assert_contains "$out" "replay" "a retried handoff saved a second note"

  note=$(FM_HOME="$dir/theirs" "$INBOX" list)
  assert_contains "$note" "Task handoff for project shared-site: Fix the footer" "the owner's inbox lacks the proposal title"
  assert_contains "$note" "From the Firstmate home at $dir/mine" "the proposal did not name the sending home"
  assert_contains "$note" "second line" "the proposal lost its body"
  assert_equals 1 "$(find "$dir/theirs/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" \
    "the owner's inbox does not hold exactly one note"
  assert_equals "$before" "$(cat "$dir/theirs/data/backlog.md")" "handoff wrote the owning home's backlog"
  assert_absent "$dir/mine/state/inbox" "handoff wrote the sending home's inbox"

  status=0
  out=$(in_home "$dir" mine "$HANDOFF" own-tool "x" 2>&1) || status=$?
  expect_code 1 "$status" "handoff of this home's own project"
  assert_contains "$out" "no other Firstmate home owns project own-tool" "handoff of an own project did not say why"
  status=0
  out=$(in_home "$dir" mine "$HANDOFF" shared-site "" 2>&1) || status=$?
  expect_code 2 "$status" "handoff with an empty title"
  pass "handoff saves one replay-safe note in the owner's inbox and never touches its backlog"
}

if command -v tasks-axi >/dev/null 2>&1; then
  test_add_does_not_file_a_project_another_home_owns
  test_ready_does_not_offer_another_homes_project_for_dispatch
else
  echo "skip: tasks-axi not found; backlog add and ready cases not run"
fi
test_spawn_does_not_launch_into_another_homes_project
test_handoff_delivers_to_the_owners_inbox_not_its_backlog
