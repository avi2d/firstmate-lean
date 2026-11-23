# shellcheck shell=bash
# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

fm_subquo_decode() {
  node "$(dirname "${BASH_SOURCE[0]}")/fm-subquo-decode.mjs" 2>/dev/null
}

fm_subquo_snapshot() {
  local raw seconds=${1:-2}
  [ "$seconds" -le 2 ] || seconds=2
  command -v subquo >/dev/null 2>&1 || { printf '%s\n' '{"unavailable":"subquo not installed"}'; return; }
  raw=$(fm_run_timed "$seconds" subquo read --json 2>/dev/null </dev/null) || {
    printf '%s\n' '{"unavailable":"subquo snapshot missing or unreadable"}'
    return
  }
  fm_subquo_decode <<< "$raw" ||
    printf '%s\n' '{"unavailable":"subquo snapshot could not be decoded as subquo.v1"}'
}

fm_subquo_row_jq() {
  cat <<'JQ'
  def subquo_row($snapshot; $provider; $lane):
    [$snapshot.providers[]? | select(.provider == $provider)] as $rows |
    def by_label($label): first($rows[] | select(.accountKey == $label)) // null;
    if $lane != "" then by_label($lane)
    else by_label("default") // by_label($provider)
    end;
  def subquo_missing($snapshot; $row):
    $snapshot.unavailable //
    (if $row == null then "no matching subquo account"
     elif $row.unavailable == "stale" then "subquo reading stale"
     elif $row.unavailable then "subquo reading unavailable: \($row.unavailable)"
     else null end);
JQ
}

fm_subquo_row() {
  jq -c --arg provider "$2" --arg lane "$3" "$(fm_subquo_row_jq)"'
    subquo_row(.; $provider; $lane) as $row |
    if subquo_missing(.; $row) then null else $row end
  ' <<< "$1"
}
