#!/usr/bin/env bash
# Usage: fm-handoff.sh <project> "<title>" [--body-file <path> | --body <text> | -]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-project-owner-lib.sh
. "$SCRIPT_DIR/fm-project-owner-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-handoff.sh <project> "<title>" [--body-file <path> | --body <text> | -]

Deliver a task proposal for <project> to the inbox of the Firstmate home that
owns it, per the project ownership record (docs/configuration.md "Project
ownership"). The owning home files the proposal into its own backlog when it
handles the inbox note; this never writes another home's backlog.
"-" reads the body from stdin. A retry of the same proposal replays the note
already delivered instead of queueing a second one.

Exits 0 once the note is saved in the owning home's inbox, 2 on a usage error,
and 1 when no other home owns the project or the delivery fails.
EOF
}

usage_error() {
  printf 'fm-handoff: %s\n' "$*" >&2
  usage >&2
  exit 2
}

die() {
  printf 'fm-handoff: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
esac
[ "$#" -ge 2 ] || usage_error "name the project and the title"
project=$1
title=$2
shift 2
body=
case "${1:-}" in
  '') [ "$#" -eq 0 ] || usage_error "unexpected argument: $1" ;;
  --body-file)
    [ "$#" -eq 2 ] || usage_error "--body-file takes one path"
    [ -f "$2" ] && [ -r "$2" ] || die "cannot read the body file $2"
    body=$(cat -- "$2"; printf .) || die "cannot read the body file $2"
    body=${body%.}
    ;;
  --body)
    [ "$#" -eq 2 ] || usage_error "--body takes one text"
    body=$2
    ;;
  -)
    [ "$#" -eq 1 ] || usage_error "- takes no further argument"
    body=$(cat; printf .)
    body=${body%.}
    ;;
  *) usage_error "unexpected argument: $1" ;;
esac
case "$title" in
  *[![:space:]]*) ;;
  *) usage_error "the title is empty" ;;
esac
case "$title" in
  *$'\n'* | *$'\r'*) usage_error "the title must be one line" ;;
esac

if ! fm_project_owners_read; then
  die "the project ownership record is unreadable ($FM_PROJECT_OWNERS_ERROR)"
fi
key=$(fm_project_owner_key "$project")
if ! fm_project_owner_foreign "$key" "$FM_HOME"; then
  die "no other Firstmate home owns project $key in $FM_PROJECT_OWNERS_FILE, so this home files it itself with bin/fm-tasks-axi.sh add"
fi
owner=$FM_PROJECT_OWNER_HOME
[ -d "$owner" ] || die "the owning home $owner for project $key does not exist on this machine"

self=$(fm_project_owner_home_identity "$FM_HOME")
proposal=$(
  printf 'Task handoff for project %s: %s\n' "$key" "$title"
  printf 'From the Firstmate home at %s, which does not own %s.\n' "$self" "$key"
  printf 'File it into this home'"'"'s backlog if it belongs here, for example: bin/fm-tasks-axi.sh add "<title>" --mint --prefix %s\n' "$key"
  if [ -n "$body" ]; then
    printf '\n%s' "$body"
  fi
  printf '.'
)
proposal=${proposal%.}
request_id="handoff-$(printf '%s\n%s\n%s\n%s' "$self" "$key" "$title" "$body" | cksum | tr ' ' '-')"

out=$(printf '%s' "$proposal" | env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_PROJECTS_OVERRIDE FM_HOME="$owner" "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$request_id" - 2>&1) \
  || die "delivery to $owner failed: $out"
printf 'handed off to %s: %s\n%s\n' "$owner" "$title" "$out"
