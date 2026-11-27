#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/bin"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG"

. "$ROOT/bin/fm-pr-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"

ship_reported_done() {
  local status="$STATE/$1.status" verb
  [ ! -L "$status" ] || return 1
  status_line_verb "$(last_status_line "$status")" verb
  [ "$verb" = "done" ]
}

finished() {
  local id=$1 meta="$STATE/$1.meta" kind rc
  kind=$(awk -F= '$1 == "kind" { print substr($0,6); exit }' "$meta")
  case "$kind" in
    scout)
      [ -f "$DATA/$id/report.md" ] || return 1
      "$SCRIPT_DIR/fm-captain-hold.sh" settled "$id" >/dev/null 2>&1 || return 1
      rc=0
      "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 1 ]
      ;;
    ship)
      ship_reported_done "$id" || return 1
      fm_pr_metadata_identity_parse "$meta" || return 1
      case "$FM_PR_META_PROVIDER" in
        github)
          fm_pr_github_read_record "$FM_PR_META_HOST" "${FM_PR_META_PATH%%/*}" "${FM_PR_META_PATH#*/}" "$FM_PR_META_NUMBER" || return 1
          ;;
        gitlab)
          fm_pr_gitlab_read_record "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" || return 1
          ;;
        forgejo)
          fm_pr_forgejo_read_record "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" || return 1
          ;;
        gerrit)
          fm_pr_gerrit_read_record "$FM_PR_META_HOST" "$FM_PR_META_NUMBER" || return 1
          ;;
        *) return 1 ;;
      esac
      [ "$FM_PR_RECORD_MERGED" = true ] && ship_reported_done "$id"
      ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in list|sweep) action=$1 ;; *) printf 'usage: %s list|sweep\n' "$0" >&2; exit 2 ;; esac
if [ "$action" = sweep ]; then
  registration=$("$SCRIPT_DIR/fm-pr-check.sh" scan 2>&1) || registration="PR registration failed: $registration"
  [ -z "$registration" ] || printf '%s\n' "$registration"
fi
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  fm_pr_task_id_valid "$id" || continue
  finished "$id" || continue
  if [ "$action" = list ]; then
    printf 'finished workspace open: %s\n' "$id"
    continue
  fi
  rc=0
  out=$("$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'closed finished workspace: %s\n' "$id"
  elif [ -e "$meta" ]; then
    printf 'finished workspace open: %s (teardown exit %s): %s\n' "$id" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
  else
    printf 'finished workspace cleanup result: %s (exit %s): %s\n' "$id" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
  fi
done
