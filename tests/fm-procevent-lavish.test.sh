#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-lavish-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
new_home() { mkdir -p "$1/state"; fm_test_track_procevent_home "$1"; }

# Lavish's session store is the only record of an open board, so the fixture writes it directly.
lavish_session() {
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "${2:-http://127.0.0.1:14387/session/0123456789abcdef}"
}

LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
export LAVISH_RELEASE="$TMP_ROOT/lavish-release"
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" != --version ] || { printf '0.1.81\n'; exit 0; }
while [ ! -e "$LAVISH_RELEASE" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$LAVISH_BIN/lavish-axi"

UNOPENED_ART="$TMP_ROOT/unopened-board.html"
printf '<h1>unopened</h1>\n' > "$UNOPENED_ART"
UNOPENED_HOME="$TMP_ROOT/unopened-home"
new_home "$UNOPENED_HOME"
UNOPENED_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$UNOPENED_ART")

set +e
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$UNOPENED_ART" \
  > "$TMP_ROOT/unopened-arm.out" 2> "$TMP_ROOT/unopened-arm.err"
unopened_rc=$?
set -e
[ "$unopened_rc" -ne 0 ] \
  || fail "arm reported a board ready that Lavish has not opened"
assert_not_contains "$(cat "$TMP_ROOT/unopened-arm.out")" "armed: $UNOPENED_ID" \
  "arm printed a ready board for an unopened session"
assert_not_contains "$(cat "$TMP_ROOT/unopened-arm.out")" "registered:" \
  "arm registered a board Lavish has not opened"
assert_contains "$(cat "$TMP_ROOT/unopened-arm.err")" "lavish-axi $UNOPENED_ART" \
  "arm did not name the missing lavish-axi open step for an unopened board"
[ -s "$TMP_ROOT/unopened-arm.err" ] \
  || fail "arm refused an unopened board without a reason"
pass "arm refuses an unopened board with a reason instead of reporting it armed"
pass "arm refuses before registering and names the lavish-axi open step instead of failing on listener is not running"

UNOPENED_SRC_HOME="$TMP_ROOT/unopened-src-home"
new_home "$UNOPENED_SRC_HOME"
PATH="$LAVISH_BIN:$PATH" pe "$UNOPENED_SRC_HOME" register lavish "$UNOPENED_ID" -- \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$UNOPENED_ART" >/dev/null
set +e
PATH="$LAVISH_BIN:$PATH" pe "$UNOPENED_SRC_HOME" ensure-listening "$UNOPENED_ID" \
  > "$TMP_ROOT/unopened-ensure.out" 2> "$TMP_ROOT/unopened-ensure.err"
unopened_ensure_rc=$?
set -e
[ "$unopened_ensure_rc" -ne 0 ] \
  || fail "ensure-listening reported a running listener for an unopened board"
[ -s "$TMP_ROOT/unopened-ensure.err" ] \
  || fail "ensure-listening refused an unopened board without a reason"
pass "ensure-listening reports a listener that never attached as not running"

lavish_session "$UNOPENED_ART"
set +e
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$UNOPENED_ART" \
  > "$TMP_ROOT/opened-arm.out" 2> "$TMP_ROOT/opened-arm.err"
opened_rc=$?
set -e
[ "$opened_rc" -eq 0 ] \
  || fail "arm did not attach after the board was opened: $(cat "$TMP_ROOT/opened-arm.err")"
assert_contains "$(cat "$TMP_ROOT/opened-arm.out")" "armed: $UNOPENED_ID" \
  "arm did not report the attached board as armed"
pass "a board opened after a refused arm attaches on the next arm"
assert_contains "$(cat "$TMP_ROOT/opened-arm.out")" "board-url: http://127.0.0.1:14387/session/0123456789abcdef" \
  "arm in an ordinary home did not print the board's own session URL"
assert_not_contains "$(cat "$TMP_ROOT/opened-arm.out")" "note: this board URL" \
  "arm in an ordinary home warned about an execution host"
pass "arm in an ordinary home prints the saved session URL unchanged, not a rewritten one"

arm_exec_board() {  # <name> <supervisor-address-or-empty>
  local home="$TMP_ROOT/exec-$1" art="$TMP_ROOT/exec-$1.html"
  new_home "$home"
  : > "$home/.fm-exec-home"
  if [ -n "$2" ]; then
    mkdir -p "$home/config"
    printf '%s\n' "$2" > "$home/config/lavish-axi-supervisor-address"
  fi
  printf '<h1>%s</h1>\n' "$1" > "$art"
  lavish_session "$art" "http://127.0.0.1:4387/session/fedcba9876543210?token=t1"
  PATH="$LAVISH_BIN:$PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$art" \
    > "$TMP_ROOT/exec-$1.out" 2> "$TMP_ROOT/exec-$1.err"
}

EXEC_SUPERVISOR_ADDRESS=127.0.0.1:24387
arm_exec_board configured "$EXEC_SUPERVISOR_ADDRESS" \
  || fail "arm in a configured execution home failed: $(cat "$TMP_ROOT/exec-configured.err")"
assert_contains "$(cat "$TMP_ROOT/exec-configured.out")" \
  "board-url: http://$EXEC_SUPERVISOR_ADDRESS/session/fedcba9876543210?token=t1" \
  "arm in an execution home did not carry the board URL on the configured supervisor address"
assert_not_contains "$(cat "$TMP_ROOT/exec-configured.out")" "127.0.0.1:4387" \
  "arm in an execution home printed the host's own Lavish address"
pass "arm in a configured execution home prints the supervisor address, not the host's own 4387"

arm_exec_board unconfigured "" \
  || fail "arm in an unconfigured execution home failed: $(cat "$TMP_ROOT/exec-unconfigured.err")"
assert_contains "$(cat "$TMP_ROOT/exec-unconfigured.out")" \
  "board-url: http://127.0.0.1:4387/session/fedcba9876543210?token=t1" \
  "arm in an unconfigured execution home did not keep the saved session URL"
assert_contains "$(cat "$TMP_ROOT/exec-unconfigured.out")" "note: this board URL is on the execution host's own Lavish server" \
  "arm in an unconfigured execution home handed out the host's address without saying so"
pass "arm in an unconfigured execution home keeps the host URL and warns, not silently"

if arm_exec_board malformed "127.0.0.1:4387 extra"; then
  fail "arm accepted a malformed config/lavish-axi-supervisor-address"
fi
assert_contains "$(cat "$TMP_ROOT/exec-malformed.err")" "config/lavish-axi-supervisor-address" \
  "arm refused a malformed supervisor address without naming the file"
assert_not_contains "$(cat "$TMP_ROOT/exec-malformed.out")" "armed:" \
  "arm registered a board before rejecting a malformed supervisor address"
pass "arm refuses a malformed supervisor address before registering, not with a bad URL"

touch "$LAVISH_RELEASE"
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$UNOPENED_ART" >/dev/null 2>&1 || true
for exec_name in configured unconfigured; do
  PATH="$LAVISH_BIN:$PATH" FM_HOME="$TMP_ROOT/exec-$exec_name" \
    "$ROOT/bin/fm-procevent-lavish.sh" retire "$TMP_ROOT/exec-$exec_name.html" >/dev/null 2>&1 || true
done

SD_ROOT="$TMP_ROOT/state-dir"
SD_HOME="$SD_ROOT/home"
SD_CUSTOM="$SD_ROOT/custom"
mkdir -p "$SD_HOME/.lavish-axi" "$SD_CUSTOM"
SD_BIN=$(fm_fakebin "$SD_ROOT/lavish-stub")
cat > "$SD_BIN/lavish-axi" <<SH
#!/usr/bin/env bash
[ "\${1-}" != --version ] || { printf '0.1.81\n'; exit 0; }
log="$SD_ROOT/polls-\$(basename "\${2-}" .html).log"
printf 'port=%s state_dir=%s\n' "\$LAVISH_AXI_PORT" "\${LAVISH_AXI_STATE_DIR-unset}" >> "\$log"
if [ "\$(wc -l < "\$log")" -le 2 ]; then printf 'session:\n  status: browser_disconnected\n'; exit 0; fi
while [ ! -e "$SD_ROOT/release" ]; do
  [ "\$SECONDS" -lt "\${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$SD_BIN/lavish-axi"
sd_session() {  # <store-dir> <artifact> <port>
  perl -MJSON::PP -MCwd=realpath -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$real} = { key => "k", file => $real, status => "open", url => $url };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$1/state.json" "$2" "http://127.0.0.1:$3/session/0123456789abcdef"
}
sd_run() { env -u LAVISH_AXI_STATE_DIR HOME="$SD_HOME" PATH="$SD_BIN:$PATH" "$@"; }
sd_poll() {  # <board-name> <poll-number> [command retried until that poll arrives...]
  local log="$SD_ROOT/polls-$1.log" n=$2 _
  shift 2
  for _ in $(seq 100); do
    [ "$({ wc -l < "$log"; } 2>/dev/null || echo 0)" -ge "$n" ] && { sed -n "${n}p" "$log"; return 0; }
    [ "$#" -eq 0 ] || "$@" >/dev/null 2>&1 || true
    sleep 0.2
  done
  printf 'board %s never reached poll %s\n' "$1" "$n"
}

SD_ART="$SD_ROOT/own.html"
printf '<h1>own server</h1>\n' > "$SD_ART"
sd_session "$SD_HOME/.lavish-axi" "$SD_ART" 14001
sd_session "$SD_CUSTOM" "$SD_ART" 14002
SD_FM="$SD_ROOT/fm-home"
new_home "$SD_FM"
sd_run LAVISH_AXI_STATE_DIR="$SD_CUSTOM" FM_HOME="$SD_FM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$SD_ART" >/dev/null \
  || fail "arm against a non-default Lavish server failed"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 1)" \
  "the first listener did not poll the board's own server"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 2 sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent.sh" reconcile)" \
  "a listener restart without LAVISH_AXI_STATE_DIR polled the default server"
pass "a listener restart without LAVISH_AXI_STATE_DIR re-arms against the board's own server, not the default"

sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" arm "$SD_ART" >/dev/null \
  || fail "a hand re-arm without LAVISH_AXI_STATE_DIR failed"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 3)" \
  "a hand re-arm without LAVISH_AXI_STATE_DIR polled the default server"
pass "a hand re-arm without LAVISH_AXI_STATE_DIR keeps the board's recorded server instead of the default"

SD_OLD_ART="$SD_ROOT/old.html"
printf '<h1>pre-fix registration</h1>\n' > "$SD_OLD_ART"
sd_session "$SD_HOME/.lavish-axi" "$SD_OLD_ART" 14001
sd_session "$SD_CUSTOM" "$SD_OLD_ART" 14002
SD_OLD_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$SD_OLD_ART")
pe "$SD_FM" register lavish "$SD_OLD_ID" -- \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$SD_OLD_ART" >/dev/null
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent.sh" ensure-listening "$SD_OLD_ID" >/dev/null 2>&1 || true
assert_equals "port=14001 state_dir=unset" "$(sd_poll old 1)" \
  "a registration without a recorded state dir left the default server"
pass "a registration without a recorded state dir still polls the default server"

touch "$SD_ROOT/release"
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" retire "$SD_ART" >/dev/null 2>&1 || true
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" retire "$SD_OLD_ART" >/dev/null 2>&1 || true

printf '\nall procevent-lavish tests passed\n'
