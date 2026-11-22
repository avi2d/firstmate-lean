#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  printf '%s\n' 'Usage: fm-effect-shadow.sh <baseline-executable> <candidate-executable> [arg ...]' >&2
  exit 2
fi

baseline=$1 candidate=$2
shift 2
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-effect-shadow.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

baseline_rc=0
"$baseline" "$@" >"$scratch/baseline.out" 2>"$scratch/baseline.err" || baseline_rc=$?
candidate_rc=0
"$candidate" "$@" >"$scratch/candidate.out" 2>"$scratch/candidate.err" || candidate_rc=$?

different=0
if [ "$baseline_rc" -ne "$candidate_rc" ]; then
  printf 'Exit codes differ: baseline=%s candidate=%s\n' "$baseline_rc" "$candidate_rc" >&2
  different=1
fi
diff -u "$scratch/baseline.out" "$scratch/candidate.out" || different=1
diff -u "$scratch/baseline.err" "$scratch/candidate.err" || different=1
if [ "$different" -eq 0 ]; then
  printf 'stdout, stderr, and exit code match (%s)\n' "$baseline_rc"
fi
exit "$different"
