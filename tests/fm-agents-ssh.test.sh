#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot agents-ssh)
export INSTALLED_ROOT="$TMP_ROOT/operator's code root"
export ALLOWED_HOME="$TMP_ROOT/agents-home"
export AGENTS_GATE="$ROOT/bin/fm-agents-ssh.sh"
export WIRE_LOG="$TMP_ROOT/original-command"
export FM_HOME="$TMP_ROOT/supervisor"
export FM_SSH_BIN="$TMP_ROOT/test-ssh"
REGISTRY="$FM_HOME/data/remote-homes.md"
ENTRYPOINT="$INSTALLED_ROOT/bin/fm-remote-entrypoint.sh"

mkdir -p "$INSTALLED_ROOT/bin" "$FM_HOME/data"
cat > "$ENTRYPOINT" <<'PY'
#!/usr/bin/python3 -I
import base64
import os
import pathlib
import sys

root = str(pathlib.Path(__file__).parent.parent)
assert len(sys.argv) == 5 and sys.argv[1] == "1"
assert base64.b64decode(sys.argv[2]) == os.fsencode(root)
assert base64.b64decode(sys.argv[3]) == os.fsencode(str(pathlib.Path(root).parent / "agents-home"))
assert "SSH_ORIGINAL_COMMAND" not in os.environ
sys.stdout.buffer.write(base64.b64decode(sys.argv[4]) + sys.stdin.buffer.read())
sys.exit(23)
PY

cat > "$FM_SSH_BIN" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$1" = -o ]; do shift 2; done
[ "$1" = -- ] && [ "$2" = agents-alias ] || exit 90
shift 2
IFS=' '
export SSH_ORIGINAL_COMMAND="$*"
printf '%s' "$SSH_ORIGINAL_COMMAND" > "$WIRE_LOG"
exec "$AGENTS_GATE" "$INSTALLED_ROOT" "$ALLOWED_HOME"
SH
chmod +x "$ENTRYPOINT" "$FM_SSH_BIN"

write_route() {
  printf '%s\n' "- agents - Guarded execution (host: agents-alias; root: $1; home: $2; scope: workers; projects: -; added 2026-01-01)" > "$REGISTRY"
}
write_route "$INSTALLED_ROOT" "$ALLOWED_HOME"

fm_on() {
  "$ROOT/bin/fm-on.sh" "$@"
}

allowed() {
  local input=$1 rc=0
  shift
  if [ -n "$input" ]; then
    printf '%s' "$input" | fm_on --stdin agents "$@" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || rc=$?
  else
    fm_on agents "$@" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || rc=$?
  fi
  [ "$rc" = 23 ] || fail "approved $1 ${2:-} did not reach the entrypoint: $(<"$TMP_ROOT/stderr")"
  [ ! -s "$TMP_ROOT/stderr" ] || fail "approved $1 emitted an unexpected error"
  { printf '%s\0' "$@"; printf '%s' "$input"; } > "$TMP_ROOT/expected"
  cmp -s "$TMP_ROOT/expected" "$TMP_ROOT/stdout" || fail "approved $1 ${2:-} changed argv or stdin"
}

refused() {
  local reason=$1 rc=0
  shift
  "$@" < /dev/null > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || rc=$?
  [ "$rc" = 1 ] || fail "refusal for '$reason' exited $rc instead of 1"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "refusal for '$reason' reached the entrypoint"
  grep -Fq "fm-agents-ssh: $reason" "$TMP_ROOT/stderr" || fail "wrong refusal: $(<"$TMP_ROOT/stderr")"
}

gate() {
  SSH_ORIGINAL_COMMAND="$1" "$AGENTS_GATE" "$INSTALLED_ROOT" "$ALLOWED_HOME"
}

doctor_rejects_internal_probe() {
  allowed '' fm-remote-doctor.sh
  allowed '' fm-remote-doctor.sh --fix --backend herdr --session fm-remote
  refused 'arguments are not allowed' fm_on agents fm-remote-doctor.sh --worker-tool-probe
  pass "doctor accepts its route options but refuses the internal worker probe"
}

provision_preserves_manifest_stdin() {
  allowed $'schema=fm-remote-exec-home-provision.v1\n' fm-remote-home-provision.sh
  refused 'arguments are not allowed' fm_on agents fm-remote-home-provision.sh "$ALLOWED_HOME/other"
  pass "provisioning forwards manifest stdin without accepting a positional home"
}

worker_control_rejects_extra_verbs_and_flags() {
  local verb
  allowed '' fm-remote-worker-control.sh capabilities
  allowed '' fm-remote-worker-control.sh capabilities worker-name
  allowed '' fm-remote-worker-control.sh fleet
  for verb in route state capture ci-repository interrupt exit teardown crew-state; do
    allowed '' fm-remote-worker-control.sh "$verb" task-1
  done
  allowed '' fm-remote-worker-control.sh admit task-1 project
  allowed '' fm-remote-worker-control.sh capture task-1 40
  allowed '' fm-remote-worker-control.sh claude-account-check pi claude-bridge/sonnet account
  allowed $'brief fixture\n' fm-remote-worker-control.sh launch task-1 project ship direct-PR off '' main pi claude-bridge/sonnet high herdr account
  allowed $'brief fixture\n' fm-remote-worker-control.sh launch task-1 project scout - - fm/ - pi-signed - - herdr
  allowed 'message fixture' fm-remote-worker-control.sh send-stdin task-1 until-rung
  allowed $'resolved fixture\n' fm-remote-worker-control.sh resolve-stdin task-1
  allowed '' fm-remote-worker-control.sh key task-1 Enter
  allowed $'doorbell fixture\n' fm-remote-worker-control.sh ring task-1 fm-task-1
  allowed '' fm-remote-worker-control.sh ring-record task-1 001.msg
  allowed '' fm-remote-worker-control.sh done-gate task-1 'done [at=42]: report ready'
  allowed '' fm-remote-worker-control.sh relaunch task-1 --harness pi-signed --model openai/gpt-5 --effort medium --note $'literal ; | &\non the next line'
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh unknown task-1
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh relaunch task-1 --note-file /etc/hostname
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh teardown task-1 --force
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh capture ../task-1 40
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh ring task-1 fm-other-task
  refused 'arguments are not allowed' fm_on agents fm-remote-worker-control.sh key task-1 --help
  pass "worker control accepts the route verbs without arbitrary options or targets"
}

status_feed_rejects_unbounded_wait() {
  allowed $'task-1 0 cursor\n' fm-remote-status-feed.sh 55
  refused 'arguments are not allowed' fm_on agents fm-remote-status-feed.sh 301
  pass "status feed preserves cursor stdin but refuses an out-of-range wait"
}

file_reads_reject_nonreports_and_writes() {
  allowed '' fm-remote-file.sh get data/task-1/report.md
  allowed '' fm-remote-file.sh get data/task-1/review/answer.md 262144
  allowed '' fm-remote-file.sh get data/task-1/nm-42-findings-final.txt 262144
  refused 'arguments are not allowed' fm_on agents fm-remote-file.sh get config/backlog-backend
  refused 'arguments are not allowed' fm_on agents fm-remote-file.sh get data/task-1/../other/report.md
  refused 'arguments are not allowed' fm_on agents fm-remote-file.sh put state/handoff/task-1.outbox.md
  pass "file transport accepts report reads, not writes or other home paths"
}

unknown_tracked_operation_is_refused() {
  refused 'remote operation is not allowed' fm_on agents fm-fleet-sync.sh project
  pass "a tracked operation outside the route allowlist does not dispatch"
}

shell_syntax_is_refused_without_dispatch() {
  local original
  allowed '' fm-remote-doctor.sh
  original=$(<"$WIRE_LOG")
  refused 'expected the fm-on.sh protocol 1 command format' gate "$original; true"
  refused 'expected the fm-on.sh protocol 1 command format' gate "${original% *} !!"
  refused 'argv must be canonical base64 with NUL-terminated arguments' gate "${original% *} $(printf %s fm-remote-doctor.sh | base64 | tr -d '\n')"
  pass "wire command rejects shell syntax, invalid base64, and unterminated argv"
}

another_code_root_is_refused_in_both_fields() {
  local original token
  allowed '' fm-remote-doctor.sh
  original=$(<"$WIRE_LOG")
  token=$(printf '%s' "$INSTALLED_ROOT" | base64 | tr -d '\n')
  write_route "$TMP_ROOT/other-code" "$ALLOWED_HOME"
  refused 'command must name the installed remote entrypoint' fm_on agents fm-remote-doctor.sh
  write_route "$INSTALLED_ROOT" "$ALLOWED_HOME"
  refused 'remote code root does not match the installed code root' gate "${original/"$token"/L2Fub3RoZXI=}"
  pass "neither the command path nor the encoded root can select another checkout"
}

another_home_is_refused_without_dispatch() {
  write_route "$INSTALLED_ROOT" "$TMP_ROOT/other-home"
  refused 'remote home does not match the permitted execution home' fm_on agents fm-remote-doctor.sh
  write_route "$INSTALLED_ROOT" "$ALLOWED_HOME"
  pass "the encoded home cannot select a different execution home"
}

interactive_login_is_refused() {
  refused 'interactive login is not allowed' env -u SSH_ORIGINAL_COMMAND "$AGENTS_GATE" "$INSTALLED_ROOT" "$ALLOWED_HOME"
  pass "an SSH login without a command does not dispatch"
}

fm_test_run doctor_rejects_internal_probe provision_preserves_manifest_stdin worker_control_rejects_extra_verbs_and_flags \
  status_feed_rejects_unbounded_wait file_reads_reject_nonreports_and_writes unknown_tracked_operation_is_refused \
  shell_syntax_is_refused_without_dispatch another_code_root_is_refused_in_both_fields \
  another_home_is_refused_without_dispatch interactive_login_is_refused
