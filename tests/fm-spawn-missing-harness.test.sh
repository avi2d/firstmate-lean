#!/usr/bin/env bash
# A spawn whose harness executable is absent from PATH refuses before endpoint creation.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-missing-harness)
fm_git_identity fmtest fmtest@example.invalid

make_missing_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" timeout treehouse)
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_missing_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_missing_harness_refuses_before_endpoint() {  # <harness>
  local harness=$1 rec id out status
  id="missing-$harness-z1"
  rec=$(make_missing_case "missing-$harness" "$id")
  read_missing_record "$rec"
  rm -f "$FAKEBIN_DIR/$harness"
  : > "$LAUNCH_LOG"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH='/usr/bin:/bin:/usr/sbin:/sbin' \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --harness "$harness" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a missing $harness executable should refuse the spawn"
  assert_contains "$out" "$harness executable not found on PATH" \
    "missing $harness refusal did not name the actionable requirement"
  assert_not_contains "$out" "spawned $id" \
    "a refused spawn must never report success"
  assert_absent "$HOME_DIR/state/$id.meta" "missing $harness refusal wrote task metadata"
  assert_absent "$FAKEBIN_DIR/tab-index" "missing $harness refusal created an endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing $harness refusal typed a launch command"
  pass "a missing $harness executable refuses before endpoint creation"
}

test_missing_harness_refuses_before_endpoint pi
test_missing_harness_refuses_before_endpoint pi-signed

echo "all fm-spawn-missing-harness tests passed"
