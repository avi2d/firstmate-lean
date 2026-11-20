#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-meta)
state="$TMP_ROOT/state"
mkdir -p "$state"
meta="$state/worker.meta"
printf 'backend=herdr\nharness=pi\nkind=ship\n' > "$meta"

event="$ROOT/bin/fm-busy-event.sh"
gen=$("$event" arm "$state" worker)
"$event" apply "$state" worker busy --gen "$gen" --source pi-ext --event agent-start
assert_equals "unknown no-target" "$(fm_busy_classify_meta "$meta" worker "$state")" \
  "a busy event must not fill in a missing endpoint"

printf 'window=lab:w1:p2\n' >> "$meta"
assert_equals "busy pi-ext" "$(fm_busy_classify_meta "$meta" worker "$state")" \
  "an addressed worker must use the recorded Pi event"

"$event" apply "$state" worker idle --gen "$gen" --source pi-ext --event stop
assert_equals "idle pi-ext" "$(fm_busy_classify_meta "$meta" worker "$state")" \
  "the stop event must clear the previous busy verdict"
pass "inbox activity needs both a recorded endpoint and the current Pi event"
