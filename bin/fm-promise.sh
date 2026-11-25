#!/usr/bin/env bash
# Record and review chat promises and owner answers.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  fm-promise.sh add <promise|answer> <text> --proof <check> [--due <UTC time>]
  fm-promise.sh close <id> --proof <evidence>
  fm-promise.sh list --open
  fm-promise.sh list --overdue

Use a URL, a command and its expected result, or a file as the proof check.
Verify the check before closing, then record the evidence you found.
Use YYYY-MM-DDTHH:MMZ or YYYY-MM-DDTHH:MM:SSZ for the due time.
With no due time, the record is due at the next review.

Add prints the record ID. List prints one JSON object per record.
The append-only journal is promises.jsonl under FM_STATE_OVERRIDE or FM_HOME/state.
USAGE
}

die() { printf 'fm-promise: %s\n' "$*" >&2; exit 1; }

require_text() {
  [[ $2 == *[![:space:]]* ]] || die "$1 cannot be blank"
}

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

check_journal() {
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    [ -f "$journal" ] && [ ! -L "$journal" ] || die "not a regular journal: $journal"
  fi
}

lock_journal() {
  umask 077
  FM_STATE_OVERRIDE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$script_dir/fm-wake-lib.sh"
  local lock="$journal.lock"
  fm_lock_acquire_wait_max "$lock" 10 || die "cannot lock $journal"
  trap 'fm_lock_release "$journal.lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  check_journal
}

fold_open() {
  jq -nc --arg id "$1" --arg now "$2" '
    reduce inputs as $event ({};
      $event.id as $key
      | if $event.state == "open" and .[$key] == null then .[$key] = $event
        elif $event.state == "closed" and .[$key] != null then del(.[$key])
        else error("invalid promise journal transition")
        end)
    | if $id != "" then .[$id]
      else [.[]] | sort_by(.id | tonumber)[] | select($now == "" or .due == null or .due <= $now)
      end
  ' "$journal"
}

add_record() {
  [ "$#" -ge 2 ] || die "add needs a kind and text; see --help"
  local kind=$1 message=$2 proof='' due='' size=0 id at event
  case "$kind" in promise|answer) ;; *) die "kind must be promise or answer" ;; esac
  require_text text "$message"
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "missing value for $1"
    case "$1" in
      --proof) [ -z "$proof" ] || die "give --proof once"; require_text proof "$2"; proof=$2 ;;
      --due) [ -z "$due" ] || die "give --due once"; require_text due "$2"; due=$2 ;;
      *) die "unknown add option: $1" ;;
    esac
    shift 2
  done
  require_text proof "$proof"

  if [ -n "$due" ]; then
    if [[ $due =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]]; then
      due=${due%Z}:00Z
    fi
    if ! [[ $due =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      ! jq -ne --arg due "$due" '$due | (fromdateiso8601 | todateiso8601) == $due' >/dev/null 2>&1; then
      die "invalid UTC due time; see --help"
    fi
  fi
  at=$(utc_now)
  lock_journal
  if [ -f "$journal" ]; then
    size=$(wc -c < "$journal")
  fi
  # The byte offset can only be reused if someone rewrites the journal.
  id=$((size + 1))
  event=$(jq -nc --arg id "$id" --arg kind "$kind" --arg text "$message" \
    --arg proof "$proof" --arg due "$due" --arg at "$at" '
    {$id, state: "open", $kind, $text, $proof, due: (if $due == "" then null else $due end), $at}
  ')
  printf '%s\n' "$event" >> "$journal" || die "cannot append to $journal"
  printf '%s\n' "$id"
}

close_record() {
  [ "$#" -eq 3 ] && [ "$2" = --proof ] || die "use close <id> --proof <evidence>"
  local id=$1 proof=$3 at event open
  [[ $id =~ ^[1-9][0-9]*$ ]] || die "invalid record ID"
  require_text proof "$proof"
  lock_journal
  [ -f "$journal" ] || die "no open record with ID $id"
  open=$(fold_open "$id" '') || die "cannot read $journal"
  [ "$open" != null ] || die "no open record with ID $id"
  at=$(utc_now)
  event=$(jq -nc --arg id "$id" --arg proof "$proof" --arg at "$at" '
    {$id, state: "closed", $proof, $at}
  ')
  printf '%s\n' "$event" >> "$journal" || die "cannot append to $journal"
}

list_records() {
  [ "$#" -eq 1 ] || die "use list --open or list --overdue"
  local now=''
  case "$1" in
    --open) ;;
    --overdue) now=$(utc_now) ;;
    *) die "use list --open or list --overdue" ;;
  esac
  check_journal
  [ -f "$journal" ] || return 0
  fold_open '' "$now"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
home="${FM_HOME:-${FM_ROOT_OVERRIDE:-${script_dir%/bin}}}"
state="${FM_STATE_OVERRIDE:-$home/state}"
journal="$state/promises.jsonl"

case "${1:-}" in
  add) shift; add_record "$@" ;;
  close) shift; close_record "$@" ;;
  list) shift; list_records "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
