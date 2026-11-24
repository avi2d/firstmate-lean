#!/usr/bin/env bash
# Source to read GitHub's required checks and compare a PR with its base.

github_main_only_empty_rollup() {
  local home=$1 project_url=$2 json=$3 config
  config="$home/config/ci-main-only"
  [ -f "$config" ] && grep -Fxq -- "$project_url" "$config" \
    && printf '%s' "$json" | jq -e '.statusCheckRollup == []' >/dev/null 2>&1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

github_disjoint_base_tip() {
  local repo=$1 base=$2 head=$3 merge_state=$4 comparison tip fork base_changes
  shift 4
  # A blocked merge state can hide the strict branch update requirement.
  [ "$merge_state" = CLEAN ] || return 1
  comparison=$("$@" api "repos/$repo/compare/$(github_urlencode_path_segment "$base")...$head?per_page=1") || return 1
  tip=$(printf '%s' "$comparison" | jq -er 'select((.behind_by | type) == "number" and .behind_by > 0) | .base_commit.sha') || return 1
  fork=$(printf '%s' "$comparison" | jq -er '.merge_base_commit.sha') || return 1
  fm_pr_head_valid "$tip" && fm_pr_head_valid "$fork" && [ "$tip" != "$fork" ] || return 1
  base_changes=$("$@" api "repos/$repo/compare/$fork...$tip?per_page=1") || return 1

  # GitHub puts the changed files on page one and caps the list at 300.
  printf '%s\n%s\n' "$comparison" "$base_changes" | jq -es --arg fork "$fork" '
    def paths:
      .files
      | if type != "array" or length >= 300 then error("incomplete changed files") else . end
      | [ .[]
          | if (.status | type) != "string" or (.filename | type) != "string" or .filename == ""
               or (.status == "renamed" and .previous_filename == null)
               or (.previous_filename != null and ((.previous_filename | type) != "string" or .previous_filename == ""))
            then error("invalid changed file") else .filename, (.previous_filename // empty) end ];
    length == 2 and (.[1].merge_base_commit.sha == $fork and .[1].status == "ahead")
    and ((.[0] | paths) as $pr | (.[1] | paths) as $base | ($pr - $base | length) == ($pr | length))
  ' >/dev/null || return 1
  printf '%s' "$tip"
}

# A plan refusal means there are no active rulesets. A permission refusal does not.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local repo=$1 base=$2 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  shift 2
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$("$@" api "repos/$repo/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$("$@" api --paginate "repos/$repo/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  if ! FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sce '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []') \
    || [ -z "$FM_PR_GITHUB_REQUIRED" ]; then
    FM_PR_GITHUB_REQUIRED='[]'
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the required checks for base branch $base could not be combined"
  fi
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}
