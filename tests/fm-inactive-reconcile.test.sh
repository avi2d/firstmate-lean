#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
fm_git_identity fmtest fmtest@example.invalid

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  # Mirrors bin/fm-crew-state.sh's one canonical line, including the source and
  # detail fields a terminal outcome must take its PR identity from.
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: %s%s\n' "${FM_FAKE_CREW_STATE:-unknown}" \
  "${FM_FAKE_CREW_SOURCE:-fake}" "${FM_FAKE_CREW_DETAIL:+ · $FM_FAKE_CREW_DETAIL}"
SH
  # FM_FAKE_PANE_CMD names the pane's foreground process: a harness is a live
  # agent, a shell an agent-free pane, and unset a pane Herdr no longer has.
  cat > "$fake/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -ge 2 ] && [ "${@: -2:1}" = --session ]; then set -- "${@:1:$#-2}"; fi
case "${1:-} ${2:-}" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}'
    exit 0 ;;
  'pane process-info') pane=${4:-} ;;
  'pane '*|'agent '*) pane=${3:-} ;;
  *) exit 1 ;;
esac
cmd=${FM_FAKE_PANE_CMD:-}
case "${1:-} ${2:-}" in
  'pane get')
    [ -n "$cmd" ] || { printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane" ;;
  'agent get')
    [ "$cmd" = pi ] || { printf '%s\n' '{"error":{"code":"agent_not_found"}}'; exit 1; }
    printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  'pane process-info')
    if [ "$cmd" = pi ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"pi","argv":["pi"]}]}}}\n' "$pane"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' "$pane"
    fi ;;
  'pane read') printf 'idle\n> \n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fake/herdr-ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=,comm=') printf ' 4242     1 zsh\n' ;;
  '-p 4242 -o args=') printf 'zsh\n' ;;
  *) exit 1 ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects}
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM} sha
  mkdir -p "$home/projects/$id"
  git -C "$home/projects/$id" init -q
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  fm_write_herdr_meta "$home/state/$id.meta" "firstmate:w1:p-$id" \
    "worktree=$home/projects/$id" "project=$home/projects/$id" \
    'harness=pi' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1' \
    "pr_head=$sha"
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_HERDR_PS_BIN="$WORLD/fakebin/herdr-ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

prime_seen() { # <state> <status>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

arm_pi_busy() { # <home> <id> <busy|idle>
  local home=$1 id=$2 state=$3
  printf 'g1\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=g1 seq=1 state=%s source=pi-ext event=test ts=%s\n' "$state" "$(date +%s)" > "$home/state/$id.busy-state"
}

run_live_child() { # <world> <busy|idle> <spawn-epoch-offset> [rewrite-meta]
  local status_epoch=$(( $(date +%s) - 600 ))
  make_world "$1"
  write_child "$MAIN" child "done[at=$status_epoch]: PR https://example.test/owner/repo/pull/1 checks green" "s$((status_epoch + $3)).1.1"
  arm_pi_busy "$MAIN" child "$2"
  age "$MAIN/state/child.meta" "$MAIN/state/child.status"
  [ -z "${4:-}" ] || set_mtime "$(( $(date +%s) - 90 ))" "$MAIN/state/child.meta"
  FM_FAKE_CREW_STATE='done' FM_FAKE_PANE_CMD=pi run_reconcile "$MAIN" --startup
}

assert_withheld() {
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$1: terminal outcome record written"
  ! grep -q inactive-outcome: "$MAIN/state/.wake-queue" 2>/dev/null || fail "$1: supervisor woke"
}

test_busy_agent_withholds_terminal_outcome() {
  run_live_child busy-agent busy -10
  assert_withheld "busy agent"
  pass "busy agent withholds the terminal outcome"
}

test_relaunched_idle_agent_withholds_terminal_outcome() {
  run_live_child relaunched-agent idle 10
  assert_withheld "relaunched agent"
  pass "idle agent on a newer incarnation withholds the terminal outcome"
}

test_idle_finished_agent_keeps_terminal_outcome() {
  run_live_child idle-agent idle -10
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "idle finished agent lost its terminal outcome"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "idle finished agent did not wake the supervisor"
  pass "idle finished agent keeps the terminal outcome"
}

test_idle_agent_with_rewritten_meta_keeps_terminal_outcome() {
  run_live_child rewritten-meta idle -10 rewrite
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "rewritten meta withheld the terminal outcome"
  pass "idle finished agent with rewritten meta keeps the terminal outcome"
}

test_dead_agent_keeps_terminal_outcome() {
  make_world dead-agent; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' FM_FAKE_PANE_CMD=zsh run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "dead agent lost its terminal outcome"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "dead agent did not wake the supervisor"
  pass "dead agent keeps the terminal outcome"
}

test_branch_ack_retires_inactive_outcome_receipt() {
  local err seq generation
  make_world branch-ack
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "scan did not queue the terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "scan did not retain a presentation receipt"

  # This test's own live process owns the grant the branch dispatch publishes.
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ { print $2 }' "$MAIN/state/.wake-queue" | tail -1)
  case "$seq" in ''|*[!0-9]*) fail "the queued inactive-outcome row had no sequence" ;; esac
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" activate "$$" branch-ack \
    || fail "branch owner activation failed"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" publish branch-ack "$seq" \
    || fail "branch grant publication failed"

  err="$WORLD/branch-drain.err"
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] \
    || { cat "$err"; fail "branch presentation did not require durable acknowledgement"; }
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] || fail "branch acknowledgement left its check row queued"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "branch acknowledgement left the terminal-outcome receipt pending"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "branch acknowledgement never recorded the presentation receipt"

  local cycle
  for cycle in 1 2 3; do
    age "$MAIN/state/.inactive-outcome-reconcile"
    FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN"
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] \
      || fail "unchanged inactive outcome re-queued on cadence scan $cycle after its branch acknowledgement"
  done
  pass "a branch-actor acknowledgement retires the inactive-outcome receipt and later scans stay quiet"
}

# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id
  write_child "$MAIN" child 'working: quiet since' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  rm -f "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  write_child "$MAIN" child 'working: quiet since' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 2 ] \
    || fail "reused task id collided with the retired incarnation receipt"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 2 ] \
    || fail "reused task id did not queue an independent presentation"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite
  write_child "$MAIN" child 'working: quiet since' spawn-old
  meta="$MAIN/state/child.meta"
  tmp="$MAIN/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup

  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "legacy metadata rewrite duplicated the presentation"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race
  write_child "$MAIN" child 'working: quiet since' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MAIN" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MAIN/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

test_watcher_poll_surfaces_inactive_outcome() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"
  pass "a watcher poll surfaces an inactive terminal outcome"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_stalled_liveness_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded-liveness
  write_child "$MAIN" a 'working: liveness read will stall'
  age "$MAIN/state/a.meta" "$MAIN/state/a.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 1
  printf 'state: failed · source: fake\n'
else
  printf 'state: done · source: fake\n'
fi
SH
  mv "$WORLD/fakebin/herdr" "$WORLD/fakebin/herdr-base"
  cat > "$WORLD/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
[ ! -e "$(dirname "$0")/stall" ] || sleep 30
exec "$(dirname "$0")/herdr-base" "$@"
SH
  : > "$WORLD/fakebin/stall"
  chmod +x "$WORLD/fakebin/fm-crew-state.sh" "$WORLD/fakebin/herdr"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 4 ] || fail "stalled liveness read exceeded aggregate scan budget (${elapsed}s)"

  rm -f "$WORLD/fakebin/stall"
  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled liveness reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  # The unbounded wake-lock wait is ended by the process-group backstop, which
  # fires one second after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

# --- a terminal outcome must be established from its own source --------------
# Regression family for the 2026-08-27 false failure report. The reader's
# terminal state was promoted into a captain-facing outcome together with a PR
# taken from an OLDER record, so one queued record was wrong twice: the work had
# not failed, and the pull request named was not the one the current run opened.

queued_payload() { # <home> <key-prefix>
  grep -F "$2" "$1/state/.wake-queue" 2>/dev/null | tail -1
}

# wake_count above reports an empty string when the queue file does not exist at
# all, which is the same fact as a zero count for these cases.
assert_nothing_queued() { # <home> <key-prefix> <message>
  case "$(wake_count "$1" "$2")" in
    ''|0) ;;
    *) fail "$3: $(queued_payload "$1" "$2")" ;;
  esac
}

# The exact shape that reached the captain: the current run opened no pull
# request at all, so the record must name none rather than borrowing the task's
# previously recorded one.
test_terminal_outcome_never_names_a_pr_the_run_did_not_open() {
  local payload
  make_world outcome-pr-absent; write_child "$MAIN" child 'working: still validating'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pull/1'*) fail "the terminal outcome named a pull request the run never opened: $payload" ;;
  esac
  pass "a terminal outcome names no pull request when its run opened none"
}

# When the run DID open one, that identity wins over the older recorded PR.
test_terminal_outcome_takes_the_pr_its_run_opened() {
  local payload
  make_world outcome-pr-current; write_child "$MAIN" child 'working: still validating'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='run-step' \
    FM_FAKE_CREW_DETAIL='checks green: PR ready for review · pr=https://example.test/owner/repo/pull/42' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr=https://example.test/owner/repo/pull/42'*) ;;
    *) fail "the terminal outcome did not name the run's own pull request: $payload" ;;
  esac
  case "$payload" in
    *'pull/1 '*|*'pull/1') fail "the terminal outcome kept the older recorded pull request: $payload" ;;
  esac
  pass "a terminal outcome names the pull request its own run opened"
}

# A state-log-sourced terminal state keeps taking its PR from that same line.
test_status_log_sourced_outcome_keeps_its_own_pr() {
  local payload
  make_world outcome-pr-log
  write_child "$MAIN" child 'done: PR https://github.com/owner/repo/pull/7 checks green'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='PR https://github.com/owner/repo/pull/7 checks green' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr=https://github.com/owner/repo/pull/7'*) ;;
    *) fail "the terminal outcome dropped the pull request its own record named: $payload" ;;
  esac
  pass "a status-log sourced outcome keeps the pull request that record named"
}

# Every supported forge's ready report keeps its review link: a GitLab merge
# request and a Gerrit change reported in their own ready shapes.
test_status_log_outcome_keeps_gitlab_and_gerrit_reviews() {
  local payload name url detail
  for name in gitlab gerrit; do
    case "$name" in
      gitlab)
        url='https://gitlab.example/group/sub/project/-/merge_requests/8'
        detail="PR $url checks green"
        ;;
      gerrit)
        url='https://gerrit.example/c/group/project/+/4201'
        detail="PR $url published for review"
        ;;
    esac
    make_world "outcome-pr-log-$name"
    write_child "$MAIN" child "done: $detail"
    FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
      FM_FAKE_CREW_DETAIL="$detail" run_reconcile "$MAIN" --startup
    payload=$(queued_payload "$MAIN" 'inactive-outcome:')
    [ -n "$payload" ] || fail "no terminal outcome was queued for $name"
    case "$payload" in
      *"pr=$url"*) ;;
      *) fail "the $name terminal outcome dropped its review link: $payload" ;;
    esac
  done
  pass "a status-log outcome keeps GitLab and Gerrit review links"
}

# A status-log outcome without its own PR carries none. An earlier working line
# and the task metadata deliberately name different PRs so either provenance
# violation is visible.
test_status_log_outcome_never_borrows_an_earlier_pr() {
  local payload
  make_world outcome-pr-log-absent
  write_child "$MAIN" child 'working: PR https://example.test/owner/repo/pull/55 still validating'
  printf 'done: implementation complete\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='implementation complete' run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome borrowed a pull request from another record: $payload" ;;
  esac
  pass "a status-log outcome without its own pull request carries none"
}

test_status_log_outcome_never_borrows_the_fresh_last_line_pr() {
  local payload
  make_world outcome-pr-log-fresh-line
  write_child "$MAIN" child 'done: implementation complete'
  printf 'working: PR https://example.test/owner/repo/pull/55 resumed\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='implementation complete' run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome borrowed a pull request from the corroboration line: $payload" ;;
  esac
  pass "a status-log outcome takes no pull request from another line"
}

# Prose is not a delivery claim: a terminal line that merely mentions pull
# requests names none of them as the delivery, so the abandoned one is never
# reported to the captain.
test_status_log_outcome_never_claims_a_mentioned_pr() {
  local payload note
  make_world outcome-pr-log-prose
  note='closed https://example.test/owner/repo/pull/12, shipped instead as https://example.test/owner/repo/pull/34'
  write_child "$MAIN" child "done: $note"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL="$note" run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome claimed a pull request only mentioned in prose: $payload" ;;
  esac
  pass "a status-log outcome never claims a pull request mentioned in prose"
}

# A scout never delivers a pull request, so even its ready-signal-shaped
# terminal line must produce an outcome that names no PR.
test_scout_outcome_carries_no_pull_request() {
  local payload
  make_world outcome-scout-pr
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/7 checks green'
  awk '{ sub(/^kind=ship$/, "kind=scout"); print }' "$MAIN/state/child.meta" \
    > "$MAIN/state/child.meta.tmp" && mv "$MAIN/state/child.meta.tmp" "$MAIN/state/child.meta"
  age "$MAIN/state/child.meta"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='PR https://example.test/owner/repo/pull/7 checks green' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued for the scout"
  case "$payload" in
    *'pr='*) fail "a scout's terminal outcome claimed a pull request: $payload" ;;
  esac
  pass "a scout's terminal outcome carries no pull request"
}

# The independent captain protection, for the one source where the two records
# are comparable: the reader read the crew's own STATUS LOG, and the crew's last
# self-declared word disagrees with what that read reported, so nothing is
# manufactured for presentation. Ordinary supervision still owns it. Re-pointed
# from a run-step state: a run-step state is the pipeline's own record and no
# longer answers to the crew's prose.
test_contradicted_failure_is_not_promoted_for_presentation() {
  make_world outcome-contradicted
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='status-log' FM_FAKE_CREW_DETAIL='the build broke' \
    run_reconcile "$MAIN" --startup
  assert_nothing_queued "$MAIN" 'inactive-outcome:' "a contradicted failure was queued for the captain"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "a contradicted failure minted a durable record"
  pass "a failure the crew's own last word contradicts is never presented"
}

# The mirror direction: a success the crew's own last word calls a failure is
# equally unsafe to present. Re-pointed to a status-log state for the same
# reason as its sibling above. This also subsumes the removed
# test_crew_prose_cannot_forge_the_ordering_field: the ordering field it forged
# no longer exists, so a status-log note carrying any prose at all now reaches
# this same guard and cannot switch it off.
test_contradicted_success_is_not_promoted_for_presentation() {
  make_world outcome-contradicted-done
  write_child "$MAIN" child 'failed: the build broke'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' FM_FAKE_CREW_DETAIL='implementation complete' \
    run_reconcile "$MAIN" --startup
  assert_nothing_queued "$MAIN" 'inactive-outcome:' "a contradicted success was queued for the captain"
  pass "a success the crew's own last word contradicts is never presented"
}

# The routine ship shape, and the reason this whole path exists: the crew
# declares implementation done, firstmate then starts the validation run, the
# run FAILS, and the crew goes silent without appending `failed:`. The reader
# reports that failure from the pipeline's own run step, which outranks the
# crew's earlier word, so the captain must still be told - a failure reaching
# nobody is the harm this path exists to remove.
test_run_step_failure_is_not_suppressed_by_the_crews_own_word() {
  local payload
  make_world outcome-mid-run-done
  write_child "$MAIN" child 'done: implementation complete'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "a run-step failure behind the crew's own done line was dropped"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "no durable terminal outcome was minted for the failure"
  pass "a run-step failure is not suppressed by the crew's own earlier word"
}

# The mirror shape the branch is named for: a stale `paused:` line and a real
# run failure reported from the run step.
test_stale_pause_does_not_suppress_the_failure() {
  make_world outcome-stale-pause
  write_child "$MAIN" child 'paused: waiting on the pipeline'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "a failure behind a stale pause line was dropped"
  pass "a stale pause line does not suppress the failure that followed it"
}

# Direction guard: a crew that simply stopped mid-work has no self-declared
# outcome to contradict the reader, so a genuine failure still reaches the
# captain. Hiding real failures is equally wrong.
test_uncontradicted_failure_is_still_presented() {
  make_world outcome-genuine; write_child "$MAIN" child 'working: implementing'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "a genuine failure was not queued for the captain"
  pass "a genuine, uncontradicted failure still reaches the captain"
}


# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_reconciliation_sets_no_forge_mode_for_state_read() {
  make_world no-forge-env; write_child "$MAIN" child 'working: quiet since'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_CREW_STATE_NO_FORGE:-}" > "${FM_NO_FORGE_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  export FM_NO_FORGE_LOG="$WORLD/no-forge.log"
  run_reconcile "$MAIN" --startup
  unset FM_NO_FORGE_LOG
  assert_grep '1' "$WORLD/no-forge.log" "inactive reconciliation did not set crew-state no-forge mode"
  pass "reconciliation state reads set no-forge mode"
}

test_main_direct_terminal_presentation_receipt
test_busy_agent_withholds_terminal_outcome
test_relaunched_idle_agent_withholds_terminal_outcome
test_idle_finished_agent_keeps_terminal_outcome
test_idle_agent_with_rewritten_meta_keeps_terminal_outcome
test_dead_agent_keeps_terminal_outcome
test_branch_ack_retires_inactive_outcome_receipt
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_watcher_poll_surfaces_inactive_outcome
test_stalled_state_read_is_bounded_and_scan_progresses
test_stalled_liveness_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_reconciliation_never_calls_forge
test_reconciliation_sets_no_forge_mode_for_state_read
test_terminal_outcome_never_names_a_pr_the_run_did_not_open
test_terminal_outcome_takes_the_pr_its_run_opened
test_status_log_sourced_outcome_keeps_its_own_pr
test_status_log_outcome_keeps_gitlab_and_gerrit_reviews
test_status_log_outcome_never_borrows_an_earlier_pr
test_status_log_outcome_never_borrows_the_fresh_last_line_pr
test_status_log_outcome_never_claims_a_mentioned_pr
test_scout_outcome_carries_no_pull_request
test_contradicted_failure_is_not_promoted_for_presentation
test_contradicted_success_is_not_promoted_for_presentation
test_run_step_failure_is_not_suppressed_by_the_crews_own_word
test_stale_pause_does_not_suppress_the_failure
test_uncontradicted_failure_is_still_presented

echo "all inactive reconciliation tests passed"
