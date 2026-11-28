#!/usr/bin/env bash
# tests/fm-spawn-heavy-queue.test.sh - each case drives the real spawn against a
# fake pane, then runs the launch it sent with a probe harness that prints where bun resolves.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-heavy-queue)

# make_case <name> <id>
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  ORC_LOG="$CASE_DIR/orc.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" pi
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/bin/sh
command -v bun || echo no-bun
SH
  chmod +x "$FAKEBIN_DIR/pi"
}

# The folder carries a space and a quote so the launch must quote it.
install_heavy_orc() {
  STANDIN_DIR="$CASE_DIR/heavy dir's bin"
  mkdir -p "$STANDIN_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$STANDIN_DIR/bun"
  chmod +x "$STANDIN_DIR/bun"
  cat > "$FAKEBIN_DIR/orc" <<SH
#!/bin/sh
printf '%s\\n' "\$*" >> $(printf '%q' "$ORC_LOG")
[ "\$*" = "heavy path" ] || exit 2
printf '%s\\n' $(printf '%q' "$STANDIN_DIR")
SH
  chmod +x "$FAKEBIN_DIR/orc"
}

# Real pueue looks for its socket under XDG_RUNTIME_DIR and fails like this
# when a non-interactive caller does not have it.
install_pueue_failing_orc() { # <fakebin>
  cat > "$1/orc" <<'SH'
#!/bin/sh
printf '\033[91mI/O error at path "/fixture/pueue.socket" while connecting to daemon. Did you start it?\033[0m\n' >&2
exit 1
SH
  chmod +x "$1/orc"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The probe PATH holds no bun, so only the launch can make one resolve.
emitted_bun() {
  local preamble
  preamble=$(grep '^ export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:/usr/bin:/bin" TERM=xterm HERDR_ENV=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_ship_and_scout_resolve_bun_to_the_standin_not_the_ambient_path() {
  local kind setting id out status
  for kind in ship scout; do
    for setting in absent enabled; do
      id="$kind-$setting-a1"
      make_case "$kind-$setting" "$id"
      install_heavy_orc
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist $setting should succeed: $out"
      assert_equals "heavy path" "$(cat "$ORC_LOG")" "$kind/$setting: spawn should ask orc for the heavy path once"
      assert_not_contains "$out" "without the heavy queue" "$kind/$setting: a working orc must not print the fallback note"
      assert_equals "$STANDIN_DIR/bun" "$(emitted_bun)" \
        "$kind/$setting: the worker's bun must resolve to the stand-in"
    done
  done
  pass "ship and scout workers resolve bun to the heavy-queue stand-in under both allowlist postures"
}

test_failing_orc_launches_unchanged_with_one_note_instead_of_refusing() {
  local id=fail-a1 out status
  make_case orc-fails "$id"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a failing orc must not block the spawn: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c "launches without the heavy queue on its PATH")" \
    "a failing orc should be reported exactly once: $out"
  assert_equals no-bun "$(emitted_bun)" "a failing orc must leave the worker PATH unchanged"
  pass "a spawn whose orc fails launches unchanged and says so once"
}

test_folder_that_does_not_exist_is_not_put_on_the_path() {
  local id=missing-a1 out status
  make_case orc-missing-dir "$id"
  cat > "$FAKEBIN_DIR/orc" <<SH
#!/bin/sh
printf '%s\\n' $(printf '%q' "$CASE_DIR/never-made")
SH
  chmod +x "$FAKEBIN_DIR/orc"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unusable folder must not block the spawn: $out"
  assert_contains "$out" "printed no folder" "an unusable folder should be named in the note: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "never-made" "an unusable folder must stay off the launch"
  pass "a folder orc printed but that does not exist stays off the worker PATH"
}

test_remote_spawn_resolves_bun_to_the_standin_not_the_ambient_path() {
  local id=remote-ok-a1 out status
  make_case remote-ok "$id"
  install_heavy_orc
  out=$(FM_REMOTE_JOB_ACTIVE=1 run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a remote spawn with a working orc should succeed: $out"
  assert_equals "$STANDIN_DIR/bun" "$(emitted_bun)" "a remote worker's bun must resolve to the stand-in"
  pass "a remote spawn puts the heavy-queue stand-ins first on the worker PATH"
}

test_remote_spawn_whose_orc_fails_stops_with_orcs_error_instead_of_launching_without_standins() {
  local id=remote-fail-a1 out status
  make_case remote-orc-fails "$id"
  install_pueue_failing_orc "$FAKEBIN_DIR"
  out=$(FM_REMOTE_JOB_ACTIVE=1 run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_not_equals 0 "$status" "a remote spawn whose orc fails must not succeed: $out"
  assert_contains "$out" "was not launched because the heavy-queue stand-ins could not be put first on its PATH" \
    "a remote spawn whose orc fails should say why it stopped: $out"
  assert_contains "$out" "while connecting to daemon. Did you start it?" "the refusal should carry orc's own error: $out"
  assert_not_contains "$out" "without the heavy queue" "a remote spawn must not fall back to an unchanged PATH: $out"
  assert_equals "" "$(cat "$LAUNCH_LOG")" "a remote spawn whose orc fails must send no launch"
  pass "a remote spawn whose orc fails stops with orc's error instead of launching without the stand-ins"
}

# make_relaunch_case <name> <id>; the task record names a live fake pane with no agent.
make_relaunch_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR="$CASE_DIR/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$CASE_DIR/fake" "$CASE_DIR/user-home"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  fm_test_make_relaunch_fakebin "$CASE_DIR"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE_DIR/fake/keys"
  printf '%s' "$WT_DIR" > "$CASE_DIR/fake/cwd"
  fm_write_herdr_meta "$HOME_DIR/state/$id.meta" "fmlab:w1:p7" \
    "worktree=$WT_DIR" "project=$PROJ_DIR" "harness=pi" \
    kind=ship mode=no-mistakes yolo=off "tasktmp=$CASE_DIR/tasktmp" \
    model=default effort=default
}

run_remote_relaunch() { # <id>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_REMOTE_JOB_ACTIVE=1 PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$CASE_DIR/fake" \
    HOME="$CASE_DIR/user-home" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$1" --relaunch --harness pi 2>&1
}

test_remote_relaunch_resolves_bun_to_the_standin_not_the_ambient_path() {
  local id=remote-relaunch-ok-a1 out status preamble seen
  make_relaunch_case remote-relaunch-ok "$id"
  ORC_LOG="$CASE_DIR/orc.log"
  install_heavy_orc
  out=$(run_remote_relaunch "$id")
  status=$?
  expect_code 0 "$status" "a remote relaunch with a working orc should succeed: $out"
  [ -s "$CASE_DIR/fake/launch" ] || fail "a remote relaunch sent no replacement launch: $out"
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/bin/sh
command -v bun || echo no-bun
SH
  chmod +x "$FAKEBIN_DIR/pi"
  preamble=$(grep '^export ' "$CASE_DIR/fake/keys")
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:/usr/bin:/bin" TERM=xterm \
    /bin/sh -c "$preamble
$(cat "$CASE_DIR/fake/launch")")
  assert_equals "$STANDIN_DIR/bun" "$seen" "a remotely relaunched worker's bun must resolve to the stand-in"
  pass "a remote relaunch puts the heavy-queue stand-ins first on the worker PATH"
}

test_remote_relaunch_whose_orc_fails_stops_with_orcs_error_instead_of_relaunching_without_standins() {
  local id=remote-relaunch-fail-a1 out status
  make_relaunch_case remote-relaunch-fails "$id"
  install_pueue_failing_orc "$FAKEBIN_DIR"
  out=$(run_remote_relaunch "$id")
  status=$?
  assert_not_equals 0 "$status" "a remote relaunch whose orc fails must not succeed: $out"
  assert_contains "$out" "was not launched because the heavy-queue stand-ins could not be put first on its PATH" \
    "a remote relaunch whose orc fails should say why it stopped: $out"
  assert_contains "$out" "while connecting to daemon. Did you start it?" "the refusal should carry orc's own error: $out"
  assert_absent "$CASE_DIR/fake/launch" "a remote relaunch whose orc fails must send no replacement launch"
  pass "a remote relaunch whose orc fails stops with orc's error instead of relaunching without the stand-ins"
}

test_local_override_and_unrouted_projects_start_locally() {
  local placement id out status
  for placement in override unrouted; do
    id="local-$placement"
    make_case "$placement" "$id"
    if [ "$placement" = override ]; then
      printf '%s\n' '- project [direct-PR host=unavailable] - project' > "$HOME_DIR/data/projects.md"
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout --local)
    else
      printf '%s\n' '- project [direct-PR] - project' > "$HOME_DIR/data/projects.md"
      out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
    fi
    status=$?
    expect_code 0 "$status" "$placement must start locally: $out"
    [ -s "$LAUNCH_LOG" ] || fail "$placement did not launch a local worker: $out"
    assert_no_grep 'remote_host=' "$HOME_DIR/state/$id.meta" "$placement must not create a remote worker record"
  done
  pass "explicit local override and unrouted projects launch locally"
}

test_local_override_and_unrouted_projects_start_locally
test_ship_and_scout_resolve_bun_to_the_standin_not_the_ambient_path
test_failing_orc_launches_unchanged_with_one_note_instead_of_refusing
test_folder_that_does_not_exist_is_not_put_on_the_path
test_remote_spawn_resolves_bun_to_the_standin_not_the_ambient_path
test_remote_spawn_whose_orc_fails_stops_with_orcs_error_instead_of_launching_without_standins
test_remote_relaunch_resolves_bun_to_the_standin_not_the_ambient_path
test_remote_relaunch_whose_orc_fails_stops_with_orcs_error_instead_of_relaunching_without_standins
