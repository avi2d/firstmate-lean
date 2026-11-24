#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh home addressing and bootstrap's
# shadow-backlog check, over the split layout where the operational home lives
# outside the code root that carries the tracked .tasks.toml.
#
# The fork these guard against: .tasks.toml names data/backlog.md relative to
# the caller's working directory, and tasks-axi writes by renaming a temp file
# over its target, so a bare tasks-axi run from the code root turns a code-root
# symlink into the home's backlog into a private regular copy. The suite proves
# that every write through bin/fm-tasks-axi.sh lands in $FM_HOME/data from the
# code root (including archiving and relative --body-file arguments),
# that the command refuses addressing it cannot keep correct, and that bootstrap
# reports any code-root copy that is not this home's own file while staying
# silent for a link into the home, an absent copy, and the single-home layout.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The developer shell may pin any of these; each case states its own layout.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  fm_test_tasks_toml "$dir/code/.tasks.toml"
  empty_backlog "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

# Run the wrapper from the code root, as firstmate does.
wrapper_from_code() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

# Only the shadow-backlog lines matter here; the rest of a detect-only local
# bootstrap pass reports this host's toolchain, which is not under test, so it
# runs on the bare base PATH where every tool probe is a fast miss.
bootstrap_backlog_lines() {  # <code-root> [<home>]
  local code=$1 home=${2:-}
  if [ -n "$home" ]; then
    PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  else
    PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  fi
}

test_guard_reports_regular_code_root_backlog() {
  local dir out
  dir=$(make_split guard-regular)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "a code-root link into this home must stay silent"

  rm "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "an absent code-root backlog must stay silent"

  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a regular code-root backlog beside a separate home was not reported"
  assert_not_contains "$out" "done-archive.md" "an absent code-root archive was reported"
  pass "bootstrap reports a regular code-root backlog and stays silent for a link into the home or no copy"
}

test_guard_reports_foreign_link_and_archive() {
  local dir out
  dir=$(make_split guard-foreign)
  empty_backlog "$dir/elsewhere.md"
  rm "$dir/code/data/backlog.md"
  ln -s "$dir/elsewhere.md" "$dir/code/data/backlog.md"
  printf '## Done\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
    "a code-root backlog linked outside this home was not reported"
  assert_contains "$out" "code-root $dir/code/data/done-archive.md is not this home's $dir/home/data/done-archive.md" \
    "a regular code-root archive beside a separate home was not reported"
  pass "bootstrap reports a code-root backlog linked elsewhere and a forked archive"
}

test_guard_silent_for_single_home() {
  local dir out
  dir="$TMP_ROOT/single-guard"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  printf '## Done\n' > "$dir/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir")
  assert_equals "" "$out" "the single-home layout's own backlog was reported as a fork"
  out=$(bootstrap_backlog_lines "$dir" "$dir")
  assert_equals "" "$out" "FM_HOME naming the code root was reported as a fork"
  pass "bootstrap stays silent when the code root is the home"
}

# The end-to-end fork: a bare tasks-axi write from the code root. Whatever the
# installed tasks-axi does to the link, bootstrap must agree with the result:
# a replaced link is reported, a written-through link is not.
test_bare_tasks_axi_fork_is_detected() {
  local dir out
  dir=$(make_split bare-fork)
  (cd "$dir/code" && tasks-axi add bare-1 "written from the code root" >/dev/null 2>&1) \
    || fail "bare tasks-axi add failed in the code root"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  if [ -L "$dir/code/data/backlog.md" ]; then
    assert_grep "bare-1" "$dir/home/data/backlog.md" "a written-through link lost the row"
    assert_equals "" "$out" "a written-through link was reported as a fork"
    pass "bare tasks-axi wrote through the code-root link and bootstrap stayed silent"
  else
    assert_no_grep "bare-1" "$dir/home/data/backlog.md" "the replaced link still reached the home"
    assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
      "bootstrap missed the fork a bare tasks-axi write left behind"
    pass "bare tasks-axi replaced the code-root link and bootstrap reported the fork"
  fi
}

test_wrapper_writes_through_to_home() {
  local dir i
  dir=$(make_split wrapper-home)
  for i in 1 2; do
    wrapper_from_code "$dir" add "ship-$i" "ship $i" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add call-1 "captain call" >/dev/null || fail "add call-1 failed"
  wrapper_from_code "$dir" hold call-1 --reason "awaiting the captain" --kind captain >/dev/null \
    || fail "hold call-1 failed"
  printf 'RELATIVE-BODY-MARKER\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" update call-1 --body-file body.md >/dev/null \
    || fail "update with a caller-relative --body-file failed"
  wrapper_from_code "$dir" prune --keep 1 >/dev/null || fail "prune failed"

  [ -L "$dir/code/data/backlog.md" ] || fail "a wrapper write replaced the code-root link"
  [ "$dir/code/data/backlog.md" -ef "$dir/home/data/backlog.md" ] \
    || fail "the code-root link no longer names the home's backlog"
  assert_grep "call-1" "$dir/home/data/backlog.md" "the held row did not land in the home"
  assert_grep "RELATIVE-BODY-MARKER" "$dir/home/data/backlog.md" \
    "a caller-relative --body-file was not read from the caller's directory"
  assert_present "$dir/home/data/done-archive.md" "archiving did not reach the home"
  assert_grep "ship-1" "$dir/home/data/done-archive.md" "the oldest closed row was not archived in the home"
  assert_absent "$dir/code/data/done-archive.md" "archiving wrote a code-root archive"
  assert_equals "" "$(bootstrap_backlog_lines "$dir/code" "$dir/home")" \
    "bootstrap reported a fork after only wrapper writes"
  pass "fm-tasks-axi.sh writes, holds, archives, and reads relative body files through to the home from the code root"
}

test_wrapper_overrides_ambient_file() {
  local dir
  dir=$(make_split wrapper-ambient)
  empty_backlog "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add amb-1 "ambient" >/dev/null) \
    || fail "add under an ambient TASKS_AXI_FILE failed"
  assert_grep "amb-1" "$dir/home/data/backlog.md" "an ambient TASKS_AXI_FILE diverted the write from the home"
  assert_no_grep "amb-1" "$dir/decoy.md" "an ambient TASKS_AXI_FILE received the write"
  wrapper_from_code "$dir" >/dev/null || fail "the no-command dashboard failed"
  pass "fm-tasks-axi.sh pins the home's backlog over an ambient TASKS_AXI_FILE and serves the dashboard"
}

test_wrapper_refusals() {
  local dir out rc before
  dir=$(make_split wrapper-refuse)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add r-2 "through a link" 2>&1)
  rc=$?
  expect_code 2 "$rc" "symlinked home backlog"
  assert_contains "$out" "is a symlink" "the symlinked home backlog refusal did not name the link"
  [ -L "$dir/home/data/backlog.md" ] || fail "a refused call still replaced the home link"
  assert_equals "$before" "$(cat "$dir/home/real-backlog.md")" "a refused call changed the backlog"

  out=$(cd "$dir/code" && FM_HOME="$dir/missing-home" "$WRAPPER" list 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing data directory"
  pass "fm-tasks-axi.sh refuses caller --file, a symlinked home backlog, and an unresolvable home"
}

# Dispatch alone moves a row to In flight, because only bin/fm-spawn.sh
# creates the task record, status file, and inbox that go with it; a row
# hand-placed there through `add --start` would count as live work nobody runs.
test_wrapper_refuses_add_start() {
  local dir out rc before
  dir=$(make_split wrapper-add-start)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add hs-1 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-1" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-1 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

# The captain's tier pick for this home's projects.
write_captain_tiers() {  # <config-dir>
  printf '%s\n' '# fleet speed tiers' 'website P0' 'ru-compliance P1' 'checks P1' \
    'tui-dash P2' 'orc P2' 'skills P2' 'dotfiles P2' 'firstmate P2' \
    'no-mistakes P2' 'pi-claude-bridge P2' 'home-vpn P2' \
    'career P3' 'learning P3' 'socials P3' 'decisions P3' 'clauth P3' \
    > "$1/project-tiers"
}

ready_ids() {  # reads tasks-axi ready output on stdin
  awk '/^ready\[/ { rows = 1; next } rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); sub(/,.*/, ""); print; next } { rows = 0 }' \
    | paste -sd' ' -
}

test_wrapper_ready_orders_by_project_tier() {
  local dir out status
  dir=$(make_split ready-tiers)
  wrapper_from_code "$dir" add career-1 "career" --repo career >/dev/null
  wrapper_from_code "$dir" add mystery-1 "untiered" --repo mystery >/dev/null
  wrapper_from_code "$dir" add tui-dash-1 "first tui" --repo tui-dash >/dev/null
  wrapper_from_code "$dir" add checks-1 "checks" --repo checks >/dev/null
  wrapper_from_code "$dir" add website-1 "website" --repo website >/dev/null
  wrapper_from_code "$dir" add tui-dash-2 "second tui" --repo tui-dash >/dev/null
  wrapper_from_code "$dir" add ru-compliance-1 "ru" --repo ru-compliance >/dev/null
  wrapper_from_code "$dir" add none-1 "no project" >/dev/null

  out=$(wrapper_from_code "$dir" ready | ready_ids)
  assert_equals "career-1 mystery-1 tui-dash-1 checks-1 website-1 tui-dash-2 ru-compliance-1 none-1" "$out" \
    "with no tier file ready must keep tasks-axi's own order"

  write_captain_tiers "$dir/home/config"
  out=$(wrapper_from_code "$dir" ready | ready_ids)
  assert_equals "website-1 checks-1 ru-compliance-1 tui-dash-1 tui-dash-2 career-1 mystery-1 none-1" "$out" \
    "ready did not list P0, P1, P2, P3, then untiered work, in tasks-axi order within a tier"

  printf 'website P0\nskills p2\n' > "$dir/home/config/project-tiers"
  status=0
  out=$(wrapper_from_code "$dir" ready 2>&1) || status=$?
  expect_code 2 "$status" "ready ran over a malformed tier file"
  assert_contains "$out" "project tiers not applied: $dir/home/config/project-tiers line 2 is not '<project-name> P0|P1|P2|P3'" \
    "the malformed tier line was not named"
  assert_contains "$out" "fm-tasks-axi: fix or remove $dir/home/config/project-tiers to list ready work" \
    "the refusal did not say how to recover"
  assert_not_contains "$out" "website-1" "ready listed work in an order the tier file did not give"

  printf 'website P0\nwebsite P1\n' > "$dir/home/config/project-tiers"
  out=$(wrapper_from_code "$dir" ready 2>&1) || true
  assert_contains "$out" "line 2 names website a second time" "a project tiered twice was not refused"
  pass "fm-tasks-axi.sh ready lists higher project tiers first and refuses a malformed tier file"
}

make_backlog_md_home() {
  mkdir -p "$1/data/backlog/tasks" "$1/config" "$1/state"
  printf '%s\n' 'filesystem_only: true' 'statuses: [Queued, Waiting, In Flight, Done]' 'task_prefix: task' > "$1/data/backlog/config.yml"
  printf '%s\n' backlog-md > "$1/config/backlog-backend"
}

write_backlog_md_ticket() {
  printf '%s\n' '---' "id: $2" 'title: Fixture ticket' "status: $3" '---' '' > "$1"
}

test_numbered_ticket_does_not_ship_on_legacy_slug_or_number_only() {
  local home="$TMP_ROOT/named-branch" project="$TMP_ROOT/naming-repo" wt="$TMP_ROOT/naming-copy"
  local id=example-site-2 legacy=blog-page-work branch out
  make_backlog_md_home "$home"
  printf '%s\n' '---' "id: $id" 'title: "Example-site: Blog reading page updates"' \
    'status: Queued' 'labels:' "  - old:$legacy" '---' > "$home/data/backlog/tasks/task-old-filename.md"
  out=$(FM_HOME="$home" bash "$WRAPPER" show "$id") || fail "$out"
  assert_contains "$out" "  id: $id" "numbered ID did not find the ticket by front matter"
  out=$(FM_HOME="$home" bash "$WRAPPER" show "$legacy") && fail "the old label resolved as a task ID"
  assert_contains "$out" 'code: NOT_FOUND' "old label did not return not found"

  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" example-site --mode local-only --branch-prefix work/ >/dev/null \
    || fail "could not scaffold the numbered task"
  branch=$(sed -n 's/^Ship branch: //p' "$home/data/$id/brief.md")
  [ "$branch" = work/example-site-2-blog-reading-page ] || fail "wrong ship branch: $branch"
  fm_git_init_commit "$project" || fail "could not initialize disposable repository"
  git -C "$project" worktree add -q --detach "$wt" HEAD || fail "could not create disposable worktree"
  git -C "$wt" checkout -qb "$branch" -- || fail "could not check out the brief's branch"
  [ "$(git -C "$wt" branch --show-current)" = "$branch" ] || fail "worktree did not switch to the brief's branch"
  grep -qF "old:$legacy" "$home/data/backlog/tasks/task-old-filename.md" || fail "old label was removed"
  pass "the numbered ticket names the ship branch without changing backlog identity"
}

test_backlog_md_mint_counts_drafts_and_archive_without_reusing_ids() {
  local home="$TMP_ROOT/backlog-md-numbering" out rc=0
  make_backlog_md_home "$home"
  mkdir -p "$home/data/backlog/archive/tasks" "$home/data/backlog/drafts"
  write_backlog_md_ticket "$home/data/backlog/tasks/task-other.md" reels-studio-site-99 Queued
  write_backlog_md_ticket "$home/data/backlog/tasks/task-current.md" reels-studio-20 'In Flight'
  write_backlog_md_ticket "$home/data/backlog/archive/tasks/task-closed.md" reels-studio-32 Done

  out=$(FM_HOME="$home" bash "$WRAPPER" add "First numbered task" --mint --prefix reels-studio) || fail "$out"
  printf '%s\n' "$out" | grep -Fxq '  id: reels-studio-33' || fail "an archived number was reused: $out"
  write_backlog_md_ticket "$home/data/backlog/drafts/draft-reserved.md" reels-studio-34 Draft

  out=$(FM_HOME="$home" bash "$WRAPPER" create "Second numbered task" --mint --repo=reels-studio) || fail "$out"
  printf '%s\n' "$out" | grep -Fxq '  id: reels-studio-35' || fail "a number reserved by a draft was reused: $out"
  out=$(FM_HOME="$home" bash "$WRAPPER" add reels-studio-descriptive "Should not be added" --repo reels-studio 2>&1) || rc=$?
  expect_code 2 "$rc" "explicit descriptive ID"
  assert_contains "$out" "reels-studio-36" "the refused ID did not name the next number"
  out=$(FM_HOME="$home" bash "$WRAPPER" list) || fail "$out"
  assert_not_contains "$out" "reels-studio-descriptive" "a refused add still wrote a ticket"
  pass "Backlog.md counts active, draft, and archived IDs, and refuses an explicit slug"
}

test_wrapper_does_not_reuse_numbers_from_the_configured_markdown_archive() {
  local dir out rc=0
  dir=$(make_split wrapper-numbering)
  printf '%s\n' 'backend = "markdown"' '[markdown]' 'archive = "data/historical.md"' > "$dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '- **workflows-15** - Older in-flight row' '' '## Queued' '' '## Done' \
    > "$dir/home/data/backlog.md"
  printf '\n%s\n' '## Archived 2026-11-20' '- [x] workflows-12 - Archived row' > "$dir/home/data/historical.md"

  out=$(wrapper_from_code "$dir" add 'First' --mint --prefix workflows) || fail "$out"
  printf '%s\n' "$out" | grep -Fxq '  id: workflows-16' || fail "the older in-flight syntax did not reserve its ID: $out"
  printf '%s\n' '- [x] workflows-23 - Another archived row' >> "$dir/home/data/historical.md"
  out=$(wrapper_from_code "$dir" create workflows-17 'Gap below archived maximum' --repo workflows 2>&1) || rc=$?
  expect_code 2 "$rc" "explicit number below the archived maximum"
  assert_contains "$out" "workflows-24" "the configured archive did not reserve its IDs"
  out=$(wrapper_from_code "$dir" add workflows-24 'Explicit next task' --repo workflows) || fail "$out"
  printf '%s\n' "$out" | grep -Fxq '  id: workflows-24' || fail "the exact next ID was refused: $out"
  pass "the markdown wrapper counts in-flight work and honors the configured archive"
}

backlog_md_lifecycle_steps() {  # <home>, with FM_HOME naming the same home
  local home=$1 out
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  printf '%s\n' 'spawn_gen=s1.1.1' > "$home/state/transition-task.meta"
  fm_backlog_transition_applies "$home/config" "$home/data" ship || exit 1
  fm_backlog_atomic_transition dispatch "$home/state/transition-task.meta" "$home/data" transition-task "$home/state" || exit 1
  out=$(bash "$WRAPPER" list --state in_flight) || exit 1
  printf '%s\n' "$out" | grep -q 'transition-task,in_flight,' || exit 1
  bash "$ROOT/bin/fm-captain-hold.sh" hold transition-task --reason "Decision needed" >/dev/null || exit 1
  fm_backlog_retain "$home/data" transition-task || exit 1
  out=$(bash "$WRAPPER" show transition-task) || exit 1
  printf '%s\n' "$out" | grep -q '^  state: queued$' || exit 1
  printf '%s\n' "$out" | grep -q '^  held: yes$' || exit 1
  printf '%s\n' approved > "$home/decision"
  bash "$ROOT/bin/fm-captain-hold.sh" answer transition-task --decision-file "$home/decision" --release >/dev/null || exit 1
  fm_backlog_atomic_transition dispatch "$home/state/transition-task.meta" "$home/data" transition-task "$home/state" || exit 1
  : > "$home/state/transition-task.backlog-close"
  fm_backlog_atomic_transition close "$home/state/transition-task.meta" "$home/state/transition-task.backlog-close" "$home/data" transition-task "$home/state" || exit 1
  out=$(bash "$WRAPPER" show transition-task) || exit 1
  printf '%s\n' "$out" | grep -q '^  state: done$' || exit 1
}

missing_python_append_refusal() {  # <home>, with PATH holding only the shims
  hash -r
  if fm_backlog_append_message "$1/data" demo-1 firstmate "Must not be appended"; then
    exit 1
  fi
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" "python3 is required" "missing Python was reported as contention"
}

message_log_lock_steps() {  # <home>, with FM_HOME naming the same home
  local home=$1 out first second
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  bash "$WRAPPER" add demo-1 "Log the steer" --repo demo >/dev/null || exit 1
  exec 8>>"$home/data/.fm-backlog-messages.lock"
  python3 -c 'import fcntl; fcntl.flock(8, fcntl.LOCK_EX)' || exit 1
  if FM_BACKLOG_MESSAGE_LOCK_SECS=0 fm_backlog_append_message "$home/data" demo-1 firstmate "Must not be appended"; then
    exit 1
  fi
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" "stayed busy" "a held lock was not reported as contention"
  exec 8>&-
  ( PATH="$home/shims" missing_python_append_refusal "$home" ) || exit 1
  fm_backlog_append_message "$home/data" demo-1 firstmate "First steer" &
  first=$!
  fm_backlog_append_message "$home/data" demo-1 firstmate "Second steer" &
  second=$!
  wait "$first" || exit 1
  wait "$second" || exit 1
  out=$(bash "$WRAPPER" show demo-1 --full) || exit 1
  assert_contains "$out" "First steer" "first concurrent append was lost"
  assert_contains "$out" "Second steer" "second concurrent append was lost"
  assert_not_contains "$out" "Must not be appended" "a refused append changed the body"
}

test_message_log_preserves_both_appends_without_the_flock_command() {
  local home="$TMP_ROOT/message-lock"
  mkdir -p "$home/data" "$home/config" "$home/shims"
  empty_backlog "$home/data/backlog.md"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '#!/bin/sh\nexit 127\n' > "$home/shims/flock"
  chmod +x "$home/shims/flock"
  ( FM_HOME="$home" PATH="$home/shims:$PATH" message_log_lock_steps "$home" ) \
    || fail "portable message log lock did not serialize writes"
  pass "the backlog keeps both concurrent steers without the flock command"
}

backlog_md_drafts_steps() {  # <home>, with FM_HOME naming the same home
  local home=$1 out
  printf 'other P0\ndemo P3\n' > "$home/config/project-tiers"
  bash "$WRAPPER" add other-1 "Lower priority" --repo other --priority 2 >/dev/null || exit 1
  bash "$WRAPPER" add demo-6 "First urgent" --repo demo --priority 0 >/dev/null || exit 1
  bash "$WRAPPER" add demo-7 "Second urgent" --repo demo --priority 0 >/dev/null || exit 1
  mv "$home/data/backlog/tasks/task-demo-7 - ticket.md" "$home/data/backlog/tasks/task-a.md"
  out=$(bash "$WRAPPER" list) || exit 1
  assert_contains "$out" "demo-4,draft," "list hid a draft"
  out=$(bash "$WRAPPER" list --state draft) || exit 1
  assert_contains "$out" "demo-4,draft," "the draft filter hid a draft"
  assert_not_contains "$out" "other-1,queued," "the draft filter listed a queued task"
  out=$(bash "$WRAPPER" ready) || exit 1
  assert_contains "$out" "drafts[2]{id,state,kind,repo,title}:" "ready hid both drafts"
  assert_equals "demo-6 demo-7 other-1" "$(printf '%s\n' "$out" | ready_ids)" \
    "ready used filename, project tier, or ordinal ahead of task priority, or included a draft"
  if bash "$WRAPPER" start demo-4 >/dev/null; then exit 1; fi
  out=$(FM_SESSION_START_QUEUED_LIMIT=1 bash "$ROOT/bin/fm-session-start.sh" --reemit) || exit 1
  assert_equals "demo-6" "$(printf '%s\n' "$out" | ready_ids)" "the digest bounded ready before sorting it"
  assert_contains "$out" "demo-4,draft," "the digest hid every draft"
  assert_contains "$out" "(shown 1 of 2 draft item(s); 1 more - bin/fm-tasks-axi.sh list --state draft)" \
    "the digest did not disclose omitted drafts"
  assert_not_contains "$out" "demo-5,draft," "the digest did not bound drafts separately"
}

test_backlog_md_keeps_drafts_visible_without_making_them_dispatchable() {
  local home="$TMP_ROOT/backlog-md-ready"
  make_backlog_md_home "$home"
  mkdir -p "$home/data/backlog/drafts"
  write_backlog_md_ticket "$home/data/backlog/drafts/demo-4.md" demo-4 Draft
  write_backlog_md_ticket "$home/data/backlog/drafts/demo-5.md" demo-5 Draft
  ( FM_HOME="$home" backlog_md_drafts_steps "$home" ) \
    || fail "Backlog.md list, ready, and session-start disagree about drafts or priority"
  pass "list, ready, and startup show drafts separately from dispatchable work"
}

test_backlog_md_lifecycle_preserves_a_running_slug_id() {
  local home="$TMP_ROOT/backlog-md-lifecycle"
  make_backlog_md_home "$home"
  write_backlog_md_ticket "$home/data/backlog/tasks/task-existing.md" transition-task Queued
  ( FM_HOME="$home" backlog_md_lifecycle_steps "$home" ) || fail "Backlog.md lifecycle did not retain and complete the task"
  pass "Backlog.md lifecycle retains a held task as queued and completes it"
}

numbered_followup_replay_steps() {  # <home>, with FM_HOME naming the same home
  local home=$1 out line
  . "$ROOT/bin/fm-classify-lib.sh"
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  bash "$WRAPPER" add workflows-1 "Parent task" --repo workflows >/dev/null || exit 1
  bash "$WRAPPER" start workflows-1 >/dev/null || exit 1
  line='followup [at=1795194318]: Correct the stale queue notes'
  fm_backlog_file_followup "$home/config" "$home/data" workflows-1 "$line" || exit 1
  [ "$FM_BACKLOG_FOLLOWUP_ID $FM_BACKLOG_FOLLOWUP_CREATED" = "workflows-2 1" ] || exit 1
  [ -z "$FM_BACKLOG_FOLLOWUP_LOG_ERROR" ] || exit 1
  bash "$WRAPPER" "done" workflows-2 --keep 0 >/dev/null || exit 1
  fm_backlog_file_followup "$home/config" "$home/data" workflows-1 "$line" || exit 1
  [ "$FM_BACKLOG_FOLLOWUP_ID $FM_BACKLOG_FOLLOWUP_CREATED" = "workflows-2 0" ] || exit 1
  out=$(bash "$WRAPPER" add "Separate task" --mint --prefix workflows) || exit 1
  printf '%s\n' "$out" | grep -Fxq '  id: workflows-3' || exit 1
}

test_numbered_followup_replay_does_not_allocate_another_id_after_archiving() {
  local store=$1 home="$TMP_ROOT/followup-$1"
  if [ "$store" = backlog-md ]; then
    make_backlog_md_home "$home"
  else
    mkdir -p "$home/data" "$home/config"
    empty_backlog "$home/data/backlog.md"
  fi
  ( FM_HOME="$home" numbered_followup_replay_steps "$home" ) || fail "$store allocated an incorrect follow-up ID or duplicated an archived follow-up"
  pass "$store files a numbered follow-up once even after it is archived"
}

# A configured non-markdown adapter stands in for the real one: a JSON store
# behind the tasks-axi list/show/add surface, with list cutting each body the
# way tasks-axi does (500 characters, then a line naming the full length).
make_adapter_home() {  # <name> <seed-js>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/home/data" "$dir/home/config"
  cat > "$dir/bin/tasks-axi" <<'JS'
#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const store = process.env.FAKE_AXI_STORE;
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_AXI_LOG, args[0] + '\n');
const tasks = JSON.parse(fs.readFileSync(store, 'utf8'));
const toon = value => /^$|^\s|\s$|[,":\\\n]|^(true|false|null|-?\d)/.test(value) ? JSON.stringify(value) : value;
const listed = task => task.body.length <= 500 ? task.body
  : task.body.slice(0, 500) + '\n... (truncated, ' + task.body.length + ' chars total - use show ' + task.id + ' --full to see complete text)';
const flag = name => args.find(arg => arg.startsWith('--' + name + '='))?.slice(name.length + 3);
if (args[0] === 'list' && args[1] === '--fields' && args[2] === 'body') {
  console.log('count: ' + tasks.length);
  if (tasks.length) console.log('tasks[' + tasks.length + ']{id,state,kind,repo,title,body}:');
  for (const task of tasks) console.log('  ' + [task.id, 'queued', 'task', task.repo, toon(task.title), toon(listed(task))].join(','));
} else if (args[0] === 'show' && args[2] === '--full') {
  const task = tasks.find(candidate => candidate.id === args[1]);
  console.log(['task:', '  id: ' + task.id, '  title: ' + toon(task.title), '  state: queued', '  body: ' + toon(task.body)].join('\n'));
} else if (args[0] === 'add') {
  tasks.push({ id: args[1], title: flag('title'), repo: flag('repo'), body: flag('body') ?? '' });
  fs.writeFileSync(store, JSON.stringify(tasks));
  console.log(JSON.stringify({ ok: true, action: 'add', task: { id: args[1] } }));
} else {
  console.error('fake adapter: unsupported ' + args.join(' '));
  process.exit(2);
}
JS
  chmod +x "$dir/bin/tasks-axi"
  node -e "require('fs').writeFileSync(process.argv[1], JSON.stringify((() => { $2 })()))" "$dir/store.json" \
    || fail "cannot seed the adapter store for $1"
  : > "$dir/calls.log"
  printf '%s\n' "$dir"
}

adapter_followup() {  # <case-dir> <key>; prints the add result
  local dir=$1
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=fakeadapter FAKE_AXI_STORE="$dir/store.json" \
    FAKE_AXI_LOG="$dir/calls.log" FM_HOME="$dir/home" \
    bash "$WRAPPER" add "Follow-up $2" --mint --repo proj --json --followup-key "$2" \
    --body "Follow-up reported by the worker on proj-1."
}

adapter_calls() {  # <case-dir> <verb>
  grep -cx "$2" "$1/calls.log" || true
}

adapter_rows() {  # <case-dir>
  node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).length)" "$1/store.json"
}

test_adapter_followups_over_157_tasks_do_not_read_each_task() {
  local dir key out id start elapsed
  local -a ids=()
  dir=$(make_adapter_home adapter-157 '
    const tasks = [];
    for (let n = 1; n <= 157; n++) tasks.push({ id: "proj-" + n, title: "Task " + n, repo: "proj", body: "Notes for task " + n + "." });
    tasks[39].body = "Follow-up reported by the worker on proj-1.\n\nFollow-up key: proj-1-fu-filed";
    return tasks;')
  start=$(date +%s)
  for key in proj-1-fu-0001 proj-1-fu-0002 proj-1-fu-0003 proj-1-fu-0004; do
    out=$(adapter_followup "$dir" "$key") || fail "adapter follow-up $key failed: $out"
    id=$(printf '%s\n' "$out" | jq -er 'select(.already != true) | .task.id') \
      || fail "adapter follow-up $key was not filed as new: $out"
    ids+=("$id")
  done
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 90 ] || fail "four adapter follow-ups over 157 tasks took ${elapsed}s"
  assert_equals "proj-158 proj-159 proj-160 proj-161" "${ids[*]}" "the four follow-ups did not get the next free IDs"
  assert_equals 4 "$(adapter_calls "$dir" list)" "each follow-up add should list the backlog once"
  assert_equals 0 "$(adapter_calls "$dir" show)" "a follow-up add read tasks one at a time"

  out=$(adapter_followup "$dir" proj-1-fu-0002) || fail "the repeated follow-up failed: $out"
  assert_equals "true proj-159" "$(printf '%s\n' "$out" | jq -r '"\(.already) \(.task.id)"')" \
    "a repeated follow-up key was not matched to its row"
  out=$(adapter_followup "$dir" proj-1-fu-filed) || fail "the pre-filed follow-up failed: $out"
  assert_equals "true proj-40" "$(printf '%s\n' "$out" | jq -r '"\(.already) \(.task.id)"')" \
    "a follow-up already in the backlog was not matched to its row"
  assert_equals 161 "$(adapter_rows "$dir")" "a repeated follow-up key filed another row"
  assert_equals 4 "$(adapter_calls "$dir" add)" "a repeated follow-up key reached the adapter's add"
  pass "four adapter follow-ups over 157 tasks list the backlog once each, and repeated keys file nothing"
}

test_adapter_followup_marker_past_the_list_cut_is_not_refiled() {
  local dir out
  dir=$(make_adapter_home adapter-cut '
    const long = Array.from({ length: 60 }, (_, n) => "context line " + n).join("\n");
    return [
      { id: "proj-1", title: "Parent, with \"quotes\": here", repo: "proj", body: long + "\n\nFollow-up key: proj-1-fu-late" },
      { id: "proj-2", title: "Mention only", repo: "proj", body: "see Follow-up key: proj-1-fu-inline here" },
      { id: "proj-3", title: "true", repo: "proj", body: "intro\n\nFollow-up key: proj-1-fu-early\n\n" + long },
    ];')
  out=$(adapter_followup "$dir" proj-1-fu-late) || fail "the late-marker follow-up failed: $out"
  assert_equals "true proj-1" "$(printf '%s\n' "$out" | jq -r '"\(.already) \(.task.id)"')" \
    "a marker past the list cut was missed and the follow-up filed again"
  : > "$dir/calls.log"
  out=$(adapter_followup "$dir" proj-1-fu-early) || fail "the early-marker follow-up failed: $out"
  assert_equals "true proj-3" "$(printf '%s\n' "$out" | jq -r '"\(.already) \(.task.id)"')" \
    "a marker before the list cut was not matched"
  assert_equals 1 "$(adapter_calls "$dir" show)" "only the earlier cut row should be read in full"
  out=$(adapter_followup "$dir" proj-1-fu-inline) || fail "the inline-mention follow-up failed: $out"
  assert_equals "false proj-4" "$(printf '%s\n' "$out" | jq -r '"\(.already // false) \(.task.id)"')" \
    "a key mentioned inside a line was treated as a follow-up marker"
  pass "an adapter follow-up marker past the list cut is found, and a mention inside a line is not"
}


if [ "${FM_TEST_BACKLOG_MESSAGE_LOCK_ONLY:-0}" = 1 ]; then
  [ "$HAVE_TASKS_AXI" = 1 ] || fail "the message lock test requires tasks-axi"
  test_message_log_preserves_both_appends_without_the_flock_command
  exit 0
fi

test_backlog_md_mint_counts_drafts_and_archive_without_reusing_ids
test_numbered_ticket_does_not_ship_on_legacy_slug_or_number_only
test_backlog_md_keeps_drafts_visible_without_making_them_dispatchable
test_backlog_md_lifecycle_preserves_a_running_slug_id
test_numbered_followup_replay_does_not_allocate_another_id_after_archiving backlog-md
test_adapter_followups_over_157_tasks_do_not_read_each_task
test_adapter_followup_marker_past_the_list_cut_is_not_refiled
test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_message_log_preserves_both_appends_without_the_flock_command
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_does_not_reuse_numbers_from_the_configured_markdown_archive
  test_numbered_followup_replay_does_not_allocate_another_id_after_archiving markdown
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_single_home
  test_wrapper_ready_orders_by_project_tier
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
