#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v bun >/dev/null || { printf '%s\n' 'fm-effect-run.sh: install Bun first' >&2; exit 127; }

fingerprint() {
  git -C "$root" hash-object --no-filters "$root/package.json" "$root/bun.lock" "$root/bin/fm-effect-run.sh" "$root"/runtime/*.ts |
    git -C "$root" hash-object --stdin
}

key=$(fingerprint)
build_dir="$root/.fm-build"
bundle="$build_dir/firstmate-$key.js"

if [ "${1:-}" = --build ]; then
  mkdir -p "$build_dir"
  staging=$(mktemp -d "$build_dir/.firstmate.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  bun build "$root/runtime/cli.ts" --target=bun --outfile "$staging/firstmate.js"
  [ "$(fingerprint)" = "$key" ] || { printf '%s\n' 'fm-effect-run.sh: inputs changed during build' >&2; exit 1; }
  mv -f -- "$staging/firstmate.js" "$bundle"
  exit 0
fi

if [ ! -f "$bundle" ]; then
  printf '%s\n' 'fm-effect-run.sh: bundle missing or stale; run bun install --frozen-lockfile && bun run build' >&2
  exit 127
fi

exec bun "$bundle" "$@"
