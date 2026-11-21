#!/usr/bin/env bash
# Behavior tests for bin/fm-session-start.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-tests)
SESSION_START_TEST_HARNESS_PID=$$
SESSION_START_SECOND_MATE_ID="fmtest-sm-${TMP_ROOT##*.}"
SESSION_START_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_SECOND_MATE_ID"
SESSION_START_HERDR_SECOND_MATE_ID="fmtest-herdr-${TMP_ROOT##*.}"
SESSION_START_HERDR_SECOND_MATE_TMP="/tmp/fm-$SESSION_START_HERDR_SECOND_MATE_ID"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT" "$SESSION_START_SECOND_MATE_TMP" "$SESSION_START_HERDR_SECOND_MATE_TMP")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# --- world builders ----------------------------------------------------------

# new_world <name>: a real, throwaway git repo on `main` (so the worktree-tangle
# and default-branch checks behave exactly as they do against the real
# firstmate repo) to use as FM_ROOT_OVERRIDE, plus an empty FM_HOME with
# state/, data/, config/, and a fakebin. Echoes "<root-dir>|<home-dir>|<fakebin>".
new_world() {
  local name=$1 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

# make_fake_toolchain <fakebin>: every tool fm-bootstrap.sh detects, present
# and compatible, so its own detect-only section stays quiet except where a
# test deliberately breaks one. Mirrors fm-bootstrap.test.sh's fixture.
make_fake_toolchain() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' manual > "${fakebin%/*}/home-placeholder" 2>/dev/null || true
}

# make_fake_tasks_axi_compact <fakebin>: a tasks-axi boundary that answers the
# four group filters the startup listing composes (in-flight, held, blocked
# queued, and the dispatchable ready set) and REFUSES anything the recovery
# listing must never ask for: a body field, an unfiltered whole-backlog listing,
# or done rows. FM_FAKE_TASKS_AXI_READY sizes the ready set so the queued bound
# can be driven past its limit.
make_fake_tasks_axi_compact() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_AXI_LOG:-}
[ -n "$log" ] && printf '%s\n' "$*" >> "$log"
ready_count=${FM_FAKE_TASKS_AXI_READY:-2}
require_file() {
  case "$*" in *'--file '*) return 0 ;; esac
  printf '%s\n' 'missing explicit backlog file' >&2
  exit 9
}
task_header() {
  printf 'count: %s\n' "$1"
  printf 'tasks[%s]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:\n' "$1"
}
list_help() {
  printf 'help[1]:\n'
  printf '%s\n' '  - Run `tasks-axi show <id> --full` for full notes on a task'
}
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.6'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  ready)
    require_file "$@"
    rows=${FM_FAKE_TASKS_AXI_READY_ROWS:-}
    [ -z "$rows" ] || ready_count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    printf 'count: %s\n' "$ready_count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$ready_count"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" | sed 's/^/  /'
    else
      i=1
      while [ "$i" -le "$ready_count" ]; do
        printf '  ready-%s,queued,ship,firstmate,Ready item %s\n' "$i" "$i"
        i=$((i + 1))
      done
    fi
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n'
    printf '%s\n' '  - Run `tasks-axi start <id>` to dispatch one of these'
    exit 0
    ;;
  list)
    case "$*" in
      *'--fields '*'body'*|*'--fields='*'body'*)
        printf '%s\n' 'unexpected body field requested' >&2
        exit 9
        ;;
    esac
    require_file "$@"
    case "$*" in
      *'--state done'*)
        printf '%s\n' 'startup recovery must never list done rows' >&2
        exit 9
        ;;
      *'--state in_flight'*'--fields held'*)
        printf 'count: 2\ntasks[2]{id,state,kind,repo,title,held}:\n'
        printf '%s\n' '  compact-startup,in_flight,ship,firstmate,Compact startup digest,yes'
        printf '%s\n' '  open-work,in_flight,ship,firstmate,"Open work, not held",no'
        ;;
      *'--state in_flight'*)
        task_header 1
        printf '%s\n' '  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending'
        ;;
      *'--state held'*)
        held_count=${FM_FAKE_TASKS_AXI_HELD:-1}
        task_header "$held_count"
        printf '%s\n' '  held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending'
        i=2
        while [ "$i" -le "$held_count" ]; do
          printf '  held-%s,queued,ship,firstmate,Held item %s,none,captain,pick one\n' "$i" "$i"
          i=$((i + 1))
        done
        ;;
      *'--state queued'*'--blocked'*)
        blocked_count=${FM_FAKE_TASKS_AXI_BLOCKED:-1}
        task_header "$blocked_count"
        printf '%s\n' '  blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"'
        i=2
        while [ "$i" -le "$blocked_count" ]; do
          printf '  blocked-%s,queued,ship,firstmate,Blocked item %s,compact-startup,"-","-"\n' "$i" "$i"
          i=$((i + 1))
        done
        ;;
      *)
        printf '%s\n' 'startup recovery must not request an unfiltered whole-backlog listing' >&2
        exit 9
        ;;
    esac
    list_help
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
}

# make_fake_ps_claude <fakebin>: harness_pid()/holder_alive() (fm-lock.sh) walk
# `ps` output looking for a harness command name; this fake reports EVERY
# queried pid as a live `claude` harness unless a stable harness pid is set.
make_fake_ps_claude() {
  local fakebin=$1
  make_fake_ps_harness "$fakebin" claude
}

make_fake_ps_harness() {
  local fakebin=$1 harness=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
# The ancestry this stub reports defaults to the harness the fixture was built
# for, so a case that builds a pi (or codex) fixture gets pi (or codex) ancestry
# without having to repeat it per run; FM_FAKE_HARNESS still overrides it.
harness=\${FM_FAKE_HARNESS:-$harness}
SH
  cat >> "$fakebin/ps" <<'SH'
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '/usr/local/bin/%s\n' "$harness"
    else
      printf '/bin/bash\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ] \
      || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ]; then
      printf '%s\n' "$harness"
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
  *"ppid="*)
    [ -n "${FM_FAKE_HARNESS_PID:-}" ] || exit 1
    /bin/ps -o ppid= -p "$pid"
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$harness" > "$fakebin/.harness-name"
}

make_fake_ps_pi_holder() {
  local fakebin=$1 holder_pid=$2 harness=${3:-pi}
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
pid=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$arg"
  prev="\$arg"
done
case "\$*" in
  *"comm="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '/usr/local/bin/$harness\n'
    else
      printf '/bin/zsh\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ "\$pid" = "$holder_pid" ]; then
      printf '$harness\n'
    else
      printf 'zsh\n'
    fi
    exit 0
    ;;
  *"ppid="*) printf '%s\n' "$holder_pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_fake_herdr <fakebin> <live-pane> [odd-status-pane]: `herdr pane get
# <pane>` succeeds only for the given pane id - the exact primitive
# fm_backend_target_exists uses for a herdr endpoint liveness read. An
# optional second pane id answers with exit 4, the shape backend probes
# produce for a gone surface without normalising to 1 (jq -e on empty input,
# orca's ok:false, a missing tmux binary). No version/server-start calls: a
# liveness check must never auto-start a server (fm-backend.sh's contract).
make_fake_herdr() {
  local fakebin=$1 live=$2 odd=${3:-}
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  [ -n "$odd" ] && [ "\${3:-}" = "$odd" ] && exit 4
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# make_fake_herdr_deadly_read <fakebin> <live-pane> <kill-pane>: like
# make_fake_herdr, but `pane get <kill-pane>` KILLs the shell running the
# endpoint read. The read's shell is the fake's grandparent (fm_backend_herdr_cli's
# stderr-capture subshell sits in between), so the fake walks one /proc hop
# above $PPID. This is the digest-death shape: a per-task herdr liveness
# read whose process died mid-read, which used to take the whole
# session-start digest with it.
make_fake_herdr_deadly_read() {
  local fakebin=$1 live=$2 killpane=$3
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  if [ "\${3:-}" = "$killpane" ]; then
    read_shell=\$(sed 's/^[^)]*) //' /proc/\$PPID/stat 2>/dev/null | awk '{print \$2}')
    kill -KILL "\$read_shell" 2>/dev/null
    exit 0
  fi
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# make_fake_herdr_hanging_read <fakebin> <live-pane> <hang-pane>: like
# make_fake_herdr, but `pane get <hang-pane>` never returns - the backend-CLI
# hang shape the per-task read bound must turn into an error line.
make_fake_herdr_hanging_read() {
  local fakebin=$1 live=$2 hangpane=$3
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = pane ] && [ "\${2:-}" = get ]; then
  [ "\${3:-}" = "$hangpane" ] && sleep 300
  [ "\${3:-}" = "$live" ] && exit 0
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/herdr"
}

# run_session_start <home> <root> <path>
# Drop every harness env marker from bin/fm-harness.sh detect_own so the
# surrounding interactive shell cannot leak past the suite's fake ps harness.
# Markers today: CLAUDECODE (claude), PI_CODING_AGENT plus FM_PI_HARNESS
# (Pi family), GROK_AGENT (grok).
# codex and opencode have no env markers (ancestry only). Without this, a local
# claude/pi/grok session fails cases that pin a different fake harness while CI
# (no ambient markers) still passes.
run_session_start() {
  local home=$1 root=$2 path=$3 pi_harness=${4:-}
  if [ -n "$pi_harness" ]; then
    env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS="$pi_harness" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  else
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
      "$SESSION_START"
  fi
}

run_pi_session_start() {  # <home> <root> <path> [fm-session-start args...]
  local home=$1 root=$2 path=$3
  shift 3
  env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS=pi \
    FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
    "$SESSION_START" "$@"
}

run_named_harness_session_start() {  # <harness> <home> <root> <path> [fm-session-start args...]
  local harness=$1 home=$2 root=$3 path=$4
  shift 4
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_FAKE_HARNESS="$harness" FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$path" \
    "$SESSION_START" "$@"
}

# wait_for_network_stage <home> <root> [seconds]
# Block until the deferred network stage this home's session start launched has
# published. Only a TEST does this: the digest itself is required never to wait,
# which is exactly why the sweeps it used to run inline have to be re-asserted
# here instead of straight off the digest's own output.
wait_for_network_stage() {
  local home=$1 root=$2 limit=${3:-30}
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-startup-network.sh" wait "$limit"
}

wait_for_network_wake() {
  local home=$1 limit=${2:-30} waited=0
  while ! grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null
}

network_stage_report() {
  local home=$1 root=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-startup-network.sh" report
}

hash_file_for_test() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

install_pi_turnend_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$root/.pi/extensions/fm-primary-turnend-guard.ts"
}

install_pi_watch_extension_fixture() {
  local root=$1
  mkdir -p "$root/.pi/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$root/.pi/extensions/fm-primary-pi-watch.ts"
}

write_pi_watch_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n%s\ngeneration=1 phase=active\n' "$version" "$pid" > "$home/state/.pi-watch-extension-loaded"
}

write_pi_turnend_loaded_marker() {
  local home=$1 root=$2 pid=$3 version
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$version" "$pid" > "$home/state/.pi-turnend-extension-loaded"
}

write_pi_loaded_markers() {
  local home=$1 root=$2 pid=$3
  write_pi_watch_loaded_marker "$home" "$root" "$pid"
  write_pi_turnend_loaded_marker "$home" "$root" "$pid"
}

# --- context digest: absent vs empty vs present -----------------------------

test_context_digest_absent_empty_present() {
  local rec root home fakebin out
  rec=$(new_world context-digest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf '%s\n' '- demo [no-mistakes] - a demo project (added 2026-07-01)' > "$home/data/projects.md"
  : > "$home/data/captain.md"
  # learnings.md deliberately absent

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "data/projects.md" "digest did not label the projects.md section"
  assert_contains "$out" "- demo [no-mistakes] - a demo project (added 2026-07-01)" "digest did not print projects.md content"
  assert_contains "$out" "fm-role: user (default)" "digest did not report the home's firstmate-repository role"

  assert_contains "$out" "data/captain.md" "digest did not label the captain.md section"
  assert_contains "$out" "data/learnings.md" "digest did not label the learnings.md section"

  # The present-but-empty captain.md must NOT print ABSENT.
  absent_count=$(printf '%s\n' "$out" | grep -c '^ABSENT$')
  [ "$absent_count" -eq 2 ] || fail "expected 2 ABSENT markers (learnings.md, backlog.md), got $absent_count: $out"

  cap_section=$(printf '%s\n' "$out" | awk '/^data\/captain\.md$/{flag=1;next}/^data\//{flag=0}flag')
  assert_contains "$cap_section" "(present, empty)" "empty-but-present captain.md was not distinguished from ABSENT"

  pass "context digest distinguishes ABSENT, empty-but-present, and populated files"
}

# --- lock refusal: read-only path --------------------------------------------

test_lock_refusal_read_only_path() {
  local rec root home fakebin holder_pid out status
  rec=$(new_world lock-refusal)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  fm_write_herdr_meta "$home/state/task-x.meta" sess:w1:p-x kind=ship
  append_wake "$home/state" signal task-x "done: surfaced before refusal" || fail "seed wake failed"
  git -C "$root" checkout -q -B fm/read-only-tangle

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  expect_code 0 "$status" "fm-session-start.sh must exit 0 even on a lock refusal"
  assert_contains "$out" "READ-ONLY SESSION" "read-only banner missing on lock refusal"
  assert_contains "$out" "another live firstmate session holds the lock" "read-only banner did not surface fm-lock.sh's own error text"
  assert_contains "$out" "Skipping every mutating step" "read-only banner did not explain what was skipped"
  assert_contains "$out" "skipped (read-only session)" "wake-queue section did not report itself skipped"
  assert_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" "read-only guard did not surface watcher-liveness alarm"
  assert_contains "$out" "queued wakes pending - left untouched because this session lacks verified fleet-lock ownership" "read-only guard did not leave queued wakes untouched without verified lock ownership"
  assert_contains "$out" "TANGLE: primary checkout on feature branch 'fm/read-only-tangle'" "read-only bootstrap did not surface the tangle diagnostic"
  assert_contains "$out" "read-only session must leave restore work" "read-only tangle diagnostic did not explain restore ownership"
  assert_contains "$out" "Stay read-only: do not arm" "read-only next step did not block direct watcher repair"
  assert_not_contains "$out" "drain them with bin/fm-wake-drain.sh" "read-only guard printed a mutating drain instruction"
  assert_not_contains "$out" "After draining queued wakes" "read-only guard printed a drain-then-rearm instruction"
  assert_not_contains "$out" "run bin/fm-watch-arm.sh" "read-only guard printed a mutating watcher-arm instruction"
  assert_not_contains "$out" "git -C $root checkout main" "read-only bootstrap printed a state-changing checkout remediation"

  # Detect-only bootstrap diagnostics still ran (the fakebin's PATH excludes
  # tasks-axi, so bootstrap's own read-only tool-detection line fires
  # deterministically regardless of what is installed on the test host).
  assert_contains "$out" "MISSING: tasks-axi (install:" "detect-only bootstrap diagnostics did not run on the read-only path"

  assert_absent "$home/state/.startup-network.status" \
    "a lock refusal started the deferred mutating sweeps"

  # The rest of the digest (read-only-safe) still completed.
  assert_contains "$out" "FLEET STATE" "fleet-state digest section missing on the read-only path"
  assert_contains "$out" "NEXT STEP" "closing reminder missing on the read-only path"

  pass "a lock refusal prints a loud read-only banner, skips every mutating step, and still completes the digest"
}

test_lock_write_failure_read_only_path() {
  local rec root home fakebin out status
  rec=$(new_world lock-write-failure)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  append_wake "$home/state" signal task-a "done: must remain queued" || fail "seed wake failed"
  chmod 0500 "$home/state"

  status=0
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?
  chmod 0700 "$home/state"

  expect_code 0 "$status" "fm-session-start.sh must exit 0 when lock publication fails"
  assert_contains "$out" "cannot write session lock" "lock publication failure was not surfaced"
  assert_contains "$out" "READ-ONLY SESSION" "lock publication failure did not force a read-only session"
  assert_contains "$out" "FLEET LOCK OWNERSHIP WAS NOT VERIFIED" "lock publication failure was misreported as a live holder"
  assert_contains "$out" "lacks verified fleet-lock ownership" "lock publication failure did not explain why queued wakes remain untouched"
  assert_not_contains "$out" "ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK" "lock publication failure falsely claimed a live lock holder"
  [ -s "$home/state/.wake-queue" ] || fail "lock publication failure allowed the wake queue to mutate"

  pass "session start stays read-only when lock ownership cannot be published"
}

test_trace_context_effective_state_is_frozen_after_lock() {
  local rec root home fakebin out frozen
  rec=$(new_world trace-context-session-state)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  : > "$home/config/trace-context"

  FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = off ] \
    || fail "session start must freeze an env-off override over a present config flag"

  rm "$home/config/trace-context"
  FM_TRACE_CONTEXT=on run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  [ "$(awk '{print $2}' "$home/state/.trace-context-effective")" = on ] \
    || fail "a new session start must freeze an env-on override over an absent config flag"
  frozen=$(cat "$home/state/.trace-context-effective")

  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  out=$(FM_TRACE_CONTEXT=off run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  assert_contains "$out" "READ-ONLY SESSION" "trace-context refusal fixture did not enter read-only mode"
  [ "$(cat "$home/state/.trace-context-effective")" = "$frozen" ] \
    || fail "a lock-refused session must not mutate the frozen trace-context state"

  pass "locked session start freezes trace context and lock refusal leaves it unchanged"
}

# Wait until <dir> holds <count> entries. Forty workers poll this at once, so
# the count is a builtin glob rather than a find pipeline (no process per
# poll), and the wait ends early once the directory is gone, the suite has
# died, or FM_TEST_STUB_MAX_BLOCK_SECONDS has passed, so an interrupted run
# cannot leave forty pollers spinning under init.
lock_concurrency_barrier() {  # <dir> <count>
  local dir=$1 want=$2 start=$SECONDS entries
  while [ -d "$dir" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null \
    && [ $((SECONDS - start)) -lt "$FM_TEST_STUB_MAX_BLOCK_SECONDS" ]; do
    entries=("$dir"/*)
    [ -e "${entries[0]}" ] || entries=()
    [ "${#entries[@]}" -lt "$want" ] || return 0
    sleep 0.05
  done
  return 1
}

test_session_lock_concurrent_single_winner() {
  local rec root home fakebin ready completed winners pids i pid count
  rec=$(new_world lock-concurrency)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  ready="$home/ready"
  completed="$home/done"
  winners="$home/winners"
  mkdir -p "$ready" "$completed"
  : > "$winners"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' /usr/local/bin/claude
    else
      printf '%s\n' /bin/bash
    fi
    ;;
  *"args="*)
    if [ -f "$FM_FAKE_LOCK_STATE/harness-$pid" ]; then
      printf '%s\n' claude
    else
      printf '%s\n' bash
    fi
    ;;
  *"ppid="*) printf '%s\n' "$FM_FAKE_HARNESS_PID" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  pids=
  i=1
  while [ "$i" -le 40 ]; do
    (
      harness_pid=$(sh -c 'printf "%s\n" "$PPID"')
      : > "$home/state/harness-$harness_pid"
      : > "$ready/$i"
      lock_concurrency_barrier "$ready" 40
      if FM_HOME="$home" FM_FAKE_LOCK_STATE="$home/state" \
        FM_FAKE_HARNESS_PID="$harness_pid" PATH="$fakebin:$BASE_PATH" \
        "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1; then
        printf '%s\n' "$harness_pid" >> "$winners"
      fi
      : > "$completed/$i"
      lock_concurrency_barrier "$completed" 40
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  count=$(awk 'NF { count++ } END { print count + 0 }' "$winners")
  [ "$count" -eq 1 ] || fail "concurrent session-lock acquisition produced $count winners"

  pass "concurrent session-lock acquisition admits exactly one live harness"
}

# --- output ordering ----------------------------------------------------------

# The digest is delivered through a harness that truncates from the TAIL, so
# section order decides what a truncated startup loses. The safety preamble
# still leads, live fleet identity now outranks curated memory, and the
# read-once contract arrives before the payload it governs.
test_output_ordering_diagnostics_lead() {
  local rec root home fakebin out lock_line boot_line wake_line read_once_line
  local context_line fleet_line next_line inventory_line missing_line
  rec=$(new_world ordering)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Force a MISSING diagnostic line so the bootstrap section is non-trivial.
  rm -f "$fakebin/node"

  printf 'window=fm-sess:w1\nkind=ship\n' > "$home/state/task-a.meta"
  printf 'Captain memory that may be truncated away safely.\n' > "$home/data/captain.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$(fm_test_base_path_sans "$BASE_PATH" node)")

  lock_line=$(printf '%s\n' "$out" | grep -n '^LOCK$' | head -1 | cut -d: -f1)
  boot_line=$(printf '%s\n' "$out" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  read_once_line=$(printf '%s\n' "$out" | grep -n '^READ-ONCE CONTRACT$' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  fleet_line=$(printf '%s\n' "$out" | grep -n '^FLEET STATE$' | head -1 | cut -d: -f1)
  next_line=$(printf '%s\n' "$out" | grep -n '^NEXT STEP$' | head -1 | cut -d: -f1)
  inventory_line=$(printf '%s\n' "$out" | grep -n '^task-a \[ship\] ' | head -1 | cut -d: -f1)

  if [ -z "$lock_line" ] || [ -z "$boot_line" ] || [ -z "$wake_line" ] \
    || [ -z "$read_once_line" ] || [ -z "$context_line" ] || [ -z "$fleet_line" ] \
    || [ -z "$next_line" ] || [ -z "$inventory_line" ]; then
    fail "one or more section headers missing from digest: $out"
  fi

  # The safety preamble's order is unchanged: mutation authority, then
  # diagnostics, then this turn's work queue, before anything bulky is read.
  [ "$lock_line" -lt "$boot_line" ] || fail "LOCK did not precede BOOTSTRAP"
  [ "$boot_line" -lt "$wake_line" ] || fail "BOOTSTRAP did not precede WAKE QUEUE"
  [ "$wake_line" -lt "$read_once_line" ] || fail "WAKE QUEUE did not precede the read-once contract"

  [ "$read_once_line" -lt "$fleet_line" ] || fail "the read-once contract did not precede FLEET STATE"
  [ "$fleet_line" -lt "$context_line" ] || fail "FLEET STATE did not precede CONTEXT"
  [ "$context_line" -lt "$next_line" ] || fail "CONTEXT did not precede NEXT STEP"

  # The live-task inventory - the record recovery actually depends on - must sit
  # ahead of the curated memory a truncated tail is allowed to take.
  [ "$inventory_line" -lt "$context_line" ] \
    || fail "the live-task inventory was buried behind the curated memory files"
  assert_contains "$out" "Captain memory that may be truncated away safely." \
    "the ordering fixture did not actually print a memory file"

  missing_line=$(printf '%s\n' "$out" | grep -n 'MISSING: node' | head -1 | cut -d: -f1)
  [ -n "$missing_line" ] || fail "MISSING diagnostic did not appear at all"
  [ "$missing_line" -lt "$fleet_line" ] || fail "actionable MISSING diagnostic was buried after the bulk fleet-state digest"

  pass "digest sections are ordered safety-preamble first, live fleet state before curated memory"
}

# The contract has to survive tail truncation and stay honest once it precedes
# the sections it governs, so it carries the truncated-stage escape itself.
test_read_once_contract_is_stated_once_before_its_subject() {
  local rec root home fakebin out contract_count
  rec=$(new_world read-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Do NOT re-read any of them after reading this digest" \
    "the read-once contract lost its core instruction"
  assert_contains "$out" "or a STARTUP TRUNCATED banner or a re-emit read cue says a stage never" \
    "the read-once contract does not void itself for a stage that never ran"
  assert_contains "$out" "The READ-ONCE CONTRACT" \
    "the closing reminder does not point back at the contract"

  contract_count=$(printf '%s\n' "$out" | grep -c 'Do NOT re-read any of them')
  [ "$contract_count" -eq 1 ] \
    || fail "the read-once contract is stated $contract_count times instead of once: $out"

  pass "the read-once contract is stated once, ahead of the sources it governs"
}

test_herdr_backend_diagnostics_follow_real_session_start() {
  local mode rec root home fakebin mask out
  for mode in configured autodetected; do
    rec=$(new_world "herdr-$mode")
    IFS='|' read -r root home fakebin <<EOF
$rec
EOF
    make_fake_toolchain "$fakebin"
    make_fake_ps_claude "$fakebin"
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" herdr jq
    printf '%s\n' manual > "$home/config/backlog-backend"
    mask="$home/mask-tmux.bash"
    cat > "$mask" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then
    return 1
  fi
  builtin command "$@"
}
SH
    if [ "$mode" = configured ]; then
      printf '%s\n' herdr > "$home/config/backend"
      out=$(TMUX='' HERDR_ENV='' BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_not_contains "$out" "NOTICE: auto-detected herdr runtime" \
        "an explicit Herdr home should not be reported as auto-detected"
    else
      out=$(TMUX='' HERDR_ENV=1 BASH_ENV="$mask" run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
      assert_not_contains "$out" "NOTICE: auto-detected herdr runtime" \
        "session start should keep verified Herdr runtime auto-detection silent"
    fi
    assert_contains "$out" "SESSION START - $home" "the real session-start path did not run in the throwaway home"
    assert_not_contains "$out" "MISSING: tmux" "Herdr session start falsely required masked tmux"
    assert_not_contains "$out" "MISSING: herdr" "Herdr session start missed its available session CLI"
    assert_not_contains "$out" "MISSING: jq" "Herdr session start missed its available JSON dependency"
    assert_not_contains "$out" "MISSING: treehouse" "Herdr session start missed its available worktree provider"
  done
  pass "session start: configured and auto-detected Herdr homes never require tmux"
}

# --- one line per task under way ---------------------------------------------

test_task_line_prints_latest_status_not_older_lines_or_meta_body() {
  local rec root home fakebin out
  rec=$(new_world status-latest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live"

  printf 'window=sess:p-live\nkind=ship\nmode=direct-PR\nbackend=herdr\nworktree=/META-BODY-CANARY\n' > "$home/state/task-a.meta"
  printf 'working: step 1\nworking: step 2\nworking: step 3\n\n' > "$home/state/task-a.status"
  printf 'window=sess:p-gone\nkind=scout\nbackend=herdr\n' > "$home/state/task-b.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" \
    "task-a [ship direct-PR] endpoint: alive (backend=herdr window=sess:p-live) - latest: working: step 3" \
    "a task under way did not get one line with its kind, mode, endpoint, and latest status line"
  assert_not_contains "$out" "working: step 2" "the task line printed an older status line"
  assert_not_contains "$out" "META-BODY-CANARY" "the digest printed a meta body instead of one line"
  assert_contains "$out" "task-b [scout] endpoint: dead (backend=herdr window=sess:p-gone) - latest: (no status yet)" \
    "a task with no status log lost its line"
  assert_contains "$out" "one line per state/*.meta task with" \
    "the read-once contract does not say each task gets one line"

  pass "each task under way prints one line with its latest status line and no meta body or older lines"
}

# A worker writes its own status lines, so nothing upstream bounds their length.
test_task_line_caps_status_and_keeps_endpoint_verdict() {
  local rec root home fakebin out lede line status_part
  rec=$(new_world status-line-cap)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live"

  lede='needs-decision: [key=cap] pick the rendering strategy'
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-cap.meta"
  {
    printf 'working: older line\n'
    printf '%s' "$lede"
    awk 'BEGIN { while (i++ < 400) printf " padding" }'
    printf '\n'
  } > "$home/state/task-cap.status"
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-short.meta"
  printf 'working: short line kept whole\n' > "$home/state/task-short.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  line=$(printf '%s\n' "$out" | grep '^task-cap \[ship\] ')
  [ -n "$line" ] || fail "the over-long task produced no line: $out"
  case "$line" in *"endpoint: alive (backend=herdr window=sess:p-live) - latest: $lede"*) ;;
    *) fail "the cap dropped the endpoint verdict or the lede: $line" ;; esac
  case "$line" in *" [truncated]") ;; *) fail "an over-long status line was not marked as truncated: $line" ;; esac
  status_part=${line#*" - latest: "}
  [ "${#status_part}" -le 220 ] || fail "the status part ran ${#status_part} characters past the 220-character cap"
  assert_contains "$out" "task-short [ship] endpoint: alive (backend=herdr window=sess:p-live) - latest: working: short line kept whole" \
    "the cap mangled a status line already under it"

  pass "a long latest status line is capped and marked while the endpoint verdict survives"
}

test_wake_queue_rows_capped_in_digest_whole_in_queue() {
  local rec root home fakebin payload out row_line drained
  rec=$(new_world wake-row-cap)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  payload=$(awk 'BEGIN { s = "signal:"; for (i = 0; i < 12; i++) s = s " /padding/state/task-wake.status"; print s }')
  append_wake "$home/state" signal task-wake.status "$payload"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  row_line=$(printf '%s\n' "$out" | grep -F "$(printf '\tsignal\ttask-wake.status\t')" | head -n 1)
  [ -n "$row_line" ] || fail "the digest printed no wake-queue row for the queued signal: $out"
  [ "${#row_line}" -le 220 ] || fail "a wake-queue row ran ${#row_line} characters past the 220-character cap: $row_line"
  case "$row_line" in *" [truncated]") ;; *) fail "a capped wake-queue row lacks the truncation marker: $row_line" ;; esac

  assert_grep "$payload" "$home/state/.wake-queue" "the queue lost the whole row the digest capped"
  drained=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" 2>"$home/drain.err") || fail "the drain failed after the digest: $(cat "$home/drain.err")"
  case "$drained" in *"$payload"*) ;; *) fail "the drain output does not carry the whole queued row" ;; esac
  pass "the digest caps each wake-queue row with a truncation marker while the queue and drain keep it whole"
}

test_session_start_reports_a_wake_older_than_one_cycle_as_a_watcher_failure() {
  local rec root home fakebin out queue old
  rec=$(new_world wake-overdue)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  append_wake "$home/state" signal task-wake.status "signal: $home/state/task-wake.status"
  queue="$home/state/.wake-queue"
  old=$(( $(date +%s) - 1000 ))
  awk -F '\t' -v OFS='\t' -v old="$old" '{ $1 = old; print }' "$queue" > "$queue.tmp" && mv "$queue.tmp" "$queue"
  out=$(FM_WATCHER_STALE_GRACE=300 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "watcher: FAILED - 1 queued wake(s) not handled within one watcher cycle (300s): oldest seq 1 waited" \
    "a wake older than one watcher cycle was not reported as a watcher failure"
  pass "session start reports a wake older than one watcher cycle as a watcher failure"
}

test_orphan_status_logs_are_printed() {
  local rec root home fakebin out matched_count orphan_count
  rec=$(new_world orphan-status)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  printf 'kind=ship\n' > "$home/state/task-a.meta"
  printf 'working: surfaced once\n' > "$home/state/task-a.status"
  printf 'working: orphan step 1\nworking: orphan step 2\nworking: orphan step 3\nworking: orphan step 4\nworking: orphan step 5\nworking: orphan step 6\n' \
    > "$home/state/task-orphan.status"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "Orphan status logs (state/*.status without matching .meta)" "digest did not label orphan status logs"
  assert_contains "$out" "task-orphan ($home/state/task-orphan.status) - latest: working: orphan step 6" \
    "an orphan status log did not get one line with its id, path, and latest status line"
  assert_not_contains "$out" "working: orphan step 5" "an orphan status log printed an older line"

  matched_count=$(printf '%s\n' "$out" | grep -F -c 'working: surfaced once')
  orphan_count=$(printf '%s\n' "$out" | grep -F -c 'working: orphan step 6')
  [ "$matched_count" -eq 1 ] || fail "matched status log was printed $matched_count times: $out"
  [ "$orphan_count" -eq 1 ] || fail "orphan status log was printed $orphan_count times: $out"

  pass "orphan status logs are printed once with bounded tails"
}

# --- endpoint liveness: herdr, live and dead ---------------------------------

test_endpoint_liveness_herdr() {
  local rec root home fakebin out
  rec=$(new_world liveness-herdr)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr "$fakebin" "p-live" "p-odd"

  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-live.meta"
  printf 'window=sess:p-dead\nkind=ship\nbackend=herdr\n' > "$home/state/task-dead.meta"
  printf 'window=sess:p-odd\nkind=ship\nbackend=herdr\n' > "$home/state/task-odd.meta"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" "live herdr endpoint not reported alive"
  assert_contains "$out" "endpoint: dead (backend=herdr window=sess:p-dead)" "dead herdr endpoint not reported dead"
  assert_contains "$out" "endpoint: dead (backend=herdr window=sess:p-odd)" \
    "a probe exiting 4 for a gone surface was not reported dead"
  assert_not_contains "$out" "endpoint: error (backend=herdr window=sess:p-odd" \
    "a probe exiting 4 was mislabelled as a failed read"

  pass "herdr endpoint liveness is reported per task: alive, dead for exit 1, dead for any other probe status"
}

test_endpoint_read_death_is_isolated_and_reported() {
  local rec root home fakebin out status=0
  [ -r /proc/self/stat ] || { echo "skip: /proc not readable (the read-death shape needs process ancestry)"; return 0; }
  rec=$(new_world endpoint-death)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr_deadly_read "$fakebin" "p-live" "p-doom"

  printf 'window=sess:p-doom\nkind=ship\nbackend=herdr\n' > "$home/state/task-a-doom.meta"
  printf 'working: doomed task marker\n' > "$home/state/task-a-doom.status"
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-z-live.meta"

  out=$(FM_SESSION_START_ENDPOINT_TIMEOUT=bogus run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "one killed endpoint read must not fail the digest"
  assert_contains "$out" \
    "endpoint: error (backend=herdr window=sess:p-doom - the endpoint read died or hit its 10s bound; the digest continued past it)" \
    "a killed endpoint read was not reported as that task's own error line"
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" \
    "the digest did not continue past the killed read to the next task"
  assert_contains "$out" "working: doomed task marker" \
    "the doomed task's status tail was lost along with its endpoint read"
  assert_contains "$out" "$(printf '\nCONTEXT\n')" \
    "a killed endpoint read cost the digest its context section"
  assert_contains "$out" "NEXT STEP" \
    "a killed endpoint read cost the digest its closing reminder"
  assert_not_contains "$out" "STARTUP TRUNCATED - SESSION START" \
    "an isolated endpoint-read death raised the truncation banner"
  assert_present "$home/state/.session-start-complete" \
    "a digest that survived a killed endpoint read did not record completion"

  pass "a killed per-task endpoint read becomes that task's error line and the digest completes"
}

test_endpoint_read_hang_is_bounded_and_reported() {
  local rec root home fakebin out status=0 stray
  rec=$(new_world endpoint-hang)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr_hanging_read "$fakebin" "p-live" "p-slow"

  printf 'window=sess:p-slow\nkind=ship\nbackend=herdr\n' > "$home/state/task-a-slow.meta"
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-z-live.meta"

  out=$(FM_SESSION_START_ENDPOINT_TIMEOUT=2 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a hung endpoint read must not fail the digest"
  assert_contains "$out" \
    "endpoint: error (backend=herdr window=sess:p-slow - the endpoint read died or hit its 2s bound; the digest continued past it)" \
    "a hung endpoint read was not bounded into that task's own configured bound"
  assert_contains "$out" "endpoint: alive (backend=herdr window=sess:p-live)" \
    "the digest did not continue past the hung read to the next task"
  assert_contains "$out" "$(printf '\nCONTEXT\n')" \
    "a hung endpoint read cost the digest its context section"
  assert_not_contains "$out" "STARTUP TRUNCATED - SESSION START" \
    "a bounded endpoint-read hang raised the whole-digest truncation banner"

  stray=$(pgrep -f "$fakebin/herdr" 2>/dev/null | wc -l | tr -d ' ')
  [ "$stray" -eq 0 ] || fail "the per-task read bound left $stray hung herdr process(es) behind"

  pass "a hung per-task endpoint read hits its configured bound, reports the task, and leaves nothing stuck"
}

test_endpoint_bound_rejects_padded_zero() {
  local rec root home fakebin out status=0 stray
  rec=$(new_world endpoint-padded-zero)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_herdr_hanging_read "$fakebin" "p-live" "p-slow"

  printf 'window=sess:p-slow\nkind=ship\nbackend=herdr\n' > "$home/state/task-a-slow.meta"
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\n' > "$home/state/task-z-live.meta"

  # Only the unrelated summary gets a shorter fixture budget. The invalid
  # endpoint value must still fall back to the real 10s production bound.
  out=$(FM_HOME_SUMMARY_TIMEOUT=5 FM_SESSION_START_ENDPOINT_TIMEOUT=00 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a padded-zero per-read bound must not fail the digest"
  assert_contains "$out" \
    "endpoint: error (backend=herdr window=sess:p-slow - the endpoint read died or hit its 10s bound; the digest continued past it)" \
    "a padded-zero bound did not fall back to the 10s default, so the hung read went unbounded"
  assert_contains "$out" "$(printf '\nCONTEXT\n')" \
    "a padded-zero bound cost the digest its context section"

  stray=$(pgrep -f "$fakebin/herdr" 2>/dev/null | wc -l | tr -d ' ')
  [ "$stray" -eq 0 ] || fail "the fallback bound left $stray hung herdr process(es) behind"

  pass "a padded-zero per-read bound falls back to the 10s default instead of removing the bound"
}

test_perl_timeout_fallback_reports_signal_death_nonzero() {
  local toolbin cmd rc=0
  command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (this case pins the perl mechanism only)"; return 0; }
  toolbin=$(mktemp -d "${TMPDIR:-/tmp}/fm-perl-timeout.XXXXXX")
  for cmd in bash perl sleep kill cat rm mktemp; do
    command -v "$cmd" >/dev/null 2>&1 && ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  PATH="$toolbin" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    [ "$(fm_timeout_mechanism)" = perl ] || { echo "mechanism: $(fm_timeout_mechanism)" >&2; exit 99; }
    fm_run_timed 5 bash -c "kill -KILL \$\$"
  ' _ "$ROOT" || rc=$?
  rm -rf "$toolbin"
  expect_code 137 "$rc" "the perl timeout fallback did not report a SIGKILLed child as 128+9"

  pass "the perl timeout fallback reports a signal death as a nonzero status"
}

test_abnormal_digest_death_banners_and_exits_zero() {
  local rec root home fakebin out status=0
  [ -r /proc/self/stat ] || { echo "skip: /proc not readable (the digest-death shape needs process ancestry)"; return 0; }
  rec=$(new_world digest-death-banner)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # Replace the harness ps with one that TERMs the digest process itself when
  # fm-lock.sh invokes it: the shape where the digest child dies mid-stage
  # from something other than its runtime bound, which the parent used to
  # swallow silently (no banner, exit 0, rest of the digest gone).
  # ps sits below fm-lock.sh below the digest bash, so walk /proc upward.
  # Flattened cmdline matching alone is useless: timeout's bash -c inner shell
  # and the timeout wrapper carry the script path as an ARGV element, and the
  # lock stage's own command substitution leaves a subshell whose argv is
  # still `fm-session-start.sh` - only the topmost match is the digest bash
  # itself. That digest child is the topmost ancestor whose ENVIRON carries
  # FM_SESSION_START_STAGE_FILE: the parent wrapper mktemps the file and hands
  # it over with env (which never keeps it for itself), the bash -c inner
  # shell and timeout sit BELOW env, and the parent wrapper never holds it -
  # so the env marker stops the walk above the digest child and below the
  # wrapper whose death would skip the banner entirely. Kill that topmost
  # marker carrier: the digest bash whose death the parent must banner.
  mv "$fakebin/ps" "$fakebin/ps.real"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$(tr '\\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)" in
  *fm-lock.sh*)
    pid=\$PPID
    target=
    matched=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ -n "\$pid" ] && [ "\$pid" != 1 ] || break
      if tr '\\0' '\\n' < /proc/\$pid/environ 2>/dev/null | grep -q '^FM_SESSION_START_STAGE_FILE=' \
        && case "\$(tr '\\0' ' ' < /proc/\$pid/cmdline 2>/dev/null)" in *fm-session-start.sh*) true ;; *) false ;; esac; then
        target=\$pid
        matched=1
      elif [ "\$matched" -eq 1 ]; then
        break
      fi
      pid=\$(sed 's/^[^)]*) //' /proc/\$pid/stat 2>/dev/null | awk '{print \$2}')
    done
    [ -n "\$target" ] && kill -TERM "\$target" 2>/dev/null
    ;;
esac
exec "$fakebin/ps.real" "\$@"
SH
  chmod +x "$fakebin/ps"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a digest child that died mid-stage must still let the session open (parent exits 0)"
  assert_contains "$out" \
    "STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit 143, not its runtime bound)" \
    "a digest child killed mid-stage did not name its abnormal death"
  assert_contains "$out" 'stopped during the "lock" stage' \
    "the abnormal-death banner did not name the stage that never finished"
  assert_contains "$out" \
    "wake-queue supervision-instructions read-once fleet-state network-checks context next-step" \
    "the abnormal-death banner did not list every stage that never ran"
  assert_not_contains "$out" "RUNTIME BOUND" \
    "an abnormal death was misreported as the runtime bound firing"
  assert_contains "$out" "report the exit status and the stage" \
    "the abnormal-death banner did not tell the reader to report the exit status"
  assert_not_contains "$out" "raise FM_SESSION_START_TIMEOUT" \
    "the abnormal-death banner advised raising a bound that did not fire"
  assert_not_contains "$out" "NEXT STEP" \
    "a digest that died mid-stage claimed to have reached its closing reminder"
  assert_absent "$home/state/.session-start-complete" \
    "a digest that died mid-stage recorded itself as complete"

  pass "a digest child killed mid-stage is bannered by the parent, which still exits 0"
}

# --- composition: real scripts run, not reimplemented ------------------------

test_composition_invokes_real_scripts() {
  local rec root home fakebin out
  rec=$(new_world composition)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  rm -f "$fakebin/node"

  printf 'needs-decision: pick a library\n' > "$home/state/task-z.status"
  append_wake "$home/state" signal task-z.status "needs-decision: pick a library"

  out=$(run_session_start "$home" "$root" "$fakebin:$(fm_test_base_path_sans "$BASE_PATH" node)")

  # fm-lock.sh's own exact success text.
  assert_contains "$out" "lock acquired: harness pid" "fm-lock.sh's real output did not appear (composition, not reimplementation)"
  # fm-bootstrap.sh's own exact MISSING-tool line format.
  assert_contains "$out" "MISSING: node (install:" "fm-bootstrap.sh's real detect line did not appear verbatim"
  # fm-wake-drain.sh's real drained record (raw tab-separated queue line).
  assert_contains "$out" "$(printf 'signal\ttask-z.status\tneeds-decision: pick a library')" "fm-wake-drain.sh's real drained record did not appear"
  assert_contains "$out" "  task-z.status latest: needs-decision: pick a library" "fm-session-start.sh did not preserve the drain's separate annotation line"

  pass "fm-session-start.sh composes the real fm-lock.sh, fm-bootstrap.sh, and fm-wake-drain.sh output verbatim"
}

test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep() {
  local rec root home fakebin out
  rec=$(new_world branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  # A crash window the locked start must preserve: the supervision branch
  # stored a leading routine row and a captain row that never reached Pi, plus one lease whose
  # supervising process died and one still held by a live process.
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict routine --summary 'worker recovered automatically' >/dev/null \
    || fail "could not seed the unread routine branch outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'PR https://example.com/pr/b checks green' >/dev/null \
    || fail "could not seed the unread branch outcome"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-live --actor branch \
    || fail "could not seed the live lease"

  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):" \
    "locked start did not replay the leading routine branch outcome"
  assert_contains "$out" "worker recovered automatically" "replayed routine outcome lost its content"
  assert_not_contains "$out" "https://example.com/pr/b" "locked start crossed the captain delivery barrier"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "locked start marked the unrendered captain outcome read"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "locked start advanced past the captain row"
  [ ! -e "$home/state/.lease-task-dead" ] || fail "locked start left a provably dead lease in place"
  [ -e "$home/state/.lease-task-live" ] || fail "locked start swept a live lease"

  # Routine replay is one-shot, while the captain row remains held for Pi's
  # sequence-keyed visible-entry reconciliation.
  out=$(run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*) fail "second start re-presented already-replayed branch outcomes" ;;
  esac
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/b" "second start consumed the captain row without a Pi entry"
  pass "locked Pi session start replays leading routine outcomes, preserves the captain barrier, and sweeps only dead leases"
}

test_non_pi_session_start_leaves_branch_state_untouched() {
  local rec root home fakebin out
  rec=$(new_world non-pi-branch-recovery)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  # A Claude home runs the supervision host by default and then presents its
  # outcomes; this case pins a home that does not run it.
  : > "$home/config/supervision-host-off"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-b --verdict captain --summary 'unread Pi branch outcome' >/dev/null \
    || fail "could not seed the non-Pi unread branch outcome"
  rm -f "$home/state/.branch-outcomes-cursor"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  case "$out" in
    *"BRANCH OUTCOMES"*|*"unread Pi branch outcome"*) fail "non-Pi session replayed Pi branch outcomes" ;;
  esac
  [ -e "$home/state/.lease-task-dead" ] || fail "non-Pi session swept a Pi branch lease"
  [ ! -e "$home/state/.branch-outcomes-cursor" ] || fail "non-Pi session marked a Pi branch outcome read"
  pass "non-Pi session start neither sweeps nor replays Pi branch state"
}

# --- deferred network stage -------------------------------------------------

# install_slow_gh <fakebin> <seconds>: one external-network call the digest used
# to make directly. Making it pathologically slow is how a test stands in for an
# unreachable host without touching one: if any part of the blocking path still
# waits on the network, the digest cannot finish before this does.
install_slow_gh() {
  local fakebin=$1 seconds=$2 finished_marker=${3:-}
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ]; then
  sleep $seconds
  [ -z '$finished_marker' ] || : > '$finished_marker'
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# The locked startup scan may need the same expensive current-state read that a
# busy validation makes slow. It belongs to the detached startup worker, so the
# digest must finish while that read is still outstanding; the answer then has to
# create the ordinary durable inactive-outcome wake rather than disappear
# off-path. The slow read is held open by this case rather than by a fixed sleep,
# so "the digest did not wait for it" is decided by what had happened when the
# digest returned and not by how fast the host was.
test_inactive_reconcile_never_blocks_the_digest() {
  local rec root home fakebin world worktree crew_state calls out waited=0
  local release_gate read_finished
  rec=$(new_world inactive-reconcile-deferred)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  world=${root%/root}
  worktree="$world/child-worktree"
  crew_state="$world/slow-crew-state.sh"
  calls="$world/no-mistakes-state.calls"
  ln -s "$ROOT/bin" "$root/bin"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  fm_git_init_commit "$worktree"

  release_gate="$world/slow-state-read.release"
  read_finished="$world/slow-state-read.finished"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'axi status' ]; then
  if [ "${FM_BOOTSTRAP_NETWORK:-}" = only ]; then
    printf '%s\n' 'deferred' >> "${FM_FAKE_NM_CALLS:?}"
  else
    printf '%s\n' 'blocking' >> "${FM_FAKE_NM_CALLS:?}"
  fi
  # Stay outstanding until the case releases this read. A caller that waits for
  # it therefore waits indefinitely rather than for a fixed interval a loaded
  # host could out-run. The tick bound only stops a broken case hanging forever.
  ticks=0
  while [ ! -e "${FM_FAKE_NM_RELEASE:?}" ] && [ "$ticks" -lt 300 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  : > "${FM_FAKE_NM_READ_FINISHED:?}"
  printf '%s\n' 'slow validation state answered'
fi
exit 0
SH
  cat > "$crew_state" <<'SH'
#!/usr/bin/env bash
set -u
no-mistakes axi status >/dev/null
printf '%s\n' 'state: done · source: run-step · passed'
SH
  chmod +x "$fakebin/no-mistakes" "$crew_state"

  fm_write_herdr_meta "$home/state/slow-child.meta" \
    firstmate:w1:p-slow-child "worktree=$worktree" 'project=firstmate' \
    'harness=pi' 'kind=scout' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=slow-child.1'
  printf '%s\n' 'working: validating' > "$home/state/slow-child.status"
  : > "$home/state/slow-child.turn-ended"
  touch -t 202001010000 "$home/state/slow-child.meta" \
    "$home/state/slow-child.status" "$home/state/slow-child.turn-ended"

  out=$(FM_BACKEND=herdr FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    FM_FAKE_NM_CALLS="$calls" FM_FAKE_NM_RELEASE="$release_gate" \
    FM_FAKE_NM_READ_FINISHED="$read_finished" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=30 FM_INACTIVE_CREW_STATE_BIN="$crew_state" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_absent "$read_finished" \
    "the digest waited for inactive reconciliation's still-unreleased state read"
  [ "$(grep -c '^blocking$' "$calls" 2>/dev/null || true)" -eq 0 ] \
    || fail "the digest called the slow state reader on its blocking path"
  : > "$release_gate"

  while ! grep -Fq $'\tcheck\tinactive-outcome:' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt 150 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'check	inactive-outcome:' "$home/state/.wake-queue" \
    "the deferred scan's terminal finding never reached the durable wake queue (calls=$(cat "$calls" 2>/dev/null), report=$(network_stage_report "$home" "$root" 2>/dev/null), queue=$(cat "$home/state/.wake-queue" 2>/dev/null))"
  [ "$(grep -c '^deferred$' "$calls" 2>/dev/null || true)" -eq 1 ] \
    || fail "the deferred scan did not make exactly one slow state read"
  pass "session start: inactive reconciliation runs after the digest and retains its durable wake"
}

# The headline guarantee: an unreachable host delays a reported CHECK, never the
# startup. The fake host hangs for 12s; the digest must be done long before that,
# must say so rather than implying the checks passed, and the sweeps must still
# run and land afterwards.
test_unreachable_network_never_blocks_the_digest() {
  local rec root home fakebin network_finished out started elapsed
  rec=$(new_world slow-network)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  network_finished="${root%/root}/network-finished"
  install_slow_gh "$fakebin" 12 "$network_finished"

  started=$(date +%s)
  out=$(FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  elapsed=$(( $(date +%s) - started ))

  [ ! -e "$network_finished" ] \
    || fail "the digest waited for the 12s unreachable-host probe instead of returning from local state (${elapsed}s)"
  assert_contains "$out" "SESSION START" "the digest did not complete"
  assert_contains "$out" "IN PROGRESS - the deferred network checks have not finished yet." \
    "the digest did not disclose that its network checks were still running"
  assert_contains "$out" "NOT yet confirmed: GitHub authentication, project clone refresh with its drift reporting, and inactive terminal-outcome reconciliation." \
    "the digest did not name the checks it has not confirmed"
  assert_not_contains "$out" "NEEDS_GH_AUTH" \
    "the digest reported a GitHub-auth verdict it could not yet have"

  # ... and the work itself still happens, off the blocking path.
  wait_for_network_stage "$home" "$root" 60 \
    || fail "the deferred stage never finished: $(network_stage_report "$home" "$root")"
  assert_contains "$(network_stage_report "$home" "$root")" "NEEDS_GH_AUTH" \
    "the deferred stage lost the GitHub-auth verdict it was deferring"
  pass "session start: an unreachable host delays a reported check, not the digest"
}

# A result the digest could not print must still reach the agent by itself. The
# opposite half of the handshake - a printed result never ALSO queuing a wake -
# is asserted deterministically in tests/fm-startup-network.test.sh, where the
# claim can be set up directly instead of raced against digest composition.
test_deferred_result_reaches_the_agent_when_the_digest_cannot_print_it() {
  local rec root home fakebin queue
  rec=$(new_world wake-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  install_slow_gh "$fakebin" 8
  queue="$home/state/.wake-queue"

  FM_FAKE_HARNESS_PID="$SESSION_START_TEST_HARNESS_PID" \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  wait_for_network_stage "$home" "$root" 60 || fail "the deferred stage never finished"
  wait_for_network_wake "$home" 60 || fail "the deferred stage never settled wake delivery"
  assert_grep 'check	startup-network' "$queue" \
    "a result the digest could not print never reached the agent: $(cat "$queue" 2>/dev/null)"
  pass "session start: a deferred result the digest outran still reaches the agent as a wake"
}

# A read-only session has no lock, so it neither owns the mutating sweeps nor has
# any action a GitHub-auth verdict would gate. It must say that plainly instead of
# quietly dropping the checks.
test_read_only_session_declares_skipped_network_checks() {
  local rec root home fakebin out
  rec=$(new_world network-read-only)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-p 999999"*) printf 'claude\n'; exit 0 ;;
  *"comm="*|*"args="*) printf 'bash\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "READ-ONLY SESSION" "the read-only fixture did not actually refuse the lock"
  assert_contains "$out" "skipped (read-only session) - GitHub authentication" \
    "a read-only session did not declare its skipped network checks"
  assert_absent "$home/state/.startup-network.status" \
    "a read-only session started the deferred stage it has no authority for"
  pass "session start: a read-only session declares its skipped network checks rather than dropping them"
}

# The compatibility verdict costs three tasks-axi subprocesses and one session
# start needs it twice. The digest must pay for it once.
test_tasks_axi_compatibility_is_probed_once() {
  local rec root home fakebin log probes
  rec=$(new_world tasks-axi-once)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  log="$home/tasks-axi.log"
  printf '# Backlog\n\n## In flight\n\n## Queued\n' > "$home/data/backlog.md"

  FM_FAKE_TASKS_AXI_LOG="$log" run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null

  probes=$(grep -c -- '--version' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi was version-probed $probes times in one session start: $(cat "$log")"
  probes=$(grep -c -- 'update --help' "$log" || true)
  [ "$probes" -eq 1 ] \
    || fail "tasks-axi update --help ran $probes times in one session start: $(cat "$log")"
  assert_grep 'ready --file' "$log" "the backlog listing never ran, so the verdict was not actually reused"
  pass "session start: the tasks-axi compatibility verdict is computed once and reused"
}

# --- fleet-state digest: compact backlog rendering --------------------------

# A backlog whose Done section, held row, blocked row, and plain queued rows can
# each be told apart in the rendered digest. DONE-ROW-LINE and the *-BODY-LINE
# markers exist so a leak is unmistakable.
write_long_body_backlog() {
  local path=$1 i=1
  cat > "$path" <<'EOF'
# Backlog

## In flight
- [ ] compact-startup - Compact startup digest (repo: firstmate) (kind: ship) (since 2026-07-15) (hold: captain choice pending) (hold-kind: captain)
  OVERSIZED-BODY-LINE current startup leaks task note bodies into the session digest.
  Another long body line that should not be printed after the fix.

## Queued
- [ ] blocked-followup - Follow compact startup blocked-by: compact-startup - waits for implementation (repo: firstmate) (kind: scout) (since 2026-07-15)
  QUEUED-BODY-LINE this is another long multiline note.
- [ ] held-queued - Held queued work (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain)
EOF
  while [ "$i" -le 25 ]; do
    printf -- '- [ ] plain-%s - Plain queued item %s (repo: firstmate) (kind: ship)\n' "$i" "$i" >> "$path"
    i=$((i + 1))
  done
  cat >> "$path" <<'EOF'

## Done
- [x] landed-earlier - DONE-ROW-LINE already landed and torn down (repo: firstmate) (kind: ship)
EOF
}

test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata() {
  local rec root home fakebin out log
  rec=$(new_world backlog-compact-tasks-axi)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  mkdir -p "$home/projects/firstmate"
  printf 'window=fm-sess:compact\nworktree=%s\nproject=firstmate\nkind=ship\n' "$home/projects/firstmate" \
    > "$home/state/compact-startup.meta"
  log="$home/tasks-axi.log"

  out=$(FM_FAKE_TASKS_AXI_LOG="$log" FM_FAKE_TASKS_AXI_READY=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "backlog summary (tasks-axi; done rows omitted; held rows in full; blocked and ready queued bounded to 10; task bodies omitted)" \
    "compatible tasks-axi backend did not render the backlog summary"
  assert_contains "$out" "counts: in flight 1, held 1 (in-flight items included), blocked queued 1, ready queued 3" \
    "the backlog summary did not count every group"
  assert_contains "$out" "tasks[1]{id,state,kind,repo,title,blocked_by,hold_kind,hold_reason}:" \
    "tasks-axi compact listing omitted the expected structured field header"
  assert_not_contains "$out" "compact-startup,in_flight" \
    "the backlog summary listed an in-flight row whose task already has its own work-under-way line"
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "tasks-axi compact listing omitted a held row or its hold metadata"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "tasks-axi compact listing omitted blocked-by metadata"
  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "tasks-axi compact listing omitted a dispatchable queued row inside the bound"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "tasks-axi compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "tasks-axi compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "tasks-axi compact digest listed a done row at startup"
  assert_contains "$out" "compact-startup [ship] endpoint: " "the in-flight task lost its work-under-way line"
  assert_not_contains "$out" "worktree=$home/projects/firstmate" "the startup digest printed a meta body"
  assert_contains "$out" "Full task bodies remain available on demand: bin/fm-tasks-axi.sh show <id> --full" \
    "compact digest omitted the full-body lookup pointer"
  assert_contains "$out" "ready_public_followups: 0 delivery-ready obligations" \
    "the composed listing dropped a real signal from the dispatchable set"
  # One section pointer, not one repeated help block per composed group.
  assert_not_contains "$out" "help[1]:" \
    "the composed listing repeated tasks-axi's per-group help block"

  # The fake refuses a body field, an unfiltered listing, and a done listing, so
  # a clean render already proves those were never asked for; pin the group
  # filters the listing is built from.
  assert_grep "--state in_flight --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the in-flight group"
  assert_grep "--state held --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the held group"
  assert_grep "--state queued --blocked --fields blocked_by,hold_kind,hold_reason" "$log" \
    "session start did not ask tasks-axi for the blocked queued group"
  assert_grep "ready --file $home/data/backlog.md" "$log" \
    "session start did not ask tasks-axi for the dispatchable queued set"

  pass "compatible tasks-axi backlog rendering drops done rows and keeps every in-flight, held, and blocked row"
}

# The bound may only ever cut the dispatchable-now listing, and whatever it cuts
# must be disclosed with an exact count and the command that shows the rest.
test_backlog_queued_bound_discloses_its_remainder() {
  local rec root home fakebin out
  rec=$(new_world backlog-queued-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_FAKE_TASKS_AXI_READY=7 FM_SESSION_START_QUEUED_LIMIT=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "ready-3,queued,ship,firstmate,Ready item 3" \
    "the queued bound dropped a row inside its own limit"
  assert_not_contains "$out" "ready-4,queued" "the queued bound did not actually bound the ready listing"
  assert_contains "$out" "(shown 3 of 7 ready queued item(s); 4 more - bin/fm-tasks-axi.sh ready)" \
    "the bounded queued listing did not disclose what it showed, an exact remainder, and how to see it"

  # The bound is for dispatchable work only: held and blocked rows stay whole.
  assert_contains "$out" "held-queued,queued,ship,firstmate,Held queued work,none,captain,captain choice pending" \
    "the queued bound swallowed a held row"
  assert_contains "$out" 'blocked-followup,queued,scout,firstmate,Follow compact startup,compact-startup,"-","-"' \
    "the queued bound swallowed a blocked row"
  assert_contains "$out" "$(printf 'in flight with no state/*.meta record:\n  compact-startup,in_flight,ship,firstmate,Compact startup digest,none,captain,captain choice pending')" \
    "an in-flight row with no worker record was not listed"

  pass "the ready queue bound cuts only ready rows and discloses the remainder exactly"
}

test_backlog_blocked_bound_discloses_its_remainder_and_never_bounds_held() {
  local rec root home fakebin out
  rec=$(new_world backlog-blocked-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_FAKE_TASKS_AXI_BLOCKED=5 FM_FAKE_TASKS_AXI_HELD=5 FM_SESSION_START_QUEUED_LIMIT=3 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "blocked-3,queued,ship" "the blocked bound dropped a row inside its own limit"
  assert_not_contains "$out" "blocked-4,queued" "the blocked bound did not bound the blocked listing"
  assert_contains "$out" "(shown 3 of 5 blocked queued item(s); 2 more - bin/fm-tasks-axi.sh list --state queued --blocked)" \
    "the blocked bound did not disclose what it showed, an exact remainder, and how to see it"
  assert_contains "$out" "held-5,queued,ship,firstmate,Held item 5,none,captain,pick one" \
    "the bound cut a held row, which is a decision waiting on the captain"

  pass "the blocked queue bound discloses its remainder while held rows stay whole"
}

# The captain's tier pick: P0 website; P1 ru-compliance and checks; P2 tui-dash
# and the other tools; P3 career and the other personal projects; anything
# unnamed after P3. Ordering must happen before the bound, or the bound cuts the
# P0 row tasks-axi happened to list last.
ready_ids() {  # reads a digest on stdin
  awk '/^ready\[/ { rows = 1; next } rows && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); sub(/,.*/, ""); print; next } { rows = 0 }' \
    | paste -sd' ' -
}

test_backlog_ready_queued_orders_by_project_tier() {
  local rec root home fakebin out rows ready
  rec=$(new_world backlog-ready-tiers)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  rows=$(printf '%s\n' 'career-1,queued,ship,career,Career' 'mystery-1,queued,ship,mystery,Untiered' \
    'tui-1,queued,ship,tui-dash,First tui' 'checks-1,queued,ship,checks,Checks' \
    'tui-2,queued,ship,tui-dash,Second tui' 'ru-1,queued,ship,ru-compliance,Ru' \
    'none-1,queued,ship,"-",No project' 'web-1,queued,ship,website,Website')
  printf '%s\n' '# fleet speed tiers' 'website P0' 'ru-compliance P1' 'checks P1' \
    'tui-dash P2' 'orc P2' 'skills P2' 'dotfiles P2' 'firstmate P2' \
    'no-mistakes P2' 'pi-claude-bridge P2' 'home-vpn P2' \
    'career P3' 'learning P3' 'socials P3' 'decisions P3' 'clauth P3' \
    > "$home/config/project-tiers"

  out=$(FM_FAKE_TASKS_AXI_READY_ROWS=$rows FM_SESSION_START_QUEUED_LIMIT=5 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  ready=$(printf '%s\n' "$out" | ready_ids)
  assert_equals "web-1 checks-1 ru-1 tui-1 tui-2" "$ready" \
    "the digest did not list ready work P0, P1, P2 first in tasks-axi order within a tier, before its bound"
  assert_contains "$out" "(higher project tier first, per $home/config/project-tiers)" \
    "the digest did not say its ready listing follows the tier file"
  assert_contains "$out" "(shown 5 of 8 ready queued item(s);" "the tier order changed the bound's count"

  out=$(FM_FAKE_TASKS_AXI_READY_ROWS=$rows \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  ready=$(printf '%s\n' "$out" | ready_ids)
  assert_equals "web-1 checks-1 ru-1 tui-1 tui-2 career-1 mystery-1 none-1" "$ready" \
    "untiered ready work did not sort after P3"

  printf 'website P0\nwebsite\n' > "$home/config/project-tiers"
  out=$(FM_FAKE_TASKS_AXI_READY_ROWS=$rows \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "project tiers not applied: $home/config/project-tiers line 2 is not '<project-name> P0|P1|P2|P3'" \
    "the digest did not report the malformed tier line"
  ready=$(printf '%s\n' "$out" | ready_ids)
  assert_equals "career-1 mystery-1 tui-1 checks-1 tui-2 ru-1 none-1 web-1" "$ready" \
    "a malformed tier file still reordered the ready listing"

  rm "$home/config/project-tiers"
  out=$(FM_FAKE_TASKS_AXI_READY_ROWS=$rows \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_not_contains "$out" "higher project tier first" "with no tier file the digest still claimed a tier order"
  pass "the startup ready listing puts higher project tiers first before its bound and reports a malformed tier file"
}

test_backlog_compact_manual_backend_skips_indented_bodies() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-manual)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(FM_SESSION_START_QUEUED_LIMIT=4 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (manual backend; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to 4; indented task bodies omitted)" \
    "manual backend did not use compact title-line rendering"
  assert_contains "$out" "## In flight" "manual compact rendering omitted the in-flight section heading"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "manual compact rendering omitted the in-flight title line"
  assert_contains "$out" "(hold: captain choice pending) (hold-kind: captain)" \
    "manual compact rendering omitted hold metadata"
  assert_contains "$out" "blocked-by: compact-startup - waits for implementation" \
    "manual compact rendering omitted blocker metadata"
  assert_contains "$out" "- [ ] held-queued - Held queued work" \
    "manual compact rendering dropped a held queued title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "manual compact digest leaked an in-flight task body"
  assert_not_contains "$out" "QUEUED-BODY-LINE" "manual compact digest leaked a queued task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "manual compact digest listed a done row at startup"
  assert_not_contains "$out" "## Done" "manual compact digest printed the done heading it never fills"
  assert_contains "$out" "- [ ] plain-4 - Plain queued item 4" \
    "manual compact rendering dropped a queued title line inside its bound"
  assert_not_contains "$out" "- [ ] plain-5 - Plain queued item 5" \
    "manual compact rendering did not bound its plain queued listing"
  assert_contains "$out" "(shown 1 in-flight, 2 held or blocked queued, 4 of 25 other queued title line(s); 1 done row(s) omitted)" \
    "manual compact rendering did not report its bound accounting"
  assert_contains "$out" "(21 more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)" \
    "manual compact rendering did not disclose an exact queued remainder"
  assert_contains "$out" "or data/backlog.md" "manual compact digest omitted the data/backlog.md full-body pointer"

  pass "manual backlog rendering drops done rows, keeps every held or blocked title line, and bounds the rest"
}

test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback() {
  local rec root home fakebin out
  rec=$(new_world backlog-compact-unavailable)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  assert_contains "$out" "compact backlog listing (tasks-axi unavailable or incompatible; done rows omitted;" \
    "unavailable tasks-axi did not fall back to compact title-line rendering"
  assert_contains "$out" "- [ ] compact-startup - Compact startup digest" \
    "unavailable tasks-axi fallback omitted a backlog title line"
  assert_not_contains "$out" "OVERSIZED-BODY-LINE" "unavailable tasks-axi fallback leaked an in-flight task body"
  assert_not_contains "$out" "DONE-ROW-LINE" "unavailable tasks-axi fallback listed a done row at startup"

  pass "unavailable or incompatible tasks-axi falls back to compact manual backlog rendering"
}

# --- runtime bound -----------------------------------------------------------
#
# The digest runs on a session-open hook that blocks session initialization, so
# it must have a guaranteed upper bound. These cases drive REAL processes that
# really hang, and assert the outcome the hook depends on: whatever the digest
# already emitted survives, the agent is told exactly what it never saw, and
# the command still exits 0 so the session can open.

# make_hanging_tool <fakebin> <name>: a real, unkillable-by-timeout-alone
# subprocess of the digest. `git` is the honest choice - the bootstrap stage
# shells out to it - and it also proves the bound reaches a GRANDCHILD, because
# bootstrap runs it inside its own command substitution.
make_hanging_tool() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 600
SH
  chmod +x "$fakebin/$name"
}

make_term_escalating_timeout() {
  local fakebin=$1
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env perl
use strict;
use warnings;
(shift @ARGV) eq '-k' or exit 64;
my $kill_after = shift @ARGV;
my $seconds = shift @ARGV;
my $pid = fork;
defined $pid or die "fork failed";
if (!$pid) {
  setpgrp(0, 0);
  exec @ARGV;
}
local $SIG{ALRM} = sub {
  kill 'TERM', -$pid;
  select undef, undef, undef, $kill_after;
  kill 'KILL', -$pid;
  waitpid $pid, 0;
  exit 137;
};
alarm $seconds;
waitpid $pid, 0;
alarm 0;
exit($? >> 8);
SH
  chmod +x "$fakebin/timeout"
}

test_runtime_bound_truncates_loudly_and_exits_zero() {
  local rec root home fakebin out status=0 stray mechanism
  rec=$(new_world runtime-bound)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_hanging_tool "$fakebin" git

  mechanism=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash bash -c '. "$1"; fm_timeout_mechanism' \
    _ "$ROOT/bin/fm-timeout-lib.sh")
  [ "$mechanism" = bash ] || fail "the forced pure-Bash timeout fixture selected '$mechanism'"

  out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_SESSION_START_TIMEOUT=3 FM_STARTUP_NETWORK_TIMEOUT=2 \
    run_session_start "$home" "$root" "$fakebin:$BASE_PATH") || status=$?

  expect_code 0 "$status" "a truncated session start must still exit 0 so the session can open"
  assert_contains "$out" "SESSION START - $home" "the truncated digest lost the output it had already produced"
  assert_contains "$out" "LOCK" "the truncated digest lost a stage that had completed"
  assert_contains "$out" "STARTUP TRUNCATED - SESSION START HIT ITS" "a truncated session start did not say so"
  assert_contains "$out" "RUNTIME BOUND" "the truncation banner did not name the bound it hit"
  assert_contains "$out" 'stopped during the "bootstrap" stage' "the truncation banner did not name the incomplete stage"
  assert_contains "$out" "RECONCILE these stages" "the truncation banner did not tell the agent what to reconcile"
  assert_contains "$out" "wake-queue supervision-instructions read-once fleet-state network-checks context next-step" \
    "the truncation banner did not list every stage that never ran"
  assert_not_contains "$out" "NEXT STEP" "a truncated digest claimed to have reached its closing reminder"
  assert_absent "$home/state/.session-start-complete" \
    "a truncated startup recorded itself as complete"

  # The bound must reach the whole process group: a hung grandchild that
  # outlives the digest would keep holding whatever the digest was waiting on.
  # There are now TWO bounds, deliberately independent - the digest's, and the
  # deferred network stage's own - because a truncated digest must not kill work
  # it was never waiting for. So the guarantee asserted here is the one that
  # actually matters: once BOTH deadlines have passed, nothing hung is left.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STARTUP_NETWORK_TIMEOUT=2 \
    "$ROOT/bin/fm-startup-network.sh" wait 30 >/dev/null || true
  sleep 1
  stray=$(pgrep -f "$fakebin/git" 2>/dev/null | wc -l | tr -d ' ')
  [ "$stray" -eq 0 ] || fail "the runtime bound left $stray hung subprocess(es) behind"

  status=0
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash bash -c \
    '. "$1"; fm_run_timed 2 bash -c "exit 137"' _ "$ROOT/bin/fm-timeout-lib.sh" || status=$?
  expect_code 137 "$status" "pure-Bash natural command exit 137"

  pass "the pure-Bash watchdog bounds session start, kills its hung grandchild, and emits the truncation contract"
}

test_portable_timeout_escalates_term_resistant_process() {
  local fakebin="$TMP_ROOT/portable-kill-after" driver status=0
  mkdir -p "$fakebin"
  make_term_escalating_timeout "$fakebin"
  driver="$TMP_ROOT/portable-kill-after-driver.sh"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
. "$1"
shift
fm_run_timed 1 "$@"
SH
  chmod +x "$driver"

  perl -e '
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV }
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 99 };
    alarm 5;
    waitpid $pid, 0;
    exit($? >> 8);
  ' env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    perl -e '$SIG{TERM} = "IGNORE"; sleep 600' || status=$?

  expect_code 124 "$status" "portable timeout TERM-resistant escalation"
  status=0
  env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    bash -c 'exit 137' || status=$?
  expect_code 137 "$status" "natural command exit 137"
  pass "the portable timeout path force-kills a command that ignores TERM"
}

test_runtime_bound_leaves_a_healthy_digest_untouched() {
  local rec root home fakebin out
  rec=$(new_world runtime-bound-healthy)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  # The banner line itself, not the phrase: the read-once contract names the
  # banner as the condition that voids it, and that mention is not a banner.
  assert_not_contains "$out" "STARTUP TRUNCATED - SESSION START HIT ITS" \
    "a digest that finished in time reported itself truncated"
  assert_contains "$out" "NEXT STEP" "a digest that finished in time lost its closing reminder"
  assert_absent "${TMPDIR:-/tmp}/fm-session-start-stage" "the stage breadcrumb leaked a fixed-name file"

  pass "a session start inside its budget prints no truncation banner"
}

test_runtime_bound_leaves_harness_ancestry_headroom() {
  local rec root home fakebin nest out
  rec=$(new_world runtime-bound-ancestry)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  # Only ONE pid in the whole tree is the harness, and it sits at the very top.
  # fm-session-lock-lib.sh walks a BOUNDED sixteen parents to find it, and the
  # runtime bound spends some of that budget on its own wrapper processes, so
  # this pins that the budget still reaches a realistically deep session.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' /usr/local/bin/claude
    else printf '%s\n' /bin/bash; fi
    ;;
  *"args="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' claude
    else printf '%s\n' bash; fi
    ;;
  *"ppid="*) /bin/ps -o ppid= -p "$pid" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Each level forks rather than execs, so the counter really is process depth.
  nest="$home/nest.sh"
  cat > "$nest" <<'SH'
#!/usr/bin/env bash
set -u
levels=$1
shift
if [ "$levels" -gt 0 ]; then
  bash "$0" $((levels - 1)) "$@"
  exit $?
fi
exec "$@"
SH
  chmod +x "$nest"

  # shellcheck disable=SC2016 # $$ must expand in the launched shell, not here.
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    bash -c 'export FM_FAKE_HARNESS_PID=$$; exec "$1" 8 "$2"' _ "$nest" "$SESSION_START")

  assert_contains "$out" "lock acquired: harness pid" \
    "the runtime bound's wrapper processes pushed the harness out of the bounded ancestry walk"
  assert_not_contains "$out" "READ-ONLY SESSION" \
    "a session start eight shells below its harness was wrongly refused the lock"

  pass "the runtime bound leaves enough ancestry headroom for a deeply nested session to take the lock"
}

# --- context re-emit (--reemit) ----------------------------------------------

test_reemit_cue_survives_the_hook_output_preview() {
  local rec root home fakebin reemit normal head2k
  rec=$(new_world reemit-cue)
  IFS='|' read -r root home fakebin <<FIXTURE
$rec
FIXTURE
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  mkdir -p "$home/data"
  awk 'BEGIN { for (i = 0; i < 400; i++) printf "preference line %04d padding padding padding\n", i }' > "$home/data/captain.md"
  local i
  for i in $(seq 1 80); do
    printf 'window=sess:p-%s\nkind=ship\nbackend=herdr\n' "$i" > "$home/state/task-$i.meta"
    printf 'working: step %s of the long-running fixture task with padding padding\n' "$i" > "$home/state/task-$i.status"
  done

  normal=$(FM_FAKE_HARNESS_PID=$$ run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_not_contains "$normal" "RE-EMIT CUE" "a normal start printed the re-emit cue"

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)
  [ "${#reemit}" -gt 10000 ] || fail "re-emit fixture did not exceed the hook output limit"
  head2k=$(printf '%s' "$reemit" | head -c 2000)
  assert_contains "$head2k" "RE-EMIT CUE" "the re-emit cue is not inside the first 2000 characters"
  assert_contains "$head2k" "Full output saved to" "the re-emit cue does not point at the saved output"

  pass "--reemit puts its read cue in the first 2000 characters and a normal start omits it"
}

test_reemit_skips_startup_sweeps_but_keeps_the_wake_drain() {
  local rec root home fakebin network_status reemit_status reemit sequence generation
  rec=$(new_world reemit)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  append_wake "$home/state" signal task-r "done: queued after startup" || fail "seed wake failed"

  FM_FAKE_HARNESS_PID=$$ run_session_start "$home" "$root" "$fakebin:$BASE_PATH" >/dev/null
  wait_for_network_stage "$home" "$root" \
    || fail "the full startup fixture's deferred network stage never published"
  network_status=$(cat "$home/state/.startup-network.status") \
    || fail "the full startup fixture recorded no deferred sweep run"
  assert_contains "$network_status" "phases=probe,sweeps" \
    "the full startup fixture did not run the mutating sweeps"

  append_wake "$home/state" signal task-r "done: queued after the re-emit too" || fail "seed second wake failed"
  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)

  assert_contains "$reemit" "SESSION START (CONTEXT RE-EMIT) - $home" "--reemit did not label itself"
  reemit_status=$(cat "$home/state/.startup-network.status")
  if [ "$reemit_status" != "$network_status" ]; then
    case $(printf '%s\n' "$reemit_status" | sed -n 's/^phases=//p' | tail -1) in
      probe) ;;
      *) fail "--reemit started another run of the sweeps startup already ran" ;;
    esac
  fi
  assert_contains "$reemit" "done: queued after the re-emit too" "--reemit did not drain the wake queue"
  [ -s "$home/state/.wake-queue" ] || fail "--reemit removed the wake before its handling acknowledgement"
  sequence=$(printf '%s\n' "$reemit" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' | tail -1)
  generation=$(printf '%s\n' "$reemit" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "--reemit omitted the generation-bound wake acknowledgement"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" || fail "--reemit wake acknowledgement failed"
  [ ! -s "$home/state/.wake-queue" ] || fail "--reemit acknowledgement left queued wakes behind"
  assert_contains "$reemit" "CONTEXT" "--reemit dropped the context digest"
  assert_contains "$reemit" "FLEET STATE" "--reemit dropped the fleet-state digest"
  assert_contains "$reemit" "NEXT STEP" "--reemit dropped the closing reminder"

  pass "--reemit reprints the digest without repeating startup's mutating sweeps and still drains queued wakes"
}

test_reemit_context_manifest_names_every_source_without_bodies() {
  local rec root home fakebin startup reemit
  rec=$(new_world reemit-manifest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' 'REEMIT_MANIFEST_CAPTAIN_CANARY=present' > "$home/data/captain.md"
  printf '%s\n' 'REEMIT_MANIFEST_LEARNINGS_CANARY=present' > "$home/data/learnings.md"
  : > "$home/data/projects.md"

  startup=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$startup" "REEMIT_MANIFEST_CAPTAIN_CANARY=present" "true startup did not print the captain body"

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)
  assert_contains "$reemit" "data/captain.md" "--reemit dropped the captain source label"
  assert_contains "$reemit" "data/learnings.md" "--reemit dropped the learnings source label"
  assert_contains "$reemit" "data/projects.md" "--reemit dropped the projects source label"
  assert_contains "$reemit" "sha256:" "--reemit manifest names no hash the model could verify"
  assert_contains "$reemit" "(present, empty)" "--reemit lost the empty-but-present distinction"
  assert_contains "$reemit" "only when this turn needs its content" "--reemit cue does not scope the manifest follow-up reads"
  assert_not_contains "$reemit" "REEMIT_MANIFEST_CAPTAIN_CANARY=present" "--reemit reprinted a context body it should manifest"
  assert_not_contains "$reemit" "REEMIT_MANIFEST_LEARNINGS_CANARY=present" "--reemit reprinted a context body it should manifest"

  pass "--reemit manifests every context source by size and hash instead of reprinting bodies"
}

test_startup_and_reemit_share_the_ten_row_queued_bound_and_one_status_line() {
  local rec root home fakebin output mode explicit
  rec=$(new_world reemit-bounds)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  printf '%s\n' '# Backlog' > "$home/data/backlog.md"
  printf 'line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\n' > "$home/state/orphan-a.status"

  for mode in startup reemit; do
    if [ "$mode" = startup ]; then
      output=$(FM_FAKE_TASKS_AXI_READY=12 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
    else
      output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
        env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
        FM_FAKE_TASKS_AXI_READY=12 "$SESSION_START" --reemit)
    fi
    assert_contains "$output" "orphan-a ($home/state/orphan-a.status) - latest: line 7" "$mode dropped the orphan log's latest line"
    assert_not_contains "$output" "line 6" "$mode printed an older status line"
    assert_contains "$output" "ready-10,queued" "$mode queued bound (10) dropped a row it should keep"
    assert_not_contains "$output" "ready-11,queued" "$mode queued bound (10) leaked a row past its limit"
    assert_contains "$output" "(shown 10 of 12 ready queued item(s);" "$mode queued bound did not disclose what it showed"
  done

  explicit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_FAKE_TASKS_AXI_READY=12 FM_SESSION_START_QUEUED_LIMIT=12 "$SESSION_START" --reemit)
  assert_contains "$explicit" "ready-12,queued" "an explicit queued limit did not win over the default"

  pass "startup and --reemit both bound queued rows to 10 and print one status line, while an explicit limit wins"
}

test_reemit_fleet_state_lists_open_work_and_one_line_per_task() {
  local rec root home fakebin startup reemit long_line
  rec=$(new_world reemit-fleet-summary)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  make_fake_tasks_axi_compact "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  printf 'window=fm-sess:compact\nkind=ship\nmode=no-mistakes\nMETA-BODY-CANARY=1\n' > "$home/state/compact-startup.meta"
  printf 'working: OLDER-STATUS-LINE\npaused [at=1]: LATEST-STATUS-LINE | owner=firstmate | recheck=2026-01-01\n\n' \
    > "$home/state/compact-startup.status"
  printf 'window=fm-sess:scout\nkind=scout\n' > "$home/state/long-scout.meta"
  awk 'BEGIN { printf "working: "; for (i = 0; i < 400; i++) printf "x"; printf "\n" }' > "$home/state/long-scout.status"

  startup=$(FM_FAKE_TASKS_AXI_READY=3 run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$startup" "held-queued,queued,ship,firstmate,Held queued work" "true startup dropped a held row"
  assert_contains "$startup" "blocked-followup,queued,scout,firstmate" "true startup dropped a blocked row"
  assert_not_contains "$startup" "META-BODY-CANARY=1" "true startup printed the meta body"
  assert_not_contains "$startup" "OLDER-STATUS-LINE" "true startup printed an older status line"
  assert_contains "$startup" "- latest: paused [at=1]: LATEST-STATUS-LINE | owner=firstmate | recheck=2026-01-01" \
    "true startup dropped the task's latest status line"

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_FAKE_TASKS_AXI_READY=3 "$SESSION_START" --reemit)
  assert_contains "$reemit" "counts: in flight 2, held 1 (in-flight items included), blocked queued 1" \
    "re-emit did not count the backlog groups"
  assert_contains "$reemit" 'open-work,in_flight,ship,firstmate,"Open work, not held"' \
    "re-emit dropped an in-flight row that is not held"
  assert_not_contains "$reemit" "compact-startup,in_flight" "re-emit listed a held in-flight row"
  assert_not_contains "$reemit" "held-queued" "re-emit listed a held queued row"
  assert_not_contains "$reemit" "blocked-followup" "re-emit listed a blocked queued row"
  assert_contains "$reemit" "ready-3,queued,ship,firstmate,Ready item 3" "re-emit dropped the ready queue"
  assert_contains "$reemit" "compact-startup [ship no-mistakes]: paused [at=1]: LATEST-STATUS-LINE | owner=firstmate | recheck=2026-01-01" \
    "re-emit did not print one line with the task's kind, mode, and last status line"
  assert_not_contains "$reemit" "OLDER-STATUS-LINE" "re-emit printed more than the last status line"
  assert_not_contains "$reemit" "META-BODY-CANARY=1" "re-emit printed the full meta body"
  assert_not_contains "$reemit" "endpoint:" "re-emit still probed every task endpoint"
  long_line=$(printf '%s\n' "$reemit" | grep '^long-scout \[scout\]: working: x')
  [ -n "$long_line" ] || fail "re-emit dropped the line for a task without a delivery mode"
  [ "${#long_line}" -le 220 ] || fail "re-emit did not cap a long task line: ${#long_line} characters"
  assert_contains "$reemit" "but not held or" "the read-once contract does not say re-emit omits held and blocked rows"

  pass "--reemit lists counts, open in-flight rows, the ready queue, and one capped line per task while a true startup also lists held and blocked rows"
}

test_reemit_manual_backlog_counts_held_and_blocked_lines() {
  local rec root home fakebin reemit
  rec=$(new_world reemit-manual-backlog)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  write_long_body_backlog "$home/data/backlog.md"
  printf '%s\n' manual > "$home/config/backlog-backend"

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)
  assert_contains "$reemit" "(counts: 1 in-flight, 1 of them held or blocked and not listed; 2 held or blocked queued, not listed; shown 10 of 25 other queued title line(s); 1 done row(s) omitted)" \
    "manual re-emit did not count the held and blocked title lines"
  assert_not_contains "$reemit" "- [ ] compact-startup" "manual re-emit listed a held in-flight title line"
  assert_not_contains "$reemit" "held-queued" "manual re-emit listed a held queued title line"
  assert_not_contains "$reemit" "blocked-followup" "manual re-emit listed a blocked queued title line"
  assert_contains "$reemit" "plain-10 - Plain queued item 10" "manual re-emit dropped a plain queued line inside its bound"

  pass "--reemit on a manual backlog counts held and blocked title lines instead of listing them"
}

test_agents_baseline_stays_at_true_start_and_reemits_on_every_drifted_pi_compact() {
  local rec root home fakebin startup compact_equal compact_first compact_second clear_out resume_out reset_out baseline baseline_after expected_hash refresh_line bootstrap_line
  rec=$(new_world agents-refresh)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  cat > "$root/AGENTS.md" <<'EOF'
FIRSTMATE_TEST_INSTRUCTION=original
Keep this original instruction.
EOF

  startup=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup)
  assert_contains "$startup" "SESSION START - $home" "true startup did not run the full digest"
  assert_present "$home/state/.session-start-agents-baseline" "true startup did not record an AGENTS baseline"
  baseline=$(cat "$home/state/.session-start-agents-baseline")
  expected_hash=$(hash_file_for_test "$root/AGENTS.md")
  [ "$(printf '%s\n' "$baseline" | sed -n '2p')" = "$expected_hash" ] \
    || fail "true startup baseline did not record the original AGENTS hash: $baseline"

  compact_equal=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_not_contains "$compact_equal" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "an unchanged AGENTS file was unnecessarily re-emitted"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a no-drift compact rewrote the true-start baseline"

  cat > "$root/AGENTS.md" <<'EOF'
FIRSTMATE_TEST_INSTRUCTION=updated
The complete updated instruction must survive every stale rebuild.
EOF
  resume_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source resume)
  assert_not_contains "$resume_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a context-preserving continuation emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a context-preserving continuation rebased the true-start baseline"

  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a drifted Pi compact did not emit the replacement instructions"
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a drifted Pi compact did not emit the complete current AGENTS content"
  refresh_line=$(printf '%s\n' "$compact_first" | grep -n '^CURRENT AGENTS.md - INSTRUCTION REFRESH$' | head -1 | cut -d: -f1)
  bootstrap_line=$(printf '%s\n' "$compact_first" | grep -n '^BOOTSTRAP$' | head -1 | cut -d: -f1)
  [ -n "$refresh_line" ] && [ -n "$bootstrap_line" ] && [ "$refresh_line" -lt "$bootstrap_line" ] \
    || fail "replacement instructions were not emitted before the bulky digest"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a drifted compact rebased the original-session baseline"

  compact_second=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_second" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a second drifted compact suppressed the required replacement instructions"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a repeated compact rebased the original-session baseline"

  clear_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source clear)
  assert_not_contains "$clear_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "a Pi clear, which creates a fresh runtime, unnecessarily emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "a clear rebuild rebased the original-session baseline"

  reset_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source reset)
  assert_not_contains "$reset_out" "CURRENT AGENTS.md - INSTRUCTION REFRESH" \
    "an unrecognized reset source emitted a replacement contract"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] \
    || fail "reset rebased the original-session baseline"

  rm -f "$home/state/.session-start-agents-baseline"
  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a missing baseline did not trigger first-post-fix replacement instructions"
  assert_absent "$home/state/.session-start-agents-baseline" \
    "a rebuild fabricated a baseline instead of preserving true-start-only ownership"

  printf 'wrong-session\n%s\n' "$(hash_file_for_test "$root/AGENTS.md")" > "$home/state/.session-start-agents-baseline"
  compact_first=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_first" "FIRSTMATE_TEST_INSTRUCTION=updated" \
    "a wrong-session baseline did not trigger replacement instructions"
  baseline_after=$(cat "$home/state/.session-start-agents-baseline")
  [ "$baseline_after" = "wrong-session
$(hash_file_for_test "$root/AGENTS.md")" ] \
    || fail "a wrong-session baseline was rewritten during a rebuild"

  pass "true-start AGENTS baselines stay immutable while every drifted Pi compact re-emits the current contract"
}

test_read_only_pi_compact_refreshes_against_its_own_session_identity() {
  local rec root home fakebin holder_pid out baseline_before completion_before
  rec=$(new_world agents-refresh-read-only)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  printf '%s\n' 'READ_ONLY_AGENTS=current' > "$root/AGENTS.md"
  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null

  sleep 300 &
  holder_pid=$!
  printf '%s\n%s\n' "$holder_pid" "$(hash_file_for_test "$root/AGENTS.md")" \
    > "$home/state/.session-start-agents-baseline"
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  baseline_before=$(cat "$home/state/.session-start-agents-baseline")
  completion_before=$(cat "$home/state/.session-start-complete")

  out=$(FM_FAKE_HARNESS=pi FM_FAKE_LIVE_HOLDER_PID="$holder_pid" \
    run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "READ-ONLY SESSION" "competing live lock owner did not force read-only mode"
  assert_contains "$out" "READ_ONLY_AGENTS=current" \
    "read-only compact trusted another session's equal baseline"
  [ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline_before" ] \
    || fail "read-only compact mutated the competing session's baseline"
  [ "$(cat "$home/state/.session-start-complete")" = "$completion_before" ] \
    || fail "read-only compact mutated startup completion state"

  pass "read-only Pi compact refreshes against the rebuilding session identity without mutation"
}

test_agents_baseline_requires_sha256_and_successful_completion() {
  local rec root home fakebin compact_out
  rec=$(new_world agents-baseline-failures)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi
  printf '%s\n' 'AGENTS_SHA_TEST=original' > "$root/AGENTS.md"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/shasum"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/sha256sum"
  chmod +x "$fakebin/shasum" "$fakebin/sha256sum"

  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null
  assert_absent "$home/state/.session-start-agents-baseline" \
    "startup recorded a non-SHA-256 instruction baseline when both SHA-256 tools failed"
  printf '%s\n' 'AGENTS_SHA_TEST=updated' > "$root/AGENTS.md"
  compact_out=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
  assert_contains "$compact_out" "AGENTS_SHA_TEST=updated" \
    "a missing SHA-256 baseline did not conservatively refresh a supported rebuild"

  rm -f "$fakebin/shasum" "$fakebin/sha256sum" "$home/state/.session-start-complete"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$home/state/.session-start-complete") exit 1 ;;
esac
exec /bin/mv "\$@"
SH
  chmod +x "$fakebin/mv"
  FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup >/dev/null
  assert_absent "$home/state/.session-start-complete" \
    "startup published completion despite the atomic completion write failure"
  assert_absent "$home/state/.session-start-agents-baseline" \
    "startup recorded an instruction baseline after completion publication failed"

  pass "instruction baselines require SHA-256 and successful startup completion"
}

test_reemit_keeps_repair_ownership_with_the_lock_holder() {
  local rec root home fakebin reemit readonly_out holder_pid
  rec=$(new_world reemit-tangle)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  git -C "$root" checkout -q -B fm/reemit-tangle

  reemit=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)

  # A re-emit skips the sweeps because it ALREADY ran them, not because it lacks
  # the lock, so it must still own repair rather than deferring to a lock holder.
  assert_contains "$reemit" "restore the primary with: git -C $root checkout main" \
    "--reemit disowned a repair it is entitled to perform"
  assert_not_contains "$reemit" "must leave restore work to the session holding the fleet lock" \
    "--reemit misreported itself as an unlocked read-only session"

  rm -f "$home/state/.lock"
  sleep 300 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"
  readonly_out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$BASE_PATH" \
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    "$SESSION_START" --reemit)
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$readonly_out" "READ-ONLY SESSION" \
    "--reemit assumed lock ownership instead of re-verifying it"
  assert_contains "$readonly_out" "must leave restore work to the session holding the fleet lock" \
    "a lock-refused --reemit still claimed repair ownership"

  pass "--reemit re-verifies lock ownership and keeps repair ownership with whoever holds it"
}

# --- fleet-state digest: no in-flight tasks ----------------------------------

test_fleet_digest_empty_fleet() {
  local rec root home fakebin out
  rec=$(new_world empty-fleet)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"

  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "(none)" "empty fleet did not report (none) for in-flight tasks"

  pass "an empty fleet reports (none) for in-flight tasks"
}

test_supervision_block_exactly_one_and_pi_diagnostic() {
  local rec root home fakebin out block_count wake_line sup_line context_line
  rec=$(new_world pi-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")

  block_count=$(printf '%s\n' "$out" | grep -c '^SUPERVISION OPERATING INSTRUCTIONS - primary harness:')
  [ "$block_count" -eq 1 ] || fail "expected exactly one supervision block, got $block_count"
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi" "pi supervision block missing"
  assert_contains "$out" "Mode: Pi extension background wake." "pi snippet missing from session start"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi extension load diagnostic missing"
  assert_contains "$out" "restart plain pi so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" "pi extension load diagnostic omits the turn-end guard extension"

  wake_line=$(printf '%s\n' "$out" | grep -n '^WAKE QUEUE$' | head -1 | cut -d: -f1)
  sup_line=$(printf '%s\n' "$out" | grep -n '^SUPERVISION OPERATING INSTRUCTIONS' | head -1 | cut -d: -f1)
  context_line=$(printf '%s\n' "$out" | grep -n '^CONTEXT$' | head -1 | cut -d: -f1)
  [ "$wake_line" -lt "$sup_line" ] || fail "supervision block did not follow wake queue"
  [ "$sup_line" -lt "$context_line" ] || fail "supervision block did not precede context"

  pass "session start emits exactly one detected harness block and reports Pi extension load state"
}

test_pi_signed_primary_uses_pi_extensions_without_identity_normalization() {
  local rec root home fakebin out
  rec=$(new_world pi-signed-supervision-block)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_harness "$fakebin" pi-signed

  out=$(FM_FAKE_HARNESS=pi-signed run_session_start "$home" "$root" "$fakebin:$BASE_PATH" pi-signed)

  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi-signed" \
    "session start normalized a pi-signed primary to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed primary did not reuse Pi's supervision protocol"
  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" \
    "pi-signed primary skipped Pi extension validation"
  assert_contains "$out" "restart pi-signed so $root/.pi/extensions/fm-primary-turnend-guard.ts and $root/.pi/extensions/fm-primary-pi-watch.ts auto-load" \
    "pi-signed extension diagnostic did not preserve the executable identity"

  pass "session start preserves pi-signed primary identity while applying Pi extension guarantees"
}

test_pi_diagnostic_rejects_stale_loaded_marker() {
  local rec root home fakebin out marker holder_pid
  rec=$(new_world pi-stale-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  printf 'stale-extension-version\n%s\n' "$holder_pid" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"
  touch -t 203001010000 "$marker" 2>/dev/null || touch "$marker"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a stale loaded marker"

  pass "session start rejects stale Pi loaded markers"
}

test_pi_diagnostic_rejects_handoff_generation_marker() {
  local rec root home fakebin out marker holder_pid
  rec=$(new_world pi-handoff-generation-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  write_pi_loaded_markers "$home" "$root" "$holder_pid"
  marker="$home/state/.pi-watch-extension-loaded"
  head -n 2 "$marker" > "$marker.tmp"
  printf 'generation=1 phase=handoff\n' >> "$marker.tmp"
  mv "$marker.tmp" "$marker"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" \
    "pi diagnostic trusted a handoff marker left by an absent replacement extension"

  pass "session start rejects a Pi watcher generation left in handoff"
}

test_pi_diagnostic_accepts_prelock_loaded_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-prelock-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_loaded_markers "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_not_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic rejected a current pre-lock loaded marker"

  pass "session start accepts current Pi markers written before lock acquisition"
}

test_pi_diagnostic_rejects_missing_turnend_guard_marker() {
  local rec root home fakebin out holder_pid
  rec=$(new_world pi-missing-turnend-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"

  write_pi_watch_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a session without the turn-end guard extension"

  pass "session start rejects Pi sessions missing the turn-end guard marker"
}

test_pi_diagnostic_rejects_previous_session_loaded_marker() {
  local rec root home fakebin out marker version holder_pid
  rec=$(new_world pi-previous-session-loaded-marker)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"

  sleep 300 &
  holder_pid=$!
  make_fake_ps_pi_holder "$fakebin" "$holder_pid"
  install_pi_turnend_extension_fixture "$root"
  install_pi_watch_extension_fixture "$root"
  marker="$home/state/.pi-watch-extension-loaded"
  version=$(hash_file_for_test "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n999999\n' "$version" > "$marker"
  write_pi_turnend_loaded_marker "$home" "$root" "$holder_pid"

  out=$(FM_FAKE_HARNESS=pi run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  assert_contains "$out" "PI_WATCH_EXTENSION: not loaded" "pi diagnostic trusted a marker from a previous Pi process"

  pass "session start rejects Pi loaded markers from previous sessions"
}

test_startup_reports_configured_heavy_limit_instead_of_stale_value() {
  local rec root home fakebin out
  rec=$(new_world capacity-digest)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' '@heavy-limit 19' > "$home/config/project-capacity"
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "heavy worker limit: 19" "startup did not report the configured limit"
  printf '%s\n' '@heavy-limit 23' > "$home/config/project-capacity"
  out=$(run_session_start "$home" "$root" "$fakebin:$BASE_PATH")
  assert_contains "$out" "heavy worker limit: 23" "startup reported a stale limit"
  pass "startup reads the heavy limit from the machine configuration"
}

test_remote_startup_recovers_pending_worker_and_does_not_mark_it_dead() {
  local rec root home fakebin out
  rec=$(new_world remote-pending)
  IFS='|' read -r root home fakebin <<EOF
$rec
EOF
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  printf '%s\n' "- winexec - execution (host: testhost; root: $ROOT; home: /tmp/exechome; session: fm-remote; scope: workers; projects: alpha; added 2026-01-01)" > "$home/data/remote-homes.md"
  printf '%s\n' 'window=remote:task-a' 'endpoint_task_id=task-a' 'worktree=/tmp/exechome' 'project=/tmp/exechome/projects/alpha' 'kind=ship' 'harness=pi' 'spawn_gen=s1' 'remote_host=testhost' 'remote_route=winexec' "remote_root=$ROOT" 'remote_backend=herdr' 'remote_target=pending' > "$home/state/task-a.meta"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
encoded=${!#}
args=$(printf '%s' "$encoded" | base64 -d 2>/dev/null | tr '\\0' ' ')
case "$args" in
  *'fm-session-start.sh --heavy-limit'*) sleep 6; printf '%s\n' 'heavy worker limit: 4' ;;
  *'fm-remote-worker-control.sh route task-a'*) printf '%s\n' 'schema=fm-remote-worker-control.v1' 'backend=herdr' 'target=fm-remote:ws:pane' 'kind=ship' 'harness=pi' 'worktree=/tmp/task-a' 'project=/tmp/project' 'herdr_session=fm-remote' ;;
  *'fm-remote-worker-control.sh state task-a'*) printf '%s\n' alive ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ssh"
  out=$(FM_SSH_BIN="$fakebin/ssh" run_session_start "$home" "$ROOT" "$fakebin:$BASE_PATH")
  assert_contains "$out" 'winexec: heavy worker limit: 4' 'a six-second remote limit probe was rejected'
  assert_contains "$out" 'task-a [ship] endpoint: alive' 'a live pending remote worker was reported dead'
  assert_contains "$(cat "$home/state/task-a.meta")" 'remote_target=fm-remote:ws:pane' 'the recovered target was not published'
  assert_contains "$(cat "$home/state/task-a.meta")" 'worktree=/tmp/task-a' 'the recovered worktree was not published'
  pass "startup recovers a pending remote worker and accepts a slow healthy route"
}

test_remote_startup_recovers_pending_worker_and_does_not_mark_it_dead
test_startup_reports_configured_heavy_limit_instead_of_stale_value
test_context_digest_absent_empty_present
test_lock_refusal_read_only_path
test_lock_write_failure_read_only_path
test_trace_context_effective_state_is_frozen_after_lock
test_session_lock_concurrent_single_winner
test_output_ordering_diagnostics_lead
test_read_once_contract_is_stated_once_before_its_subject
test_herdr_backend_diagnostics_follow_real_session_start
test_inactive_reconcile_never_blocks_the_digest
test_unreachable_network_never_blocks_the_digest
test_deferred_result_reaches_the_agent_when_the_digest_cannot_print_it
test_read_only_session_declares_skipped_network_checks
test_tasks_axi_compatibility_is_probed_once
test_task_line_prints_latest_status_not_older_lines_or_meta_body
test_task_line_caps_status_and_keeps_endpoint_verdict
test_wake_queue_rows_capped_in_digest_whole_in_queue
test_session_start_reports_a_wake_older_than_one_cycle_as_a_watcher_failure
test_orphan_status_logs_are_printed
test_endpoint_liveness_herdr
test_endpoint_read_death_is_isolated_and_reported
test_endpoint_read_hang_is_bounded_and_reported
test_endpoint_bound_rejects_padded_zero
test_perl_timeout_fallback_reports_signal_death_nonzero
test_abnormal_digest_death_banners_and_exits_zero
test_composition_invokes_real_scripts
test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep
test_non_pi_session_start_leaves_branch_state_untouched
test_backlog_compact_tasks_axi_omits_bodies_and_keeps_metadata
test_backlog_queued_bound_discloses_its_remainder
test_backlog_blocked_bound_discloses_its_remainder_and_never_bounds_held
test_backlog_ready_queued_orders_by_project_tier
test_backlog_compact_manual_backend_skips_indented_bodies
test_backlog_compact_tasks_axi_unavailable_uses_manual_fallback
test_fleet_digest_empty_fleet
test_supervision_block_exactly_one_and_pi_diagnostic
test_pi_signed_primary_uses_pi_extensions_without_identity_normalization
test_pi_diagnostic_rejects_stale_loaded_marker
test_pi_diagnostic_rejects_handoff_generation_marker
test_pi_diagnostic_accepts_prelock_loaded_marker
test_pi_diagnostic_rejects_missing_turnend_guard_marker
test_pi_diagnostic_rejects_previous_session_loaded_marker
test_runtime_bound_truncates_loudly_and_exits_zero
test_portable_timeout_escalates_term_resistant_process
test_runtime_bound_leaves_a_healthy_digest_untouched
test_runtime_bound_leaves_harness_ancestry_headroom
test_reemit_skips_startup_sweeps_but_keeps_the_wake_drain
test_reemit_cue_survives_the_hook_output_preview
test_reemit_context_manifest_names_every_source_without_bodies
test_startup_and_reemit_share_the_ten_row_queued_bound_and_one_status_line
test_reemit_fleet_state_lists_open_work_and_one_line_per_task
test_reemit_manual_backlog_counts_held_and_blocked_lines
test_agents_baseline_stays_at_true_start_and_reemits_on_every_drifted_pi_compact
test_read_only_pi_compact_refreshes_against_its_own_session_identity
test_agents_baseline_requires_sha256_and_successful_completion
test_reemit_keeps_repair_ownership_with_the_lock_holder

echo "# fm-session-start.test.sh: all assertions passed"
