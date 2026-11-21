#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, Herdr, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

fm_test_fake_herdr_send() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}'
    ;;
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    ;;
  'pane read')
    case "${FM_FAKE_HERDR_COMPOSER:-}" in
      pending) printf '%s\n' '╭──────────────╮' '│ leftover txt │' '╰──────────────╯' ;;
      *) printf '%s\n' '╭────╮' '│    │' '╰────╯' ;;
    esac
    ;;
  'pane send-text')
    [ "${FM_FAKE_HERDR_SEND_FAIL:-0}" != 1 ] || exit 1
    printf '%s' "$4" >> "${FM_SEND_LOG:-/dev/null}"
    ;;
  'pane send-keys') [ "${FM_FAKE_HERDR_SEND_FAIL:-0}" != 1 ] ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

fm_test_fake_herdr_teardown() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
fixture=$(dirname "$0")
session=${@: -1}
case "${1:-} ${2:-}" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true}}'
    ;;
  'session list')
    jq -cn --arg name "$session" --arg path "$fixture/herdr.sock" '{sessions:[{name:$name,running:true,socket_path:$path}]}'
    ;;
  'pane get')
    [ ! -e "$fixture/unknown" ] || exit 1
    if [ -e "$fixture/pending-close" ]; then
      jq -cn --arg pane "$3" '{result:{pane:{pane_id:$pane}}}'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    ;;
  'pane close')
    [ -z "${FM_FAKE_HERDR_CLOSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_HERDR_CLOSE_LOG"
    [ ! -e "$fixture/pending-close" ]
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

fm_test_make_spawn_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  shift
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$#" -ge 2 ] && [ "${@: -2:1}" = --session ]; then
  [ "${@: -1}" = spawn-fixture ]
  set -- "${@:1:$#-2}"
else
  [ "$*" = 'status --json' ]
fi
fixture="$(dirname "$0")"
pane=${3:-}
cwd_file="$fixture/cwd-$pane"
if [ -n "${FM_FAKE_CALL_LOG:-}" ]; then
  case "$1 $2" in
    'tab create'|'pane run'|'pane send-text'|'pane send-keys'|'pane close')
      printf 'herdr %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
      ;;
  esac
fi
case "$1 $2" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.9.5","protocol":22},"server":{"running":true,"version":"0.9.5","protocol":22}}'
    ;;
  'workspace list')
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    ;;
  'tab list')
    printf '%s\n' '{"result":{"tabs":[]}}'
    ;;
  'tab create')
    index=$(cat "$fixture/tab-index" 2>/dev/null || printf '1')
    index=$((index + 1))
    printf '%s' "$index" > "$fixture/tab-index"
    : > "$fixture/cwd-w1:p$index"
    printf '{"result":{"tab":{"tab_id":"w1:t%s"},"root_pane":{"pane_id":"w1:p%s"}}}\n' "$index" "$index"
    ;;
  'pane run')
    payload=${4# }
    [ -z "${FM_FAKE_PANE_LOG:-}" ] || printf '%s\n' "$payload" >> "$FM_FAKE_PANE_LOG"
    lease=$(cat "$fixture/lease")
    if [ "$payload" = "cd -- '$lease'" ]; then
      printf '%s' "$lease" > "$cwd_file"
    fi
    ;;
  'pane get')
    if [ ! -f "$cwd_file" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    jq -cn --arg pane "$pane" --arg cwd "$(cat "$cwd_file")" '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}'
    ;;
  'pane send-text')
    payload=${4# }
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          cat -- "$staged" >> "$FM_FAKE_LAUNCH_LOG"
          ;;
        *) printf '%s\n' "$payload" >> "$FM_FAKE_LAUNCH_LOG" ;;
      esac
    fi
    ;;
  'pane send-keys')
    [ -z "${FM_FAKE_ENTER_LOG:-}" ] || printf '%s\n' "$4" >> "$FM_FAKE_ENTER_LOG"
    ;;
  'pane close') rm -f -- "$cwd_file" ;;
  'session list')
    jq -cn --arg path "$fixture/herdr.sock" '{sessions:[{name:"spawn-fixture",running:true,socket_path:$path}]}'
    ;;
  *)
    printf 'unexpected fake Herdr command: %s %s\n' "$1" "$2" >&2
    exit 2
    ;;
esac
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_CALL_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "${1:-} ${2:-}" in
  'get --lease')
    if [ -n "${FM_FAKE_PANE_PATH_ROOT:-}" ]; then
      slot="$FM_FAKE_PANE_PATH_ROOT/fm-${4:?}"
    else
      slot=${FM_FAKE_PANE_PATH:?}
    fi
    printf '%s' "$slot" > "$(dirname "$0")/lease"
    printf '%s\n' "$slot"
    ;;
  'return --force') : ;;
  *) exit 2 ;;
esac
SH
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/orc"
  chmod +x "$fakebin/herdr" "$fakebin/treehouse" "$fakebin/orc"
  fm_fake_exit0 "$fakebin" pi "$@"
  printf '%s\n' "$fakebin"
}

fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  mkdir -p "$home/user-home" "$home/config"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_BACKEND=herdr HERDR_SESSION=spawn-fixture FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_herdr_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}
