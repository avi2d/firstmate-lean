#!/usr/bin/env bash
# Usage: fm-tasks-axi.sh [<command> [args...]]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-project-tiers-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-project-tiers-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-tasks-axi.sh [<command> [args...]]
       fm-tasks-axi.sh <command> --help
       fm-tasks-axi.sh add "<title>" --mint --prefix <project> [flags]
       fm-tasks-axi.sh add <project>-<number> "<title>" [flags]

Use --repo instead of --prefix to name the project when minting.
An explicit new ID must match the next free <project>-<number> ID.
create is an alias for add. Use fm-spawn.sh to dispatch queued work.

This command addresses the current home's backlog and refuses --file.
Relative --to and --*-file values are resolved against the caller's
directory. --report is stored verbatim.
show (including view) and list decode stored hold reasons.

Data directory: FM_DATA_OVERRIDE, else $FM_HOME/data, else code-root data/.
EOF
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

FM_PROJECT_TIERS=
if [ "$(fm_backlog_backend_value "$CONFIG")" = backlog-md ]; then
  command -v python3 >/dev/null 2>&1 || fail "Backlog.md requires python3 for its write lock"
  command -v node >/dev/null 2>&1 || fail "Backlog.md requires node"
  BACKLOG=(python3 "$SCRIPT_DIR/fm-backlog-md/locked.py" "$DATA" .fm-backlog-md.lock "$SCRIPT_DIR/fm-backlog-md/cli.cjs")
else
  if [ "${1:-}" = ready ] && ! fm_project_tiers_read "$CONFIG"; then
    fail "fix or remove $FM_PROJECT_TIERS_FILE to list ready work"
  fi
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"
  FM_BACKLOG_TRANSITION_ERROR=
  if ! fm_backlog_tasks_axi_addressing "$DATA"; then
    fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
  fi

  if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
    if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
      fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
    fi
    export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
  else
    unset TASKS_AXI_FILE
  fi

  if [[ ${1:-} = add || ${1:-} = create ]]; then
    command -v python3 >/dev/null 2>&1 || fail "add requires python3 for its ID allocation lock"
    command -v node >/dev/null 2>&1 || fail "add requires node"
    DATA=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
    cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
    exec python3 "$SCRIPT_DIR/fm-backlog-md/locked.py" "$DATA" .fm-tasks-axi-add.lock \
      "$SCRIPT_DIR/fm-backlog-md/tasks-axi-add.cjs" "${ARGS[@]:1}"
  fi
  cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
  BACKLOG=(tasks-axi)
fi
case "${1:-}" in
  show|view|list)
    set -o pipefail
    "${BACKLOG[@]}" ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
  ready)
    if [ -n "$FM_PROJECT_TIERS" ]; then
      set -o pipefail
      "${BACKLOG[@]}" ${ARGS[@]+"${ARGS[@]}"} | fm_project_tiers_order_ready
      exit $?
    fi
    ;;
esac
exec "${BACKLOG[@]}" ${ARGS[@]+"${ARGS[@]}"}
