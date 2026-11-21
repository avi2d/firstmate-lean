#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of the running
# firstmate repo, which skips a dirty, wrong-branch, detached, or diverged
# checkout instead of forcing it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" "$@" 2>/dev/null
}

test_updates_main_by_single_parent_fast_forward() {
  local w out
  w=$(new_world t1)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  pass "T1 main fast-forwards (single-parent) and signals a reread"
}

test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  pass "T3 a README-only advance skips the reread"
}

test_bin_only_advance_rereads() {
  local w out
  w=$(new_world t3b)
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "a bin/ change is still an instruction-surface advance"
  pass "T3b a bin/-only advance signals a reread"
}

test_dirty_firstmate_skipped() {
  local w out before
  w=$(new_world t4)
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/main/AGENTS.md"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: dirty working tree" "dirty checkout skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  grep -q 'uncommitted local edit' "$w/main/AGENTS.md" \
    || fail "dirty edit was discarded"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "dirty firstmate HEAD moved"
  pass "T4 dirty firstmate skipped, local edit preserved"
}

test_diverged_firstmate_skipped() {
  local w out before
  w=$(new_world t5)
  printf 'fork work\n' > "$w/main/AGENTS.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm local-work
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" "diverged checkout skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "diverged firstmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged firstmate is skipped and its commit preserved"
}

seed_ten_line_agents() {
  local w=$1
  printf 'L%s\n' 1 2 3 4 5 6 7 8 9 10 > "$w/seed/AGENTS.md"
  git -C "$w/seed" add AGENTS.md
  git -C "$w/seed" commit -qm ten-lines
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q --ff-only origin main
}

commit_line_edits() {
  local dir=$1 msg=$2 edit line text
  shift 2
  for edit in "$@"; do
    line=${edit%%=*}
    text=${edit#*=}
    sed -i.bak "${line}s/.*/${text}/" "$dir/AGENTS.md"
    rm -f "$dir/AGENTS.md.bak"
  done
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -qm "$msg"
}

push_rewritten_upstream() {
  local w=$1
  commit_line_edits "$w/seed" rewritten-upstream 2=L2-local 9=L9-upstream
  git -C "$w/seed" push -q origin main
}

test_missing_write_tree_refuses() {
  local w out before real_git
  w=$(new_world t5e)
  seed_ten_line_agents "$w"
  commit_line_edits "$w/main" local-line 2=L2-local
  before=$(git -C "$w/main" rev-parse HEAD)
  push_rewritten_upstream "$w"
  real_git=$(command -v git)
  cat > "$w/fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = merge-tree ]; then
    echo "usage: git merge-tree <base-tree> <branch1> <branch2>" >&2
    exit 129
  fi
done
exec "$real_git" "\$@"
SH
  chmod +x "$w/fakebin/git"

  out=$(run_update "$w" --reconcile-redundant-root) || fail "the update crashed without merge-tree --write-tree: $out"

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" \
    "a git lacking merge-tree --write-tree did not refuse"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "the code root moved without a content proof"
  pass "T5e a git lacking merge-tree --write-tree refuses the divergence"
}

test_code_root_redundant_divergence() {
  local w out before
  w=$(new_world t5f)
  seed_ten_line_agents "$w"
  commit_line_edits "$w/main" local-line 2=L2-local
  before=$(git -C "$w/main" rev-parse HEAD)
  push_rewritten_upstream "$w"

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: skipped: diverged from origin/main" \
    "an ordinary update moved a diverged code root"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "an ordinary update moved a diverged code root"

  out=$(run_update "$w" --reconcile-redundant-root)
  assert_contains "$out" "firstmate: reconciled redundant divergence" \
    "the code root did not reconcile a divergence its target fully contains"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the reconciled code root did not reach origin/main"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = main ] \
    || fail "the reconciled code root left its default branch"
  pass "T5f the code root reconciles a contained divergence only when asked"
}

test_code_root_unique_change_refused() {
  local w out before
  w=$(new_world t5g)
  seed_ten_line_agents "$w"
  commit_line_edits "$w/main" local-line 2=L2-local 5=L5-only-here
  before=$(git -C "$w/main" rev-parse HEAD)
  push_rewritten_upstream "$w"

  out=$(run_update "$w" --reconcile-redundant-root)

  assert_contains "$out" "firstmate: skipped: diverged from origin/main" \
    "a code root holding unique content was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "a code root holding unique content was moved"
  pass "T5g a code root holding content the target lacks stays refused"
}

test_already_current_firstmate_is_idempotent() {
  local w out
  w=$(new_world t6)
  bump_origin "$w" instr
  run_update "$w" >/dev/null

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  pass "T6 a second update finds firstmate already current"
}

test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

add_fork_carry() {
  local w=$1 carry
  git init -q --bare "$w/fork.git"
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  git -C "$w/seed" checkout -q -b carry-work
  printf 'carried\n' >> "$w/seed/AGENTS.md"
  printf 'echo carried\n' > "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm carried-fix
  git -C "$w/seed" push -q "$w/fork.git" carry-work:carry
  carry=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/seed" checkout -q main
  git -C "$w/main" remote add fork "$w/fork.git"
  printf '%s\n' "$carry"
}

write_source() {
  mkdir -p "$1/home/config"
  printf '%s\n' "$2" > "$1/home/config/self-update-source"
}

test_self_update_source_follows_branch() {
  local w out carry
  w=$(new_world t13)
  carry=$(add_fork_carry "$w")
  # origin also moves, and that commit is NOT in the carry branch, so landing
  # on it would prove origin was used.
  bump_origin "$w" readme
  write_source "$w" "fork carry"

  out=$(run_update "$w")

  assert_contains "$out" "self-update source: fork carry" "the configured source is announced"
  assert_contains "$out" "firstmate: updated " "the primary advanced"
  assert_equals "$(git -C "$w/main" rev-parse HEAD)" "$carry" "the primary did not land on the configured branch"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "the primary left its default branch"
  assert_contains "$out" "reread-firstmate: yes" "the carried instruction change triggers a reread"

  # Removing the file returns to origin; the carried commit is not in origin, so
  # that path now reports divergence and moves nothing.
  rm "$w/home/config/self-update-source"
  out=$(run_update "$w")
  assert_not_contains "$out" "self-update source:" "an absent file must not announce a source"
  assert_contains "$out" "firstmate: skipped: diverged from origin/main" "without the file the origin path is used"
  assert_equals "$(git -C "$w/main" rev-parse HEAD)" "$carry" "the origin path moved a diverged primary"
  pass "T13 config/self-update-source moves the primary to that branch"
}

test_self_update_source_refuses_unusable_config() {
  local w before value rc err
  w=$(new_world t14)
  add_fork_carry "$w" >/dev/null
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)

  for value in "nosuchremote carry" "fork" "fork carry extra" "fork bad..branch" $'fork carry\nfork other'; do
    write_source "$w" "$value"
    err=$(PATH="$w/fakebin:$PATH" \
      FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1 >/dev/null)
    rc=$?
    [ "$rc" -ne 0 ] || fail "an unusable self-update source ($value) did not refuse"
    assert_contains "$err" "config/self-update-source" "the refusal ($value) must name the file"
    assert_equals "$(git -C "$w/main" rev-parse HEAD)" "$before" "the primary moved despite an unusable source ($value)"
  done
  pass "T14 an unusable config/self-update-source refuses without falling back to origin"
}

test_self_update_source_rewrite_is_skipped() {
  local w out carry other
  w=$(new_world t15)
  carry=$(add_fork_carry "$w")
  write_source "$w" "fork carry"
  out=$(run_update "$w")
  assert_equals "$(git -C "$w/main" rev-parse HEAD)" "$carry" "setup: the primary did not reach the branch"

  # Replace the branch with an unrelated line of history.
  git -C "$w/seed" checkout -q -b rewritten "$carry~1"
  printf 'other\n' >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm rewritten
  git -C "$w/seed" push -q -f "$w/fork.git" rewritten:carry
  other=$(git -C "$w/seed" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: diverged from refs/remotes/fork/carry" "a rewritten branch must be skipped"
  assert_equals "$(git -C "$w/main" rev-parse HEAD)" "$carry" "the primary was moved off its commit"
  assert_not_equals "$(git -C "$w/main" rev-parse HEAD)" "$other" "the primary was forced to the rewritten branch"
  pass "T15 a non-fast-forward self-update source is skipped, never forced"
}

test_updates_main_by_single_parent_fast_forward
test_reread_gate_is_instruction_only
test_bin_only_advance_rereads
test_dirty_firstmate_skipped
test_diverged_firstmate_skipped
test_missing_write_tree_refuses
test_code_root_redundant_divergence
test_code_root_unique_change_refused
test_already_current_firstmate_is_idempotent
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_primary_update_rebinds_local_watch
test_self_update_source_follows_branch
test_self_update_source_refuses_unusable_config
test_self_update_source_rewrite_is_skipped
