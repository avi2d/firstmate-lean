# shellcheck shell=bash
# Reads clauth, the Claude account manager, and never writes it: running
# `clauth switch` would move the machine's login under every live session.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_CLAUTH_STATUS_SECONDS=${FM_CLAUTH_STATUS_SECONDS:-15}

# Prints one snapshot carrying a profile list, or one reason on stderr and returns 1.
fm_clauth_status() {
  local out
  command -v clauth >/dev/null 2>&1 || {
    echo "clauth is not installed" >&2
    return 1
  }
  out=$(fm_run_timed "$FM_CLAUTH_STATUS_SECONDS" clauth status --json 2>/dev/null </dev/null) || {
    echo "clauth status --json failed" >&2
    return 1
  }
  printf '%s\n' "$out" | jq -e '
    type == "object" and (.profiles | type) == "array"
    and all(.profiles[]; type == "object" and (.name | type) == "string")' >/dev/null 2>&1 || {
    echo "clauth status --json returned no profile list" >&2
    return 1
  }
  printf '%s\n' "$out"
}
