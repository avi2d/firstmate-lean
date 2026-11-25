#!/usr/bin/env bash
# Exercise the promise record through bin/fm-promise.sh.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMISE="$ROOT/bin/fm-promise.sh"
TMP_ROOT=$(fm_test_tmproot fm-promise-tests)

test_undated_and_past_records_are_not_hidden_and_future_is_not_overdue() {
  local overdue promise_id answer_id future_id
  export FM_HOME="$TMP_ROOT/records"
  promise_id=$("$PROMISE" add promise 'Send the sample' --proof 'https://example.test/sample')
  answer_id=$("$PROMISE" add answer $'Use the second option\nKeep its label' --proof 'read option.txt; expect 2' --due 2000-01-01T00:00Z)
  future_id=$("$PROMISE" add promise 'Publish the release' --proof '/tmp/sample.txt' --due 2099-02-03T04:05:06Z)

  overdue=$("$PROMISE" list --overdue)
  jq -se --arg promise "$promise_id" --arg answer "$answer_id" '
    length == 2
    and any(.[]; .id == $promise and .kind == "promise" and .state == "open"
      and .text == "Send the sample" and .proof == "https://example.test/sample" and .due == null)
    and any(.[]; .id == $answer and .kind == "answer" and .state == "open"
      and .text == "Use the second option\nKeep its label" and .proof == "read option.txt; expect 2"
      and .due == "2000-01-01T00:00:00Z")
  ' <<< "$overdue" >/dev/null || fail "overdue selection lost a record or its proof: $overdue"
  "$PROMISE" list --open | jq -se --arg future "$future_id" '
    length == 3 and any(.[]; .id == $future and .due == "2099-02-03T04:05:06Z")
  ' >/dev/null || fail "open listing left out a promise with a future due time"
  pass "undated and past records are overdue, and a future record is still open"
}

test_invalid_input_does_not_append_a_record() {
  local bad_due
  export FM_HOME="$TMP_ROOT/invalid-home"
  export FM_STATE_OVERRIDE="$TMP_ROOT/invalid-state"
  if "$PROMISE" add promise 'Send it' --proof '   ' 2>/dev/null; then
    fail "accepted a blank proof check"
  fi
  for bad_due in 2030-02-30T10:30Z 2030-01-01T10:30+02:00; do
    if "$PROMISE" add promise 'Send it' --proof '/tmp/result' --due "$bad_due" 2>/dev/null; then
      fail "accepted an invalid UTC due time: $bad_due"
    fi
  done
  assert_equals '' "$("$PROMISE" list --open)" "invalid input left an open record"
  assert_absent "$FM_STATE_OVERRIDE/promises.jsonl" "invalid input created a journal"
  unset FM_STATE_OVERRIDE
  pass "invalid input is rejected before the journal is written"
}

test_close_without_proof_or_for_an_unknown_or_closed_id_does_not_append() {
  local id journal before
  export FM_HOME="$TMP_ROOT/closer-home"
  export FM_STATE_OVERRIDE="$TMP_ROOT/closer-state"
  journal="$FM_STATE_OVERRIDE/promises.jsonl"
  id=$("$PROMISE" add promise 'Send the result' --proof 'read result.txt; expect OK')
  before=$(<"$journal")
  if "$PROMISE" close "$id" 2>/dev/null ||
     "$PROMISE" close "$id" --proof ' ' 2>/dev/null ||
     "$PROMISE" close 999999 --proof 'result.txt says OK' 2>/dev/null; then
    fail "accepted a close without a record or without evidence"
  fi
  assert_equals "$before" "$(<"$journal")" "invalid close changed the journal"
  "$PROMISE" close "$id" --proof 'result.txt says OK'
  assert_equals '' "$("$PROMISE" list --open)" "closed promise is still open"
  assert_equals '' "$("$PROMISE" list --overdue)" "closed promise is still overdue"
  assert_equals "$before" "$(head -n 1 "$journal")" "close replaced the opening event"
  assert_equals '2' "$(jq -sc length "$journal")" "close did not append one event"
  jq -se --arg id "$id" '
    .[1] | .id == $id and .state == "closed" and .proof == "result.txt says OK"
  ' "$journal" >/dev/null || fail "closing event did not retain the evidence"
  if "$PROMISE" close "$id" --proof 'different result' 2>/dev/null; then
    fail "accepted a second close for the same ID"
  fi
  assert_equals '2' "$(jq -sc length "$journal")" "rejected second close appended an event"
  assert_absent "$FM_HOME/state/promises.jsonl" "state override leaked a journal into the home"
  unset FM_STATE_OVERRIDE
  pass "closing needs evidence and appends it without replacing the opening event"
}

test_concurrent_adds_do_not_lose_records_and_only_one_close_wins() {
  local pid i id a b closed=0
  local pids=()
  export FM_HOME="$TMP_ROOT/concurrent"
  for i in {1..8}; do
    "$PROMISE" add promise "Request $i" --proof 'https://example.test/result' > "$TMP_ROOT/$i.id" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a concurrent add failed"
  done
  "$PROMISE" list --open | jq -se '
    (map(.id) | unique | length) == 8
    and (map(.text) | sort) == ["Request 1", "Request 2", "Request 3", "Request 4",
                              "Request 5", "Request 6", "Request 7", "Request 8"]
  ' >/dev/null || fail "concurrent adds lost text or shared an ID"

  id=$(<"$TMP_ROOT/1.id")
  "$PROMISE" close "$id" --proof 'observed result A' 2> "$TMP_ROOT/a.err" & a=$!
  "$PROMISE" close "$id" --proof 'observed result B' 2> "$TMP_ROOT/b.err" & b=$!
  if wait "$a"; then closed=$((closed + 1)); fi
  if wait "$b"; then closed=$((closed + 1)); fi
  assert_equals 1 "$closed" "expected exactly one concurrent close; $(cat "$TMP_ROOT/"{a,b}.err)"
  "$PROMISE" list --overdue | jq -se --arg id "$id" 'length == 7 and all(.[]; .id != $id)' >/dev/null \
    || fail "exactly the closed record should disappear after competing closes"
  pass "concurrent writers preserve distinct records and cannot close one twice"
}

fm_test_run \
  test_undated_and_past_records_are_not_hidden_and_future_is_not_overdue \
  test_invalid_input_does_not_append_a_record \
  test_close_without_proof_or_for_an_unknown_or_closed_id_does_not_append \
  test_concurrent_adds_do_not_lose_records_and_only_one_close_wins
