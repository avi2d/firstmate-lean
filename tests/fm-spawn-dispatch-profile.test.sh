#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
unset LAVISH_AXI_HOST

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  # Mirror real Pi help advertising: 0.82.0 has --approve but not --tui-mode;
  # 0.50.0 is a synthetic pre-approve probe; current defaults advertise both.
  case "${FM_FAKE_PI_VERSION:-0.84.0}" in
  0.50.0) printf '%s\n' 'Pi 0.50.0' 'Options: --help' ;;
  0.82.0) printf '%s\n' 'Pi 0.82.0' 'Options: --help --approve' ;;
  *) printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode> --approve' ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = -k ]; do shift 2; done
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

# make_batch_copies <project> <case-dir> <id>...: one copy per task, read back
# through FM_FAKE_PANE_PATH_ROOT, since a live record reserves its copy.
make_batch_copies() {
  local proj=$1 root=$2/copies id
  shift 2
  for id in "$@"; do
    git -C "$proj" worktree add --quiet -b "wt-$id" "$root/fm-$id" || fail "could not create a copy for $id"
  done
  printf '%s\n' "$root"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"pi-signed","model":"openai-codex/gpt-5.6-sol","effort":"high"}}],"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

# Writes the task record bin/fm-dispatch-resolve.sh leaves in data/<id>/ (its
# documented shape: task, status, and profile with null for an unset axis).
record_dispatch() {  # <home> <id> <status> [<harness> <model> <effort>]
  local home=$1 id=$2 status=$3
  mkdir -p "$home/data/$id"
  jq -cn --arg id "$id" --arg status "$status" --arg h "${4:-}" --arg m "${5:-}" --arg e "${6:-}" '
    def opt: if . == "" then null else . end;
    {task: $id, status: $status,
     profile: (if $status == "clear" then {harness: $h, model: ($m | opt), effort: ($e | opt)} else null end)}' \
    > "$home/data/$id/dispatch-resolution.json"
}

task_inbox_export() {  # <home> <id>
  local state
  state=$(CDPATH='' cd -- "$1/state" && pwd -P) || fail "cannot resolve state dir $1/state"
  printf "export FM_TASK_INBOX='%s'; " "$state/$2.inbox"
}


write_test_dispatch_proof() {
  local home=$1 ref=$2 candidates=$3 chosen=$4 override=$5 id
  shift 5
  for id in "$@"; do
    [ -d "$home/data/$id" ] || continue
    {
      printf '%s\n' 'dispatch-selection:' "rule: $ref"
      printf '%s\n' "$candidates"
      printf '%s\n' "$chosen"
      [ -z "$override" ] || printf '%s\n' "override: $override"
    } > "$home/data/$id/dispatch-selection.md"
  done
}

auto_test_dispatch_proof() {
  local home=$1 arg id ids=() positional=() words=()
  local harness='' model='' effort='' account='' want_value='' raw='' word=''
  shift
  for arg in "$@"; do
    if [ -n "$want_value" ]; then
      case "$want_value" in
      harness) harness=$arg ;;
      model) model=$arg ;;
      effort) effort=$arg ;;
      claude-account) account=$arg ;;
      esac
      want_value=
      continue
    fi
    case "$arg" in
    --harness=*|--model=*|--effort=*|--claude-account=*)
      case "$arg" in
      --harness=*) harness=${arg#--harness=} ;;
      --model=*) model=${arg#--model=} ;;
      --effort=*) effort=${arg#--effort=} ;;
      --claude-account=*) account=${arg#--claude-account=} ;;
      esac
      ;;
    --harness|--model|--effort|--claude-account) want_value=${arg#--} ;;
    --backend|--mode|--yolo|--weight|--branch-prefix|--base-branch|--upstream-consent|--traceparent|--quota-override-reason) want_value=skip ;;
    --*) ;;
    *=*)
      case "$arg" in
      *\ *) ;;
      *) ids+=("${arg%%=*}") ;;
      esac
      ;;
    *) positional+=("$arg") ;;
    esac
  done
  if [ "${#ids[@]}" -eq 0 ] && [ "${#positional[@]}" -ge 1 ]; then
    ids+=("${positional[0]}")
  fi
  if [ -z "$harness" ] && [ "${#positional[@]}" -ge 3 ]; then
    harness=${positional[2]}
  fi
  case "$harness" in
  *\ *)
    raw=$harness harness=
    read -ra words <<< "$raw"
    for word in "${words[@]}"; do
      case "$word" in
      [A-Za-z_]*=*) continue ;;
      *) harness=$(basename "$word"); break ;;
      esac
    done
    ;;
  esac
  [ -n "$harness" ] || return 0
  [ "${#ids[@]}" -gt 0 ] || return 0
  [ -f "$home/config/crew-dispatch.json" ] || return 0
  [ -n "${FM_TEST_NO_DISPATCH_RECORD:-}" ] || for id in "${ids[@]}"; do
    [ -d "$home/data/$id" ] && [ ! -e "$home/data/$id/dispatch-resolution.json" ] || continue
    record_dispatch "$home" "$id" ambiguous
  done
  local ref entries chosen candidates override entry eh
  ref=$(jq -r --arg h "$harness" --arg hm "$harness:$model" '
    def norm: if type == "array" then . elif type == "object" then [.] else [] end;
    def lines: norm | map("\(.harness):\(.model // "")");
    ([((.rules // []) | to_entries[]) | {ref: ("rule_" + ((.key + 1) | tostring)), e: (.value.use | lines)}]
      + [{ref: "default", e: (.default | lines)}])
    | map(select((.e | length) > 0)) as $r
    | (($r | map(select(.e | index($hm))) | first | .ref)
      // ($r | map(select(.e | map(split(":")[0]) | index($h))) | first | .ref)
      // ($r | first | .ref)
      // empty)' "$home/config/crew-dispatch.json") || return 0
  [ -n "$ref" ] || return 0
  if [ "$ref" = "default" ]; then
    entries=$(jq -r '.default | (if type == "array" then . elif type == "object" then [.] else [] end) | .[] | "\(.harness):\(.model // "")"' "$home/config/crew-dispatch.json") || return 0
  else
    entries=$(jq -r --argjson n "${ref#rule_}" '((.rules // [])[$n - 1].use // null) | (if type == "array" then . elif type == "object" then [.] else [] end) | .[] | "\(.harness):\(.model // "")"' "$home/config/crew-dispatch.json") || return 0
  fi
  [ -n "$entries" ] || return 0
  chosen="chosen: --harness $harness"
  [ -z "$model" ] || chosen="$chosen --model $model"
  [ -z "$effort" ] || chosen="$chosen --effort $effort"
  [ -z "$account" ] || chosen="$chosen --claude-account $account"
  candidates=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    eh=${entry%%:*}
    entry_line="candidate: $entry provider=$eh remaining=50% spendPriority=10 runway=through_reset -> eligible: test proof"
    candidates=${candidates:+$candidates$'\n'}$entry_line
  done <<< "$entries"
  override=""
  printf '%s\n' "$entries" | grep -qxF "$harness:$model" || override="test launch uses a profile outside the dispatch rules"
  write_test_dispatch_proof "$home" "$ref" "$candidates" "$chosen" "$override" "${ids[@]}"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  auto_test_dispatch_proof "$home" "$@"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="${FM_TEST_PANE_LOG:-}" \
    FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

make_quota_axi_fixture() {
  cat > "$FAKEBIN_DIR/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'quota-axi 0.1.51' ;;
  --json)
    provider_reset=${FM_FAKE_QUOTA_RESET_JSON:-null}
    weekly_reset=${FM_FAKE_QUOTA_WEEKLY_RESET_JSON:-'"2030-01-02T03:04:05Z"'}
    monthly_reset=${FM_FAKE_QUOTA_MONTHLY_RESET_JSON:-'"2030-01-03T03:04:05Z"'}
    limiting_ids=${FM_FAKE_QUOTA_LIMITING_IDS_JSON:-'["weekly"]'}
    limiting_id=${FM_FAKE_QUOTA_LIMITING_ID_JSON:-'"weekly"'}
    printf '{"schemaVersion":5,"providers":[{"provider":"codex","resetsAt":%s,"windows":[{"id":"weekly","percentRemaining":%s,"resetsAt":%s},{"id":"monthly","percentRemaining":8,"resetsAt":%s}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s","limitingWindowId":%s},"limitingWindowIds":%s}]}}]}\n' "$provider_reset" "${FM_FAKE_QUOTA_REMAINING:-10}" "$weekly_reset" "$monthly_reset" "${FM_FAKE_QUOTA_REMAINING:-10}" "${FM_FAKE_QUOTA_RUNWAY:-through_reset}" "$limiting_id" "$limiting_ids" ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/quota-axi"
}

test_quota_gate_refuses_profile_below_floor_with_reset() {
  local rec id out status
  id=quota-floor-z1
  rec=$(make_spawn_case quota-floor pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","floor":{"scope":"all_models","min_percent":20}}}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn below its matched profile floor should refuse: $out"
  assert_contains "$out" 'below 20%' "quota refusal should name the configured floor"
  assert_contains "$out" '2030-01-02T03:04:05Z' "quota refusal should name the reset time"
  pass "quota gate refuses a matched profile below its floor and names the reset"
}

spawn_floor_reset_case() {
  local name=$1 remaining=$2 offset=$3 reset_json
  if [ -n "$offset" ]; then
    FLOOR_RESET_ISO=$(jq -nr --argjson offset "$offset" 'now + $offset | floor | todateiso8601')
    reset_json="\"$FLOOR_RESET_ISO\""
  else
    FLOOR_RESET_ISO=''
    reset_json=null
  fi
  FLOOR_RESET_ID="quota-$name-z11"
  read_case_record "$(make_spawn_case "quota-$name" pi "$FLOOR_RESET_ID")"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","floor":{"scope":"all_models","min_percent":20}}}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture
  FLOOR_RESET_OUT=$(FM_FAKE_QUOTA_REMAINING=$remaining FM_FAKE_QUOTA_WEEKLY_RESET_JSON=$reset_json run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$FLOOR_RESET_ID" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  FLOOR_RESET_STATUS=$?
}

test_quota_gate_skips_floor_instead_of_refusing_when_window_resets_within_a_day() {
  spawn_floor_reset_case floor-near-reset 10 7200
  expect_code 0 "$FLOOR_RESET_STATUS" "a floor whose window resets within a day should not refuse without an override: $FLOOR_RESET_OUT"
  assert_contains "$FLOOR_RESET_OUT" "profile floor all_models below 20% skipped: window weekly resets at $FLOOR_RESET_ISO" "the skipped floor names its window and reset"
  assert_grep "quota_gate=checked:profile floor all_models below 20% skipped: window weekly resets at $FLOOR_RESET_ISO" "$HOME_DIR/state/$FLOOR_RESET_ID.meta" "the skip is recorded on the task"
  pass "quota gate skips a profile floor whose window resets within a day"
}

test_quota_gate_keeps_refusing_instead_of_skipping_far_exhausted_or_unknown_resets() {
  spawn_floor_reset_case floor-far-reset 10 259200
  [ "$FLOOR_RESET_STATUS" -ne 0 ] || fail "a floor whose window resets in three days should still refuse: $FLOOR_RESET_OUT"
  assert_contains "$FLOOR_RESET_OUT" 'below 20%' "the far reset refusal names the floor"
  assert_not_contains "$FLOOR_RESET_OUT" 'skipped' "a far reset never skips the floor"

  spawn_floor_reset_case floor-exhausted-near-reset 0 7200
  [ "$FLOOR_RESET_STATUS" -ne 0 ] || fail "a window at 0% should refuse even when it resets soon: $FLOOR_RESET_OUT"
  assert_contains "$FLOOR_RESET_OUT" 'quota exhausted now' "the 0% refusal names exhaustion"

  spawn_floor_reset_case floor-unknown-reset 10 ''
  [ "$FLOOR_RESET_STATUS" -ne 0 ] || fail "a floor whose reset is unknown should still refuse: $FLOOR_RESET_OUT"
  assert_contains "$FLOOR_RESET_OUT" 'below 20%' "the unknown reset refusal names the floor"
  assert_not_contains "$FLOOR_RESET_OUT" 'skipped' "an unknown reset never skips the floor"
  pass "quota gate keeps refusing a floor whose reset is far, exhausted, or unknown"
}

test_quota_gate_uses_strictest_matching_floor() {
  local rec id out status
  id=quota-strict-floor-z2
  rec=$(make_spawn_case quota-strict-floor pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"rules":[{"when":"first","use":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","floor":{"scope":"all_models","min_percent":20}}},{"when":"second","use":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","floor":{"scope":"all_models","min_percent":30}}}]}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture
  out=$(FM_FAKE_QUOTA_REMAINING=25 run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn below the strictest matching floor should refuse"
  assert_contains "$out" 'below 30%' "quota refusal should use the strictest matching floor"
  pass "quota gate applies the strictest floor across matching profiles"
}

test_quota_gate_refuses_exhausted_now() {
  local rec id out status
  id=quota-exhausted-z3
  rec=$(make_spawn_case quota-exhausted pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol"}}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture
  out=$(FM_FAKE_QUOTA_RUNWAY=exhausted_now run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with exhausted_now quota should refuse"
  assert_contains "$out" 'quota exhausted now' "quota refusal should name exhaustion"
  assert_contains "$out" '2030-01-02T03:04:05Z' "exhaustion refusal should name the reset time"

  id=quota-exhausted-multiple-z8
  rec=$(make_spawn_case quota-exhausted-multiple pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol"}}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture
  out=$(FM_FAKE_QUOTA_RUNWAY=exhausted_now FM_FAKE_QUOTA_LIMITING_ID_JSON=null FM_FAKE_QUOTA_LIMITING_IDS_JSON='["weekly","monthly"]' run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with multiple exhausted windows should refuse"
  assert_contains "$out" '2030-01-03T03:04:05Z' "quota refusal should name the latest reset among all limiting windows"
  pass "quota gate refuses exhausted windows at their own reset, choosing the latest when several limit"
}

test_quota_gate_records_override_and_unmatched_skip() {
  local rec id out status
  id=quota-override-z4
  rec=$(make_spawn_case quota-override pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","floor":{"scope":"all_models","min_percent":20}}}' > "$HOME_DIR/config/crew-dispatch.json"
  make_quota_axi_fixture
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --quota-override-reason 'usage feed misses purchased credits')
  status=$?
  expect_code 0 "$status" "explicit quota override should proceed: $out"
  assert_grep 'quota_gate=overridden:usage feed misses purchased credits' "$HOME_DIR/state/$id.meta" "override reason must be recorded in task metadata"

  id=quota-unmatched-z5
  rec=$(make_spawn_case quota-unmatched pi "$id")
  read_case_record "$rec"
  printf '%s\n' '{"default":{"harness":"pi","model":"openai-codex/gpt-5.4"}}' > "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  expect_code 0 "$status" "unmatched profile should skip the quota gate: $out"
  assert_contains "$out" 'warning: this launch was not quota-checked: no profile in config/crew-dispatch.json matches harness=pi model=openai-codex/gpt-5.6-sol effort=default; report it to the captain' "unmatched launch should warn that it ran unchecked"
  assert_grep 'quota_gate=skipped:no matching dispatch profile' "$HOME_DIR/state/$id.meta" "skip reason must be recorded in task metadata"

  id=quota-config-absent-z7
  rec=$(make_spawn_case quota-config-absent pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol)
  status=$?
  expect_code 0 "$status" "a missing dispatch config should skip the quota gate: $out"
  assert_contains "$out" 'quota gate skipped: config/crew-dispatch.json is absent' "missing config should explain the skip"
  assert_grep 'quota_gate=skipped:no dispatch profile file' "$HOME_DIR/state/$id.meta" "missing config skip must be recorded in task metadata"
  pass "quota override is recorded, and unmatched or unconfigured launches explain and record their skips"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=herdr HERDR_SESSION=spawn-fixture \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/launch-brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=herdr HERDR_SESSION=spawn-fixture \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/launch-brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"
  rm -f "$HOME_DIR/state/$relative_id.meta"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=herdr HERDR_SESSION=spawn-fixture \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/launch-brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=herdr HERDR_SESSION=spawn-fixture \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/launch-brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  jq '.preferred_provider = "codex"' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/preferred.json"
  mv "$HOME_DIR/config/preferred.json" "$HOME_DIR/config/crew-dispatch.json"
  record_dispatch "$HOME_DIR" "$id" ambiguous

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report explicit pi harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/pi' --approve --model 'openai-codex/gpt-5.6-sol' --thinking 'high'" \
    "explicit Pi launch lost its model or thinking level"
  pass "a non-clear dispatch record accepts the explicit flags of the manual intake"
}

test_recorded_dispatch_selection_refuses_conflicting_flags() {
  local rec id out status
  id=profile-selected-conflict-z13
  rec=$(make_spawn_case profile-selected-conflict pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi opus high

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 1 "$status" "flags that differ from the recorded selection should be refused"
  assert_contains "$out" 'launch flags do not match the clear dispatch selection --harness pi --model opus --effort high' "spawn did not name the recorded selection"
  assert_absent "$HOME_DIR/state/$id.meta" "selection mismatch should refuse before task publication"
  assert_equals '' "$(cat "$LAUNCH_LOG")" "selection mismatch must not create a worker"
  pass "a recorded dispatch selection refuses conflicting explicit launch flags"
}

test_recorded_dispatch_selection_allows_matching_flags() {
  local rec id out status
  id=profile-selected-match-z13
  rec=$(make_spawn_case profile-selected-match pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi openai-codex/gpt-5.6-sol high

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "flags equal to the recorded selection should launch: $out"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol high
  assert_no_grep 'dispatch_override=' "$HOME_DIR/state/$id.meta" "a matching launch should record no override"
  pass "a recorded dispatch selection allows the matching launch flags"
}

test_recorded_dispatch_selection_allows_recorded_override() {
  local rec id out status
  id=profile-selected-override-z13
  rec=$(make_spawn_case profile-selected-override pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi opus high

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high \
    --dispatch-override 'authorized account test')
  status=$?
  expect_code 0 "$status" "a recorded task override should permit a different launch: $out"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report the overridden Pi launch"
  assert_grep 'dispatch_override=authorized account test' "$HOME_DIR/state/$id.meta" "task record omitted the override reason"
  pass "a task override with its reason permits a different launch and is recorded"
}

test_recorded_dispatch_selection_leaves_unset_effort_unbound() {
  local rec id out status
  id=profile-selected-fallback-z13
  rec=$(make_spawn_case profile-selected-fallback pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi openai-codex/gpt-5.6-sol ''

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort low)
  status=$?
  expect_code 0 "$status" "a fallback effort beside a selection with no effort should launch: $out"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol low
  assert_no_grep 'dispatch_override=' "$HOME_DIR/state/$id.meta" "the documented effort fallback should need no override"
  pass "an effort the clear selection leaves unset is not bound"
}

# A raw command keeps its own options, so matching --harness/--model/--effort
# beside it proves nothing about what the worker runs.
test_recorded_dispatch_selection_refuses_raw_launch_without_override() {
  local rec id out status
  id=profile-selected-raw-z13
  rec=$(make_spawn_case profile-selected-raw pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi haiku low

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "pi --model opus --effort high" --model haiku --effort low)
  status=$?
  expect_code 1 "$status" "a raw command under a clear selection should be refused without an override"
  assert_contains "$out" 'launch flags do not match the clear dispatch selection --harness pi --model haiku --effort low' "spawn did not name the recorded selection"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused raw launch should not publish the task"
  assert_equals '' "$(cat "$LAUNCH_LOG")" "a refused raw launch must not create a worker"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "pi --model opus --effort high" --dispatch-override 'captain asked for opus')
  status=$?
  expect_code 0 "$status" "a raw command with a recorded task override should launch: $out"
  assert_grep 'dispatch_override=captain asked for opus' "$HOME_DIR/state/$id.meta" "task record omitted the override reason"
  pass "a clear dispatch selection refuses a raw launch command unless a task override is recorded"
}

test_active_dispatch_without_task_record_is_refused() {
  local rec id out status
  id=profile-unrecorded-z13
  rec=$(make_spawn_case profile-unrecorded pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(FM_TEST_NO_DISPATCH_RECORD=1 run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 1 "$status" "an active dispatch spawn with no task record should be refused"
  assert_contains "$out" "has no recorded dispatch resolution; run bin/fm-dispatch-resolve.sh" "refusal did not name the resolver command"
  assert_absent "$HOME_DIR/state/$id.meta" "an unrecorded dispatch should refuse before task publication"
  assert_equals '' "$(cat "$LAUNCH_LOG")" "an unrecorded dispatch must not create a worker"
  pass "active dispatch refuses a spawn whose task has no recorded resolution"
}

test_batch_checks_each_task_against_its_own_record() {
  local rec id1 id2 out status
  id1=profile-batch-own-a-z13
  id2=profile-batch-own-b-z13
  rec=$(make_spawn_case profile-batch-own pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id1" clear pi openai-codex/gpt-5.6-sol high
  record_dispatch "$HOME_DIR" "$id2" clear pi opus high

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 1 "$status" "a batch with one conflicting task record should report failure"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi openai-codex/gpt-5.6-sol high
  assert_absent "$HOME_DIR/state/$id2.meta" "the task with a conflicting recorded model must not launch"
  assert_contains "$out" "batch: FAILED to spawn $id2" "batch did not name the refused task"
  pass "batch dispatch checks each task against its own recorded selection"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" clear pi openai-codex/gpt-5.6-sol high

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report positional pi harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

# Replacing inherited config rather than appending the hooks entry loses the
# scoped HTTPS credential helper. Execute the real emitted launch and ask Git,
# rather than inspecting command text, to catch that credential widening. Every
# pane shell runs with its startup files pointed at the case directory, so a
# developer's rc file cannot prompt, exec a multiplexer or export GIT_CONFIG_*.
isolated_pane_env() {  # <assignment-or-command...>
  env HOME="$CASE_DIR" ZDOTDIR="$CASE_DIR" XDG_CONFIG_HOME="$CASE_DIR" ENV= BASH_ENV= "$@"
}

test_launch_preserves_inherited_git_config() {
  local rec id=git-config-append out status launch result pane_shell count launch_file expected prefix interactive_probe
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness 'echo WORKER-RAN >&2; git config --get-all credential.helper; git config --get core.hooksPath')
  status=$?
  expect_code 0 "$status" "Git configuration probe should spawn: $out"
  launch=$(cat "$LAUNCH_LOG")
  launch_file="$CASE_DIR/git-config-launch.sh"
  printf '%s\n' "$launch" > "$launch_file"
  expected=$'\n!gh auth git-credential\n'"$(cd "$HOME_DIR/state" && pwd -P)/$id.git-hooks"
  interactive_probe=$(cat <<'SH'
. "$1"
fm_status=$?
[ "$fm_status" -ne 0 ] || exit 2
printf '\nSHELL-STILL-ALIVE\n'
SH
)
  for pane_shell in /bin/sh /bin/bash /bin/zsh; do
    [ -x "$pane_shell" ] || continue
    for count in 2 02; do
      result=$(isolated_pane_env GIT_CONFIG_COUNT="$count" \
        GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
        "$pane_shell" -c "$launch") || fail "Git configuration launch failed in $pane_shell"
      [ "$result" = "$expected" ] \
        || fail "launch dropped the inherited credential-helper entries in $pane_shell"
    done
    result=$(isolated_pane_env GIT_CONFIG_COUNT=bad "$pane_shell" -c "$launch" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "an invalid Git config count silently launched"
    assert_not_contains "$result" WORKER-RAN "an invalid Git config count still started the worker in $pane_shell"
    for count in bad 2147483647; do
      result=$(isolated_pane_env GIT_CONFIG_COUNT="$count" "$pane_shell" -i -c \
        "$interactive_probe" _ "$launch_file" 2>&1)
      status=$?
      expect_code 0 "$status" "invalid count must preserve the interactive $pane_shell pane"
      assert_contains "$result" 'error: ' "count refusal must remain visible in $pane_shell"
      assert_contains "$result" SHELL-STILL-ALIVE "count refusal killed the interactive $pane_shell pane"
      assert_not_contains "$result" WORKER-RAN "count refusal still started the worker in $pane_shell"
    done
  done
  # A fish pane sources the same launch file, so fish runs the same append and
  # refusal cases. Without fish, check the emitted launch prefix (the staged
  # launch-file contract) for POSIX-only syntax fish cannot parse.
  if command -v fish >/dev/null 2>&1; then
    for count in 2 02; do
      result=$(isolated_pane_env GIT_CONFIG_COUNT="$count" \
        GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
        fish -c "source '$launch_file'") || fail "Git configuration launch failed in fish"
      [ "$result" = "$expected" ] || fail "launch dropped the inherited credential-helper entries in fish"
    done
    result=$(isolated_pane_env GIT_CONFIG_COUNT=bad fish -c "source '$launch_file'" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "an invalid Git config count silently launched in fish"
    assert_not_contains "$result" WORKER-RAN "an invalid Git config count still started the worker in fish"
    for count in bad 2147483647; do
      result=$(isolated_pane_env GIT_CONFIG_COUNT="$count" fish -i -c \
        "source '$launch_file'; and exit 2; printf '\nSHELL-STILL-ALIVE\n'" 2>&1)
      status=$?
      expect_code 0 "$status" "invalid count must preserve the interactive fish pane"
      assert_contains "$result" 'error: ' "count refusal must remain visible in fish"
      assert_contains "$result" SHELL-STILL-ALIVE "count refusal killed the interactive fish pane"
      assert_not_contains "$result" WORKER-RAN "count refusal still started the worker in fish"
    done
  else
    prefix=$(fm_test_launch_git_prefix "$launch")
    # shellcheck disable=SC2016 # These are literal shell tokens fish rejects.
    case "$prefix" in
      *'$('* | *'${'* | *'`'* | *'case '* | *'while '* | *'esac'* | *'done'*)
        fail "the Git configuration launch prefix uses syntax fish cannot parse: $prefix" ;;
    esac
    # A token check cannot prove fish sources the launch, so report fish as
    # skipped rather than letting the pass line claim it ran.
    echo "skip: fish not found (fish pane launch); only a static syntax check ran"
    pass "launch appends the hooks config while preserving inherited Git credentials in sh, bash and zsh"
    return
  fi
  pass "launch appends the hooks config while preserving inherited Git credentials in every pane shell, fish included"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id" off

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  # The unverified-adapter escape hatch is still an agent this fleet launched,
  # so it carries the compact-adviser floor and the AI-trailer strip; nothing
  # else may rewrite the captain's own command.
  [ "$launch" = "export COMPACT_ADVISER_DISABLE=1; $(task_inbox_export "$HOME_DIR" "$id")$(fm_test_launch_git_prefix "$launch")custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_chained_raw_launch_strips_ai_trailer_in_every_step() {
  local rec id out status launch body
  id=chained-raw-z15
  rec=$(make_spawn_case chained-raw pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "cd . && git commit -q --allow-empty --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: chained raw launch'")
  status=$?
  expect_code 0 "$status" "chained raw launch should spawn: $out"
  launch=$(cat "$LAUNCH_LOG")
  (
    cd "$WT_DIR" || exit 1
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    fm_git_identity 'Captain Tests' 'captain@example.invalid'
    GIT_CONFIG_GLOBAL="$CASE_DIR/fixture-gitconfig"
    { echo '[user]'; echo 'name = Captain Tests'; echo 'email = captain@example.invalid'; } > "$GIT_CONFIG_GLOBAL"
    export GIT_CONFIG_GLOBAL
    bash -c "$launch"
  ) || fail "executing the chained raw launch failed"$'\n'"launch: $launch"
  body=$(git -C "$WT_DIR" log -1 --format=%B)
  assert_contains "$body" "fix: chained raw launch" "the chained launch did not commit"
  assert_not_contains "$body" "cursoragent@cursor.com" "the AI trailer reached a commit made after the first step of a chained raw launch"
  pass "a chained raw launch commits through the AI-trailer strip in every step"
}

test_native_effort_validator_keeps_axes_separate() {
  local harness
  for harness in pi pi-signed; do
    "$ROOT/bin/fm-harness.sh" validate-native-effort "$harness" codex-native/gpt-6-astra ultra \
      || fail "native validator refused supported harness $harness"
  done
  if "$ROOT/bin/fm-harness.sh" validate-native-effort 'pi:codex-native/forged' '' ultra 2>/dev/null; then
    fail "native validator accepted a model prefix embedded in the harness axis"
  fi
  pass "native effort validator checks harness and model as separate axes"
}

test_native_pi_ultra_is_explicit_and_model_scoped() {
  local rec id out launch harness mode native_profile model
  for harness in pi pi-signed; do
    for mode in no-mistakes direct-PR; do
      id="ultra-$harness-$mode"
      rec=$(make_spawn_case "$id" "$harness" "$id")
      read_case_record "$rec"
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
        --harness "$harness" --model codex-native/gpt-6-astra --effort ultra --mode "$mode" --yolo off)
      expect_code 0 "$?" "native Ultra spawn failed: $out"
      assert_meta_profile "$HOME_DIR/state/$id.meta" "$harness" codex-native/gpt-6-astra ultra
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "--model 'codex-native/gpt-6-astra' --codex-effort 'ultra'" "native Ultra flag missing"
      assert_not_contains "$launch" "--thinking" "native Ultra was converted into Pi thinking"
      assert_not_contains "$launch" "'max'" "native Ultra was aliased to max"
    done
  done
  for native_profile in 'pi:openai-codex/gpt-6-astra' 'pi:default' 'pi:codex-native/'; do
    harness=${native_profile%%:*}; model=${native_profile#*:}; id="ultra-refused-$RANDOM"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness "$harness" --model "$model" --effort ultra 2>&1)
    expect_code 1 "$?" "unsupported Ultra profile should refuse: $native_profile"
    assert_contains "$out" "ultra effort requires pi or pi-signed" "native-only refusal missing"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "unsupported Ultra published metadata"
    [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "unsupported Ultra provisioned lifecycle wiring"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Ultra launched an agent"
  done
  id=ultra-raw-refused
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'pi --offline' --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 1 "$?" "raw launch silently omitted the native Ultra flag"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "raw Ultra launch published metadata"
  assert_contains "$out" "canonical --harness pi or pi-signed" "raw launch refusal was not actionable"
  pass "Ultra is explicit for native Pi and Pi-signed, including direct-PR, and refuses unsupported profiles before provisioning"
}

test_batch_preserves_native_ultra() {
  local rec id1=ultra-batch-a id2=ultra-batch-b out launch copies
  rec=$(make_spawn_case ultra-batch pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id1" clear pi codex-native/gpt-6-astra ultra
  record_dispatch "$HOME_DIR" "$id2" clear pi codex-native/gpt-6-astra ultra
  copies=$(make_batch_copies "$PROJ_DIR" "$CASE_DIR" "$id1" "$id2")
  out=$(FM_FAKE_PANE_PATH_ROOT=$copies run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model codex-native/gpt-6-astra --effort ultra)
  expect_code 0 "$?" "native Ultra batch failed: $out"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi codex-native/gpt-6-astra ultra
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi codex-native/gpt-6-astra ultra
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--codex-effort 'ultra'" "batch dropped native effort"
  assert_not_contains "$launch" "--thinking 'ultra'" "batch passed an invalid Pi level"
  pass "batch dispatch preserves native Ultra in metadata and launch flags"
}

test_pi_scout_launch_enters_recorded_worktree() {
  local rec id out status
  id=profile-pi-scout-cwd-z1
  rec=$(make_spawn_case profile-pi-scout-cwd pi "$id")
  read_case_record "$rec"

  FM_TEST_PANE_LOG="$CASE_DIR/pane.log"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --harness pi)
  status=$?
  unset FM_TEST_PANE_LOG
  expect_code 0 "$status" "Pi scout spawn should succeed"
  assert_grep "cd -- '$WT_DIR'" "$CASE_DIR/pane.log" \
    "Pi scout spawn must enter the recorded worktree before launching the agent"
  pass "Pi scout spawn enters the recorded worktree before launch"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --approve --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level in Pi's default TUI"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --approve --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not keep Pi's default TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_launch_keeps_default_tui_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      assert_not_contains "$launch" "--tui-mode" \
        "$harness $version launch must keep Pi's default TUI whether or not help advertises --tui-mode"
    done
  done
  pass "Pi launches keep Pi's default TUI on older Pi and on Pi that advertises --tui-mode"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=herdr HERDR_SESSION=spawn-fixture \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_worker_launch_preapproves_project_trust() {
  local harness rec id out status launch
  for harness in pi pi-signed; do
    id="profile-${harness}-ship-approve-z8f"
    rec=$(make_spawn_case "profile-${harness}-ship-approve" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness ship spawn should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "FM_PI_HARNESS=$harness '$FAKEBIN_DIR/$harness' --approve" \
      "$harness ship spawn must pre-approve project trust when help advertises --approve"

    id="profile-${harness}-scout-approve-z8f"
    rec=$(make_spawn_case "profile-${harness}-scout-approve" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --scout --harness "$harness")
    status=$?
    expect_code 0 "$status" "$harness scout spawn should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "FM_PI_HARNESS=$harness '$FAKEBIN_DIR/$harness' --approve" \
      "$harness scout spawn must pre-approve project trust when help advertises --approve"
  done
  pass "Pi/pi-signed ship and scout launches carry session --approve when advertised"
}

test_pi_approve_probe_omits_unsupported_flag() {
  local harness rec id out status launch
  for harness in pi pi-signed; do
    id="profile-${harness}-worker-no-approve-z8g"
    rec=$(make_spawn_case "profile-${harness}-worker-no-approve" pi "$id")
    read_case_record "$rec"

    out=$(FM_TEST_PI_VERSION=0.50.0 \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness "$harness")
    status=$?
    expect_code 0 "$status" "$harness ship without --approve must still spawn"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
      "$harness without --approve must still launch the probed executable"
    assert_not_contains "$launch" "--approve" \
      "$harness ship without advertised --approve must omit the flag"

    id="profile-${harness}-scout-no-approve-z8g"
    rec=$(make_spawn_case "profile-${harness}-scout-no-approve" pi "$id")
    read_case_record "$rec"

    out=$(FM_TEST_PI_VERSION=0.50.0 \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --scout --harness "$harness")
    status=$?
    expect_code 0 "$status" "$harness scout without --approve must still spawn"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--approve" \
      "$harness scout without advertised --approve must omit the flag"
  done
  pass "Pi approve probing omits --approve when help does not advertise it"
}

# config/crew-exclude-tools: per-home worker tool exclusions (fm-spawn header).
write_exclude_file() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/crew-exclude-tools"
}

test_pi_exclude_tools_reach_ship_and_scout_launches() {
  local harness rec id out status launch kindflag
  for harness in pi pi-signed; do
    for kindflag in --ship --scout; do
      id="excl-${harness}-${kindflag#--}-z9a"
      rec=$(make_spawn_case "excl-${harness}-${kindflag#--}" "$harness" "$id")
      read_case_record "$rec"
      write_exclude_file "$HOME_DIR" '# hide the write tools' '' \
        '  mcp__tracker__editIssue  ' 'mcp__tracker__createPage' 'mcp__other-srv__tool.v2'
      if [ "$kindflag" = --scout ]; then
        out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
      else
        out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
      fi
      status=$?
      expect_code 0 "$status" "$harness $kindflag spawn with exclusions should succeed"$'\n'"$out"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "--exclude-tools 'mcp__tracker__editIssue,mcp__tracker__createPage,mcp__other-srv__tool.v2' " \
        "$harness $kindflag launch must carry the comma-joined, quoted exclusion list"
    done
  done
  pass "Pi and pi-signed ship and scout launches carry the configured tool exclusions"
}

test_pi_exclude_tools_worker_registry_reports() {
  local harness kindflag scenario case_name rec id out status report
  command -v node >/dev/null 2>&1 || fail "node is required to drive Pi worker exclusion reporting"
  for harness in pi pi-signed; do
    for kindflag in --ship --scout; do
      for scenario in matched unmatched unverified; do
        id="excl-registry-${harness}-${kindflag#--}-${scenario}"
        case_name=$id
        [ "$scenario" != unmatched ] || case_name="josé-$id"
        rec=$(make_spawn_case "$case_name" "$harness" "$id")
        read_case_record "$rec"
        case "$scenario" in
          matched) write_exclude_file "$HOME_DIR" 'mcp__tracker__editIssue' ;;
          unmatched) write_exclude_file "$HOME_DIR" 'mcp__tracker__editIssu' 'mcp__tracker__createIssu' ;;
          unverified) write_exclude_file "$HOME_DIR" 'mcp__offline__executeWrite' ;;
        esac
        if [ "$kindflag" = --scout ]; then
          out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
        else
          out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
        fi
        expect_code 0 "$?" "$harness $kindflag registry-report spawn should succeed: $out"
        out=$(EXT_PATH="$HOME_DIR/state/$id.pi-ext.ts" STATUS_FILE="$HOME_DIR/state/$id.status" \
          EXCLUDE_FILE="$HOME_DIR/config/crew-exclude-tools" TURNEND="$HOME_DIR/state/$id.turn-ended" \
          TASK_ID="$id" BUSY_EVENT="$ROOT/bin/fm-busy-event.sh" \
          SCENARIO="$scenario" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { pathToFileURL } from "node:url";
const status = () => existsSync(process.env.STATUS_FILE) ? readFileSync(process.env.STATUS_FILE, "utf8") : "";
const before = status();
const stateDir = dirname(process.env.STATUS_FILE);
const genFile = join(stateDir, process.env.TASK_ID + ".busy-gen");
const gen = readFileSync(genFile, "utf8").trim();
const busy = () => {
  const [version, ...fields] = readFileSync(join(stateDir, process.env.TASK_ID + ".busy-state"), "utf8").trim().split(" ");
  assert.equal(version, "v1");
  const { ts, ...record } = Object.fromEntries(fields.map((field) => field.split("=")));
  assert.match(ts, /^\d+$/);
  return record;
};
const seeded = busy();
assert.deepEqual(seeded, { gen, seq: "1", state: "busy", source: "fm-spawn", event: "launch-brief", reset: "0" });
const handlers = {};
let tools = [];
const extension = await import(pathToFileURL(process.env.EXT_PATH).href);
extension.default({
  on: (name, handler) => { handlers[name] = handler; },
  events: { on() {} },
  getAllTools: () => tools,
});
assert.equal(status(), before, "registration must not validate against a registry that has not loaded yet");
assert.deepEqual(busy(), seeded, "registration must not change busy state");
if (process.env.SCENARIO !== "unverified") {
  tools = [{ name: "mcp__tracker__editIssue" }, { name: "mcp__tracker__createIssue" }];
}
rmSync(process.env.TURNEND, { force: true });
await handlers.agent_start();
const started = { gen, seq: "2", state: "busy", source: "pi-ext", event: "agent-start", reset: "0" };
assert.deepEqual(busy(), started, "agent_start must publish a generation-bound Pi busy event");
const after = status();
if (process.env.SCENARIO === "matched") {
  assert.equal(after, before, "an exact match must produce no report");
} else {
  const report = after.slice(before.length);
  assert.match(report, /^note \[at=\d+\]: warning: /);
  assert.ok(report.includes(process.env.EXCLUDE_FILE), "the report must identify the config file");
  assert.ok(report.includes("unmatched exclusion entries"));
  assert.ok(report.includes("unverified"), "absence must never imply validity");
  const missing = process.env.SCENARIO === "unmatched"
    ? ["mcp__tracker__editIssu", "mcp__tracker__createIssu"]
    : ["mcp__offline__executeWrite"];
  for (const name of missing) assert.ok(report.includes(name), "every unmatched entry must be reported: " + name);
  assert.ok(!report.includes("mcp__tracker__editIssue"), "a loaded tool must not be reported");
}
await handlers.agent_settled({}, { isIdle: () => false });
assert.deepEqual(busy(), started, "a continuation must stay busy even when agent_settled fires");
await handlers.turn_end();
for (let attempt = 0; attempt < 100 && !existsSync(process.env.TURNEND); attempt++) {
  await setTimeout(10);
}
assert.ok(existsSync(process.env.TURNEND), "reporting must preserve turn-end notification");
assert.deepEqual(busy(), started, "an inner turn boundary must not mark the worker idle");
await handlers.agent_settled({}, { isIdle: () => true });
assert.deepEqual(busy(), { gen, seq: "3", state: "idle", source: "pi-ext", event: "agent-settled", reset: "0" });
await handlers.agent_start();
assert.deepEqual(busy(), { gen, seq: "4", state: "busy", source: "pi-ext", event: "agent-start", reset: "0" });
assert.equal(status(), after, "report once per worker incarnation, not on every turn");
appendFileSync(process.env.STATUS_FILE, "done: completed task\n");
const completed = status();
await handlers.agent_settled({}, { isIdle: () => true });
assert.deepEqual(busy(), { gen, seq: "5", state: "idle", source: "pi-ext", event: "agent-settled", reset: "0" });
assert.equal(status(), completed, "a reporting extension must not supersede a terminal worker status");
const replacementGen = execFileSync(process.env.BUSY_EVENT, ["arm", stateDir, process.env.TASK_ID], { encoding: "utf8" }).trim();
assert.notEqual(replacementGen, gen, "relaunch must mint a new generation");
const replacement = busy();
assert.deepEqual(replacement, { gen: replacementGen, seq: "1", state: "busy", source: "fm-spawn", event: "launch-brief", reset: "0" });
await handlers.agent_settled({}, { isIdle: () => true });
assert.deepEqual(busy(), replacement, "a stale extension must not clear its replacement's busy state");
await handlers.agent_start();
assert.deepEqual(busy(), replacement, "a stale extension must not publish into its replacement's generation");
assert.equal(readFileSync(genFile, "utf8").trim(), replacementGen);
assert.equal(status(), completed, "stale lifecycle events must not repeat exclusion warnings");
JS
        )
        status=$?
        expect_code 0 "$status" "$harness $kindflag $scenario worker registry check failed: $out"
        if [ "$scenario" != matched ]; then
          report=$(bash -c '. "$1/bin/fm-classify-lib.sh"; scan_unread_surface_lines "$2"' \
            _ "$ROOT" "$HOME_DIR/state")
          expect_code 0 "$?" "the supervisor's unread-status consumer should succeed"
          assert_contains "$report" "$HOME_DIR/config/crew-exclude-tools" "the supervisor must see the exclusion warning even after done"
          assert_contains "$report" "unverified" "the supervisor must see that exclusions remain unverified"
        fi
      done
    done
  done
  pass "Pi worker registries report unmatched and unverified exclusions without reporting exact matches"
}

test_pi_exclude_tools_absent_and_empty_lists() {
  local rec id out status launch
  id=excl-absent-z9b
  rec=$(make_spawn_case excl-absent pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "Pi spawn without the file should succeed"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "--exclude-tools" "an absent file must add no exclusions"

  id=excl-empty-z9c
  rec=$(make_spawn_case excl-empty pi "$id")
  read_case_record "$rec"
  write_exclude_file "$HOME_DIR" '# nothing yet' ''
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "Pi spawn with a comment-only file should succeed"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "--exclude-tools" "a file with no entries must add no exclusions"

  local harness
  for harness in pi pi-signed; do
    id="excl-${harness}-empty-z9d"
    rec=$(make_spawn_case "excl-${harness}-empty" "$harness" "$id")
    read_case_record "$rec"
    write_exclude_file "$HOME_DIR" '# nothing yet' ''
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness spawn with an empty exclusion list should succeed"$'\n'"$out"
    assert_not_contains "$(cat "$LAUNCH_LOG")" "--exclude-tools" "$harness must receive no exclusion flag"
  done
  pass "an absent or empty exclusion list leaves every runtime unaffected"
}

test_raw_launch_cannot_bypass_excluded_tools() {
  local rec id out status
  id=excl-refuse-raw-z9j
  rec=$(make_spawn_case excl-refuse-raw pi "$id")
  read_case_record "$rec"
  write_exclude_file "$HOME_DIR" 'mcp__srv__writeTool'
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "pi Verify this adapter")
  status=$?
  expect_code 1 "$status" "a raw launch with a non-empty exclusion list must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "the raw-launch refusal must name the config file"
  [ ! -s "$LAUNCH_LOG" ] || fail "a raw launch ignored the exclusion list"
  pass "an explicit launch command cannot bypass the configured exclusion list"
}

test_pi_exclude_tools_malformed_entry_refuses_before_endpoint() {
  local rec id out status bad n=0
  for bad in 'two words' 'a,b' 'mcp__srv__tool;rm' '*' 'mcp__srv__*Admin' 'quote'"'"'d' "mcp__srv__\$X"; do
    n=$((n + 1))
    id="excl-bad-$n-z9e"
    rec=$(make_spawn_case "excl-bad-$n" pi "$id")
    read_case_record "$rec"
    write_exclude_file "$HOME_DIR" 'mcp__srv__good' "$bad"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "malformed entry '$bad' must refuse the spawn"
    assert_contains "$out" "config/crew-exclude-tools has a malformed entry '$bad'" \
      "the refusal must name the malformed entry '$bad'"
    [ ! -s "$LAUNCH_LOG" ] || fail "a malformed exclusion entry '$bad' still launched a worker"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a malformed exclusion entry '$bad' still wrote a task record"
  done
  pass "a malformed exclusion entry refuses the spawn before any launch or record"
}

test_pi_exclude_tools_read_failure_refuses_before_launch() {
  local harness kind rec id out status bash_env
  for harness in pi pi-signed; do
    for kind in ship scout; do
      id="excl-read-failure-${harness}-${kind}"
      rec=$(make_spawn_case "$id" "$harness" "$id")
      read_case_record "$rec"
      write_exclude_file "$HOME_DIR" 'mcp__srv__writeTool'
      bash_env="$CASE_DIR/remove-exclusions.bash"
      # Make the file disappear immediately after its readability check, without
      # sleeps or permission assumptions (chmod alone would not fail as root).
      cat > "$bash_env" <<'SH'
function [ {
  local status=0
  builtin test "${@:1:$#-1}" || status=$?
  if builtin [ "$#" -eq 4 ] && builtin [ "$1" = '!' ] &&
    builtin [ "$2" = -r ] &&
    builtin [ "$3" = "${FM_CONFIG_OVERRIDE:-}/crew-exclude-tools" ]; then
    rm -f -- "$3"
  fi
  return "$status"
}
SH
      if [ "$kind" = scout ]; then
        out=$(BASH_ENV="$bash_env" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
      else
        out=$(BASH_ENV="$bash_env" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
      fi
      status=$?
      [ ! -e "$HOME_DIR/config/crew-exclude-tools" ] || fail "the read-failure injection did not remove the list"
      expect_code 1 "$status" "$harness $kind must refuse when the checked exclusion file cannot be opened"
      assert_contains "$out" "error: cannot read config/crew-exclude-tools" "the refusal must explain the read failure"
      [ ! -s "$LAUNCH_LOG" ] || fail "$harness $kind launched despite the unreadable exclusion list"
      [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$harness $kind read failure still wrote a task record"
    done
  done
  pass "Pi and pi-signed ship and scout launches refuse when the exclusion file disappears after its checks"
}

test_pi_exclude_tools_do_not_leak_across_homes() {
  local rec_a rec_b id_a id_b
  id_a=excl-home-a-z9f
  id_b=excl-home-b-z9g
  rec_a=$(make_spawn_case excl-home-a pi "$id_a")
  read_case_record "$rec_a"
  write_exclude_file "$HOME_DIR" 'mcp__srv__writeTool'
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null
  expect_code 0 "$?" "home A spawn should succeed"
  assert_contains "$(cat "$LAUNCH_LOG")" "--exclude-tools 'mcp__srv__writeTool'" "home A lost its own exclusions"

  # A second home running the same code, with no file of its own, inherits nothing.
  rec_b=$(make_spawn_case excl-home-b pi "$id_b")
  read_case_record "$rec_b"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null
  expect_code 0 "$?" "home B spawn should succeed"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "--exclude-tools" "home B must not inherit home A's exclusions"

  pass "exclusions stay in the home that configured them"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status copies
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch "$HOME_DIR" "$id1" clear pi openai-codex/gpt-5.6-sol high
  record_dispatch "$HOME_DIR" "$id2" escalate
  copies=$(make_batch_copies "$PROJ_DIR" "$CASE_DIR" "$id1" "$id2")

  out=$(FM_FAKE_PANE_PATH_ROOT=$copies run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model openai-codex/gpt-5.6-sol --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=pi" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=pi" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi openai-codex/gpt-5.6-sol high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi openai-codex/gpt-5.6-sol high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_lavish_server_address_is_exported_to_worker_launch() {
  local rec id out status launch
  id=profile-lavish-host-z18
  rec=$(make_spawn_case profile-lavish-host pi "$id")
  read_case_record "$rec"
  printf '%s\n' '192.0.2.10' > "$HOME_DIR/config/lavish-axi-host"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a configured Lavish server address should allow the worker spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "export LAVISH_AXI_HOST='192.0.2.10';" \
    "worker launch did not export the primary-owned Lavish server address"
  pass "the primary-owned Lavish server address reaches every worker launch"
}

test_lavish_absent_config_preserves_destination_ambient() {
  local rec id out status launch pane_log seen
  id=profile-lavish-ambient-z18b
  rec=$(make_spawn_case profile-lavish-ambient pi "$id")
  read_case_record "$rec"
  pane_log="$CASE_DIR/pane.log"
  seen="$CASE_DIR/lavish-seen"
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LAVISH_AXI_HOST-unset}" > "$FM_LAVISH_SEEN"
SH
  chmod +x "$FAKEBIN_DIR/pi"
  out=$(FM_FAKE_PANE_LOG="$pane_log" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an absent Lavish host configuration should allow the worker spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "LAVISH_AXI_HOST" \
    "an absent configuration changed the host in the worker launch"
  assert_not_contains "$(cat "$pane_log")" "LAVISH_AXI_HOST" \
    "an absent configuration changed the host in the destination pane"
  FM_LAVISH_SEEN="$seen" LAVISH_AXI_HOST=destination.example PATH="$FAKEBIN_DIR:$PATH" \
    bash -c "$launch" || fail "the destination-pane launch command failed"
  assert_grep 'destination.example' "$seen" \
    "the worker launch did not retain the destination pane's Lavish host"
  pass "absent Lavish configuration preserves the destination environment"
}

# Execute the actual emitted command in a synthetic pane environment: the
# fake backend records delivery, while real shells exercise the env boundary.
# No developer environment or credential values are inspected by these probes.
test_launch_environment_allowlist() {
  local setting rec id out status probe result expected launch value pane_shell pane_path
  value=$(cat <<'VALUE'
synthetic value; $(touch SHOULD_NOT_EXIST) `false` "quoted"
VALUE
)
  for setting in absent missing-config enabled empty; do
    id="env-$setting"
    rec=$(make_spawn_case "$id" pi "$id")
    read_case_record "$rec"
    case "$setting" in
      missing-config) rm "$HOME_DIR/config/crew-harness" ;;
      enabled) printf '# Synthetic credential name\nFM_TEST_ALLOWED\nFM_TEST_EMPTY\nFM_TEST_UNSET\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      empty) : > "$HOME_DIR/config/launch-env-allowlist" ;;
    esac
    probe="$CASE_DIR/probe.sh"
    cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "${FM_TEST_ALLOWED-unset}" \
  "${FM_TEST_EMPTY-unset}" "${FM_TEST_UNSET-unset}" "$HOME" "$PATH" "$TERM" "$HERDR_ENV" "$GOTMPDIR"
printf 'hooksPath=%s\n' "$(git config --get core.hooksPath || :)"
SH
    out=$(FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "/bin/sh '$probe'")
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      pane_path=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
        HERDR_ENV=synthetic-pane GOTMPDIR=/synthetic/gotmp \
        "$pane_shell" -c "printf %s \"\$PATH\"") \
        || fail "could not read $pane_shell startup PATH"
      result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
      HERDR_ENV=synthetic-pane GOTMPDIR=/synthetic/gotmp \
      FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED="$value" FM_TEST_EMPTY='' \
      "$pane_shell" -c "$launch") || fail "allowlist=$setting emitted launch failed in $pane_shell"
      case "$setting" in
        absent|missing-config) expected=$(printf '%s\n' synthetic-unrelated "$value" '' unset) ;;
        enabled) expected=$(printf '%s\n' unset "$value" '' unset) ;;
        empty) expected=$(printf '%s\n' unset unset unset unset) ;;
      esac
      expected="$expected"$'\n'"$HOME_DIR/user-home"$'\n'"$pane_path"$'\nxterm\nsynthetic-pane\n/synthetic/gotmp'
      # The strip-hook entry must also survive the env -i boundary.
      expected="$expected"$'\n'"hooksPath=$(cd "$HOME_DIR/state" && pwd -P)/$id.git-hooks"
      [ "$result" = "$expected" ] || fail "allowlist=$setting worker environment mismatch: $result"
    done
    pass "allowlist=$setting preserves the operational floor and filters only when opted in"
  done
}

test_launch_environment_invalid_config_refuses() {
  local rec id bad out status
  id=env-invalid
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  for bad in 'FM_TEST_ALLOWED=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid allowlist must refuse spawn"
    assert_contains "$out" 'launch-env-allowlist' "refusal must identify the config file"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid allowlist delivered a launch command"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "invalid allowlist published a task"
  done
  pass "invalid allowlist names refuse before launch or task publication"
}

test_launch_environment_inaccessible_config_refuses() {
  local setting presence rec id blocked out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible launch configuration requires a non-root user\n'
    return
  fi
  for setting in config ancestor; do
    for presence in present absent; do
      id="env-inaccessible-$setting-$presence"
      rec=$(make_spawn_case "$id" pi "$id")
      read_case_record "$rec"
      if [ "$presence" = present ]; then
        printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
      fi
      blocked="$HOME_DIR/config"
      if [ "$setting" = ancestor ]; then
        blocked="$HOME_DIR/config-parent"
        mkdir "$blocked"
        mv "$HOME_DIR/config" "$blocked/config"
        ln -s config-parent/config "$HOME_DIR/config"
      fi
      chmod 600 "$blocked" || fail "could not remove configuration search permission"
      out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness pi --backend herdr)
      status=$?
      chmod 700 "$blocked" || fail "could not restore configuration search permission"
      expect_code 1 "$status" "inaccessible $setting with $presence allowlist must refuse spawn: $out"
      assert_contains "$out" 'launch-env-allowlist' "refusal must identify the launch configuration"
      [ ! -s "$LAUNCH_LOG" ] || fail "inaccessible configuration delivered a launch command"
      [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "inaccessible configuration published a task"
      pass "inaccessible $setting with $presence allowlist refuses before launch or task publication"
    done
  done
}

test_launch_environment_allowlist
test_launch_environment_invalid_config_refuses
test_launch_environment_inaccessible_config_refuses

test_worker_launch_delivers_role_scope() {
  local rec id out launch kind prompt envelope encoded brief_kind brief content first_line role_line task_line inbox
  for brief_kind in heading legacy scaffold; do
  for kind in no-mistakes direct-PR local-only scout; do
    [ "$brief_kind" = heading ] && [ "$kind" != no-mistakes ] && continue
    id="role-launch-$brief_kind-$kind"
    rec=$(make_spawn_case "$id" pi)
    read_case_record "$rec"
    if [ "$brief_kind" != scaffold ]; then
      fm_test_spawn_brief "$HOME_DIR" "$id"
      if [ "$brief_kind" = heading ]; then
        printf '\n# Worker role\nFollow the project instructions.\n' >> "$HOME_DIR/data/$id/brief.md"
      fi
    else
      if [ "$kind" = scout ]; then
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
      else
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
      fi
      brief="$HOME_DIR/data/$id/brief.md"
      content=$(cat "$brief")
      content=${content//'{TASK}'/brief for $id}
      content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn behavior under test.}
      printf '%s\n' "$content" > "$brief"
    fi
    cp "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief-before"
    cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_ROLE_PROMPT"
SH
    chmod +x "$FAKEBIN_DIR/codex"
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode "$kind" --yolo off)
    fi
    expect_code 0 "$?" "$kind worker spawn failed: $out"
    launch=$(cat "$LAUNCH_LOG")
    envelope="$CASE_DIR/prompt-envelope"
    encoded="$CASE_DIR/encoded-prompt"
    prompt="$CASE_DIR/prompt"
    FM_ROLE_PROMPT="$envelope" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" || fail "could not consume $kind launch command"
    sed -n '/FIRSTMATE_OP: v1 launch-brief:/,$p' "$envelope" > "$encoded"
    "$ROOT/bin/fm-operational-input.sh" body < "$encoded" > "$prompt" ||
      fail "could not decode $kind launch-brief envelope"
    # The final prompt delivered to the harness is the generated interface.
    # The current identity must precede the authored task, because a Firstmate
    # worktree's own AGENTS.md assigns the unrelated supervisor identity.
    first_line=$(sed -n '1p' "$prompt")
    [ "$first_line" = '# Current worker role contract' ] ||
      fail "$brief_kind $kind did not establish worker identity before task content"
    role_line=$(grep -n '^# Current worker role contract$' "$prompt" | cut -d: -f1)
    task_line=$(grep -n '^# Task$' "$prompt" | head -1 | cut -d: -f1)
    [ "$role_line" -lt "$task_line" ] || fail "$brief_kind $kind put the worker identity after the task"
    assert_grep 'follow this brief instead of that supervisor contract' "$prompt" "$kind command did not deliver the role correction"
    assert_grep 'You are a crewmate: an autonomous worker agent managed by firstmate' "$prompt" "$kind command did not establish the worker identity directly"
    inbox="$HOME_DIR/state/$id.inbox"
    assert_grep "$inbox" "$prompt" "$kind command did not name the worker's own steering inbox"
    assert_grep "do not reject it as another home's state" "$prompt" "$kind command did not distinguish its inbox from another home's namespace"
    assert_grep "Never inspect or change any other home's endpoint namespace" "$prompt" "$kind command weakened cross-home isolation"
    assert_grep "skill name does not resolve in this session, read \`$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md\` instead." "$prompt" \
      "$kind command did not name the Firstmate skill file as the fallback"
    assert_grep 'brief for' "$prompt" "$kind command lost the task"
    [ "$(grep -c '^# Current worker role contract$' "$prompt")" -eq 1 ] ||
      fail "$brief_kind $kind duplicated the delivered worker contract"
    if [ "$brief_kind" = heading ]; then
      assert_grep 'Follow the project instructions' "$prompt" "$kind command dropped the authored role section"
    fi
    cmp -s "$CASE_DIR/brief-before" "$HOME_DIR/data/$id/brief.md" || fail "spawn rewrote the authored brief"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: %s %s worker\n%s\n' "$brief_kind" "$kind" "$out"
      printf 'launch command executed with an argv-capture harness:\n%s\nreceived arguments and final prompt:\n' "$launch"
      cat "$prompt"
      printf 'authored brief remains byte-identical\n# evidence end\n'
    fi
  done
  done
  pass "fm-spawn: actual ship/scout launch commands deliver the worker role contract"
}

test_launch_preserves_inherited_git_config
test_worker_launch_delivers_role_scope
test_quota_gate_refuses_profile_below_floor_with_reset
test_quota_gate_uses_strictest_matching_floor
test_quota_gate_skips_floor_instead_of_refusing_when_window_resets_within_a_day
test_quota_gate_keeps_refusing_instead_of_skipping_far_exhausted_or_unknown_resets
test_quota_gate_refuses_exhausted_now
test_quota_gate_records_override_and_unmatched_skip
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_recorded_dispatch_selection_refuses_conflicting_flags
test_recorded_dispatch_selection_allows_matching_flags
test_recorded_dispatch_selection_allows_recorded_override
test_recorded_dispatch_selection_leaves_unset_effort_unbound
test_recorded_dispatch_selection_refuses_raw_launch_without_override
test_active_dispatch_without_task_record_is_refused
test_batch_checks_each_task_against_its_own_record
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_chained_raw_launch_strips_ai_trailer_in_every_step
test_native_effort_validator_keeps_axes_separate
test_native_pi_ultra_is_explicit_and_model_scoped
test_batch_preserves_native_ultra
test_pi_scout_launch_enters_recorded_worktree
test_pi_threads_model_and_max_effort
test_pi_launch_keeps_default_tui_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_worker_launch_preapproves_project_trust
test_pi_approve_probe_omits_unsupported_flag
test_pi_exclude_tools_reach_ship_and_scout_launches
test_pi_exclude_tools_worker_registry_reports
test_pi_exclude_tools_absent_and_empty_lists
test_raw_launch_cannot_bypass_excluded_tools
test_pi_exclude_tools_malformed_entry_refuses_before_endpoint
test_pi_exclude_tools_read_failure_refuses_before_launch
test_pi_exclude_tools_do_not_leak_across_homes
test_batch_forwards_shared_profile_flags
test_lavish_server_address_is_exported_to_worker_launch
test_lavish_absent_config_preserves_destination_ambient

echo "# all fm-spawn-dispatch-profile tests passed"
