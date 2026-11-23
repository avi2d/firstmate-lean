#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-subquo-lib.sh
. "$SCRIPT_DIR/fm-subquo-lib.sh"
# shellcheck source=bin/fm-quota-assessment-lib.sh
. "$SCRIPT_DIR/fm-quota-assessment-lib.sh"

case "${1:-}" in
  '') fm_subquo_snapshot ;;
  -h|--help) printf '%s\n' 'Usage: fm-quota-read.sh [--reset-epoch <provider> [<account-label>]]' ;;
  --reset-epoch)
    provider=${2:-} lane=${3:-}
    [[ "$provider" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || exit 2
    saved=$(fm_subquo_row "$(fm_subquo_snapshot)" "$provider" "$lane") || exit 1
    epoch=$(jq -r "$(fm_quota_assessment_jq)"'
      [.windows[]? | select(.scope == "all" and .percentRemaining == 0) | .resetsAt | quota_reset_epoch]
      | if length > 0 and all(.[]; . != null and . > now) then max else empty end
    ' <<< "$saved") || exit 1
    if [ -n "$epoch" ]; then
      printf '%s\n' "$epoch"
    else
      fm_run_timed 5 quota-axi --provider "$provider" --json --no-credential-refresh 2>/dev/null </dev/null |
        jq -er --arg provider "$provider" "$(fm_quota_assessment_jq)"'
          first(.providers[]? | select(.provider == $provider)) | .resetsAt | quota_reset_epoch | values'
    fi
    ;;
  *) exit 2 ;;
esac
