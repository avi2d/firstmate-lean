#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-lavish-address-lib.sh
. "$ROOT/bin/fm-lavish-address-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lavish-address)

accepts() { fm_lavish_address_valid "$1" || fail "refused a host:port address: $1"; }
refuses() { ! fm_lavish_address_valid "$1" || fail "accepted an address a board URL cannot carry: $1"; }

accepts 127.0.0.1:14387
accepts 127.0.0.1:1
accepts 127.0.0.1:65535
accepts '[::1]:14387'
accepts board.example:8080
refuses ''
refuses 127.0.0.1
refuses :14387
refuses 127.0.0.1:
refuses 127.0.0.1:0
refuses 127.0.0.1:65536
refuses 127.0.0.1:014387
refuses 127.0.0.1:1x
refuses 'http://127.0.0.1:14387'
refuses '127.0.0.1:14387/session'
refuses '127.0.0.1 :14387'
refuses "$(printf '127.0.0.1:1\nother:2')"
refuses '[::1:14387'
refuses '[]:14387'
pass "fm-lavish-address: validation accepts host:port in TCP port range and refuses URLs, ranges and whitespace"

ordinary="$TMP_ROOT/ordinary"
mkdir -p "$ordinary/config"
printf '127.0.0.1:24387\n' > "$ordinary/config/lavish-axi-supervisor-address"
fm_lavish_supervisor_address_load "$ordinary" "$ordinary/config" || fail "an ordinary home failed to load"
assert_equals local "$FM_LAVISH_SUPERVISOR_SCOPE" "an ordinary home read the execution-home address file"
assert_equals "http://127.0.0.1:4387/session/0123456789abcdef" \
  "$(fm_lavish_supervisor_url "http://127.0.0.1:4387/session/0123456789abcdef")" \
  "an ordinary home rewrote its own board URL"
pass "fm-lavish-address: an ordinary home keeps its own board URL, not the execution-home address"

exec_home="$TMP_ROOT/exec"
mkdir -p "$exec_home/config"
: > "$exec_home/.fm-exec-home"
fm_lavish_supervisor_address_load "$exec_home" "$exec_home/config" || fail "an unconfigured execution home failed to load"
assert_equals unconfigured "$FM_LAVISH_SUPERVISOR_SCOPE" "an execution home without the file was not reported unconfigured"
assert_equals "http://127.0.0.1:4387/session/0123456789abcdef" \
  "$(fm_lavish_supervisor_url "http://127.0.0.1:4387/session/0123456789abcdef")" \
  "an unconfigured execution home invented a board address"
pass "fm-lavish-address: an unconfigured execution home keeps the host URL, not an invented one"

printf '[::1]:24387\n' > "$exec_home/config/lavish-axi-supervisor-address"
fm_lavish_supervisor_address_load "$exec_home" "$exec_home/config" || fail "a configured execution home failed to load"
assert_equals configured "$FM_LAVISH_SUPERVISOR_SCOPE" "a configured execution home was not reported configured"
assert_equals "http://[::1]:24387/session/0123456789abcdef?token=a%2Fb" \
  "$(fm_lavish_supervisor_url "http://127.0.0.1:4387/session/0123456789abcdef?token=a%2Fb")" \
  "a configured execution home lost the session path or query while moving the address"
pass "fm-lavish-address: a configured execution home moves only host:port, not the session path or query"

printf '127.0.0.1:4387 extra\n' > "$exec_home/config/lavish-axi-supervisor-address"
if fm_lavish_supervisor_address_load "$exec_home" "$exec_home/config" 2> "$TMP_ROOT/err"; then
  fail "a malformed supervisor address loaded"
fi
assert_contains "$(cat "$TMP_ROOT/err")" "config/lavish-axi-supervisor-address" "a malformed address was refused without naming the file"
rm "$exec_home/config/lavish-axi-supervisor-address"
mkdir "$exec_home/config/lavish-axi-supervisor-address"
if fm_lavish_supervisor_address_load "$exec_home" "$exec_home/config" 2> "$TMP_ROOT/err"; then
  fail "a directory in place of the supervisor address file loaded"
fi
pass "fm-lavish-address: a malformed or non-file supervisor address is refused, not used"

printf '\nall fm-lavish-address tests passed\n'
