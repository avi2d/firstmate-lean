#!/usr/bin/env bash
# Usage: fm-main-ci-watch.sh arm <github-pr-url> <base-branch> <verified-head>
# Usage: fm-main-ci-watch.sh check <watch-record>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-github-required-checks-lib.sh
. "$SCRIPT_DIR/fm-github-required-checks-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

arm() {
  local url=$1 base=$2 head=$3 key record temp
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  fm_pr_head_valid "$head" && git check-ref-format "refs/heads/$base" || return 1
  key=$(printf '%s\t%s\t%s\n' "$url" "$base" "$head" | git hash-object --stdin) || return 1
  record="$STATE/$key.main-ci-watch"
  temp=$(mktemp "$STATE/.main-ci-watch.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\t%s\n' "$url" "$base" "$head" "$(date +%s)" > "$temp" \
    || ! mv -f -- "$temp" "$record"; then
    rm -f -- "$temp"
    return 1
  fi
}

close_watch() {
  local reason=${1-}
  if [ -n "$reason" ]; then
    fm_wake_append check "main-ci:$url:${sha:-$head}" "$reason" || return 1
  fi
  rm -f -- "$record" || return 1
  [ -z "$reason" ] || printf '%s\n' "$reason"
}

check() {
  local record=$1 url base head armed now expires json outcome sha='' merged_at runs verdict id conclusion
  [ "$record" = "$STATE/${record##*/}" ] && [[ "${record##*/}" =~ ^[0-9a-f]+\.main-ci-watch$ ]] || return 2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  IFS=$'\t' read -r url base head armed < "$record" || return 2
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 2
  fm_pr_head_valid "$head" && git check-ref-format "refs/heads/$base" || return 2
  [[ "$armed" =~ ^[1-9][0-9]{0,10}$ ]] || return 2
  now=$(date +%s)
  expires=$((armed + 86400))

  if ! json=$(GH_HOST="$FM_PR_HOST" fm_run_timed 10 gh api "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER") \
    || ! outcome=$(printf '%s' "$json" | jq -er --arg head "$head" --arg base "$base" '
      if (.head.sha | type) != "string" or (.base.ref | type) != "string" then error("unreadable PR identity")
      elif .head.sha != $head or .base.ref != $base then "retire"
      elif .state == "closed" and .merged == true then
        [.merge_commit_sha, (.merged_at | fromdateiso8601)] | @tsv
      elif .state == "closed" and .merged == false then "retire"
      elif .state == "open" then "wait"
      else error("unreadable PR outcome") end'); then
    if [ "$now" -ge "$expires" ]; then
      close_watch "check: main CI watch could not read the merge outcome for $url"
    fi
    return
  fi
  case "$outcome" in
    retire) close_watch; return ;;
    wait) if [ "$now" -ge "$expires" ]; then close_watch; fi; return ;;
  esac
  IFS=$'\t' read -r sha merged_at <<< "$outcome"
  if ! fm_pr_head_valid "$sha" || ! [[ "$merged_at" =~ ^[1-9][0-9]{0,10}$ ]]; then
    if [ "$now" -ge "$expires" ]; then
      close_watch "check: main CI watch could not identify the merge commit for $url"
    fi
    return
  fi

  if runs=$(GH_HOST="$FM_PR_HOST" fm_run_timed 10 gh api --paginate \
    "repos/$FM_PR_PATH/actions/runs?branch=$(github_urlencode_path_segment "$base")&head_sha=$sha&event=push&per_page=100") \
    && verdict=$(printf '%s' "$runs" | jq -ers --arg sha "$sha" --arg base "$base" '
      [ .[]
        | if (.workflow_runs | type) != "array" then error("unreadable workflow runs") else .workflow_runs[] end
        | select(.head_sha == $sha and .head_branch == $base and .event == "push") ] as $runs
      | [$runs[] | select(.status == "completed" and
          (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required"
           or .conclusion == "startup_failure" or .conclusion == "cancelled" or .conclusion == "stale"))]
      | if length > 0 then first | [.id, .conclusion] | @tsv
        elif ($runs | length) > 0 and all($runs[];
          .status == "completed" and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral"))
          then "green"
        else "wait" end'); then
    case "$verdict" in
      green)
        if [ "$now" -ge $((merged_at + 300)) ]; then close_watch; fi
        return
        ;;
      wait) ;;
      *)
        IFS=$'\t' read -r id conclusion <<< "$verdict"
        if [[ "$id" =~ ^[1-9][0-9]*$ ]]; then
          close_watch "check: main CI red on $base at $sha after $url: https://$FM_PR_HOST/$FM_PR_PATH/actions/runs/$id ($conclusion)"
          return
        fi
        ;;
    esac
  fi
  if [ "$now" -ge $((merged_at + 86400)) ]; then
    close_watch "check: main CI has no verified result on $base at $sha after $url"
  fi
}

case "${1-}:$#" in
  arm:4) arm "$2" "$3" "$4" ;;
  check:2) check "$2" ;;
  *) exit 2 ;;
esac
