#!/usr/bin/env bash
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

usage() {
  cat <<'USAGE'
fm-action-versions-check.sh - fail when a GitHub workflow uses an action whose
major version is behind the action's latest release.

Reads every `uses: owner/repo[/path]@ref` line in .github/workflows/*.yml and
*.yaml, looks up each action's latest release through the GitHub API with gh,
and prints the file, the line, and the version to use for every ref whose
major version is behind. A full commit SHA pin is judged by its trailing
`# vX.Y.Z` comment. Local (./) and docker:// refs are skipped. A ref with no
readable version and a failed lookup both fail the check with the reason.
Inside GitHub Actions each finding is also an error annotation on its line.

gh authenticates from GH_TOKEN or GITHUB_TOKEN; in a workflow step set
`GH_TOKEN: ${{ github.token }}`.

Usage:
  fm-action-versions-check.sh                 check this repository's workflows
  fm-action-versions-check.sh --root <dir>    check the workflows under <dir>
  fm-action-versions-check.sh --help

Exit status: 0 when every action is on its latest major version, 1 when any
is behind, unreadable, or could not be looked up, 2 on a usage error.
USAGE
}

usage_error() {
  printf 'fm-action-versions-check.sh: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || usage_error "--root requires a directory."
      ROOT=$2
      shift 2
      ;;
    --root=*)
      ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[ -d "$ROOT" ] || usage_error "not a directory: $ROOT"
ROOT=${ROOT%/}

if ! command -v gh >/dev/null 2>&1; then
  printf 'fm-action-versions-check.sh: gh is required to look up action releases.\n' >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-action-versions.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
LOOKUPS="$WORK/lookups"
: >"$LOOKUPS"

CHECKED=0
FINDINGS=0

report() {
  local file=$1 line=$2 message=$3
  FINDINGS=$((FINDINGS + 1))
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    message=${message//%/%25}
    printf '::error file=%s,line=%s::%s:%s: %s\n' "$file" "$line" "$file" "$line" "$message"
  else
    printf '%s:%s: %s\n' "$file" "$line" "$message" >&2
  fi
}

version_major() {
  local version=$1 re='^v?([0-9]+)(\.[0-9]+)*$'
  [[ $version =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

latest_release_once_per_repo() {
  local repo=$1 result tag reason
  result=$(awk -F '\t' -v repo="$repo" '$1 == repo { print $2; exit }' "$LOOKUPS")
  if [ -z "$result" ]; then
    if tag=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>"$WORK/gh.err") && [ -n "$tag" ]; then
      result="ok $tag"
    else
      reason=$(tr '\n\t' '  ' <"$WORK/gh.err" | sed 's/[[:space:]]*$//')
      [ -n "$reason" ] || reason='gh returned no release tag'
      result="error $reason"
    fi
    printf '%s\t%s\n' "$repo" "$result" >>"$LOOKUPS"
  fi
  printf '%s\n' "$result"
}

check_reference() {
  local file=$1 line=$2 value=$3 comment=$4
  local action_re='^([^/@[:space:]]+/[^/@[:space:]]+)(/[^@[:space:]]*)?@([^@[:space:]]+)$'
  local sha_re='^[0-9a-f]{40}$'
  local comment_re='^#[[:space:]]*(v?[0-9]+(\.[0-9]+)*)([[:space:]]|$)'
  local major_re='^v?[0-9]+$'
  local action repo ref version current lookup tag latest

  case "$value" in
    ./*|docker://*) return 0 ;;
  esac
  CHECKED=$((CHECKED + 1))

  if ! [[ $value =~ $action_re ]]; then
    report "$file" "$line" "cannot read the action reference '$value'; expected owner/repo@version"
    return 0
  fi
  repo=${BASH_REMATCH[1]}
  ref=${BASH_REMATCH[3]}
  action=${value%@*}

  if [[ $ref =~ $sha_re ]]; then
    if ! [[ $comment =~ $comment_re ]]; then
      report "$file" "$line" "$action@$ref is a commit pin with no trailing '# vX.Y.Z' comment naming its release"
      return 0
    fi
    version=${BASH_REMATCH[1]}
  else
    version=$ref
  fi

  if ! current=$(version_major "$version"); then
    report "$file" "$line" "$action@$ref is not a release version; pin a release such as $action@v1"
    return 0
  fi

  lookup=$(latest_release_once_per_repo "$repo")
  case "$lookup" in
    ok\ *) tag=${lookup#ok } ;;
    *)
      report "$file" "$line" "could not look up the latest release of $repo: ${lookup#error }"
      return 0
      ;;
  esac
  if ! latest=$(version_major "$tag"); then
    report "$file" "$line" "the latest release of $repo is '$tag', which is not a version this check can compare"
    return 0
  fi

  [ "$current" -lt "$latest" ] || return 0
  if [ "$version" != "$ref" ]; then
    report "$file" "$line" "$action@$ref pins $version, behind the latest major version; pin the commit of $tag and comment it '# $tag'"
  elif [[ $ref =~ $major_re ]]; then
    report "$file" "$line" "$action@$ref is behind the latest major version; use $action@${ref%%[0-9]*}$latest (latest release $tag)"
  else
    report "$file" "$line" "$action@$ref is behind the latest major version; use $action@$tag"
  fi
}

check_file() {
  local path=$1 file=${1#"$ROOT"/} text rest value comment number=0
  local uses_re='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*(.*)$'
  while IFS= read -r text || [ -n "$text" ]; do
    number=$((number + 1))
    text=${text%$'\r'}
    [[ $text =~ $uses_re ]] || continue
    rest=${BASH_REMATCH[2]}
    value=${rest%%#*}
    comment=
    [ "$value" = "$rest" ] || comment="#${rest#*#}"
    value=${value%"${value##*[![:space:]]}"}
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    check_reference "$file" "$number" "$value" "$comment"
  done <"$path"
}

shopt -s nullglob
files=("$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml)
shopt -u nullglob
if [ "${#files[@]}" -eq 0 ]; then
  printf 'fm-action-versions-check.sh: no workflow files under %s/.github/workflows.\n' "$ROOT" >&2
  exit 1
fi

for path in "${files[@]}"; do
  check_file "$path"
done

if [ "$FINDINGS" -gt 0 ]; then
  printf 'fm-action-versions-check.sh: %s of %s action references need an update or a readable version.\n' "$FINDINGS" "$CHECKED" >&2
  exit 1
fi
printf 'fm-action-versions-check.sh: all %s action references are on their latest major version.\n' "$CHECKED"
