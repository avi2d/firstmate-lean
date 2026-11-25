#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake Herdr pane,
# which records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. tests/fm-worker-account-live-e2e.test.sh proves those answers
# against the real runners.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 0
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
exit 2
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  cat > "$fakebin/clauth" <<SH
#!/usr/bin/env bash
printf "called\n" >> '$dir/clauth-calls'
[ "\$*" = 'status --json' ] || exit 2
[ -f '$dir/clauth-active' ] || exit 1
printf '{"schema":2,"active_profile":"%s","profiles":[{"name":"main"},{"name":"second"}]}\n' "\$(cat '$dir/clauth-active')"
SH
  chmod +x "$fakebin/claude" "$fakebin/pi" "$fakebin/clauth"
  cp "$fakebin/pi" "$fakebin/pi-signed"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  # A live record reserves its copy, so each task needs its own.
  WT="$CASE/wt-$id"
  [ -d "$WT" ] || git -C "$PROJ" worktree add --quiet -b "wt-$id" "$WT" >/dev/null 2>&1 ||
    fail "could not create a copy for $id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent-pi
  new_case absent-pi pi
  out=$(spawn_ship "$id" --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/pi-checks" "an unpinned spawn must not run a sign-in check"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves a Pi launch exactly as it was"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed pi
  mkdir -p "$CASE/work"
  for body in 'relative/root'$'\n''openai-codex' "$CASE/work"$'\r\n''openai-codex' '' 'ordinary' \
    'ordinary'$'\n''openai-codex'$'\n''extra' "$CASE/missing-root"$'\n''openai-codex'; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/pi-account"
    out=$(spawn_ship "$id-$n" --model openai-codex/gpt-5.5); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/pi-account"
  done
  rm "$HOME_DIR/config/pi-account"
  mkdir "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-dir" --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/pi-account must be a readable regular file"
  assert_absent "$CASE/pi-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, providerless, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope pi
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-pi" --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a Pi spawn must not report a Claude pin"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves a Pi launch unchanged"
}

test_claude_account_reaches_a_pi_claude_bridge_worker() {
  local out rc id=cacct-pi launch
  new_case pi-claude-account pi
  signed_in_claude_root "$CASE/second"
  printf '%s\n' "second $CASE/second" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id" --model claude-bridge/claude-opus-5-5 --claude-account second); rc=$?
  expect_code 0 "$rc" "a Pi claude-bridge spawn naming an account should succeed: $out"
  assert_contains "$out" "claude_account=second" "the spawn should report the account"
  launch=$(cat "$CASE/launch.log")
  assert_not_contains "$launch" "--provider" "an account alone must not add a Pi provider"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/second" "$CASE/pi-worker" "the bridge's Claude SDK should inherit the account's root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/pi-worker" "an ambient API key must not outrank the account"
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" "the account must leave Pi's own root alone"
  pass "--claude-account reaches a Pi claude-bridge worker through CLAUDE_CONFIG_DIR"
}

test_pi_claude_bridge_without_an_account_refuses_where_accounts_are_declared() {
  local out rc id=cacct-bridge-none
  new_case pi-bridge-no-account pi
  signed_in_claude_root "$CASE/main"
  signed_in_claude_root "$CASE/second"
  printf '%s\n' '# clauth profile -> login' "main $CASE/main" "second $CASE/second" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id" --harness pi --model claude-bridge/claude-opus-5-5 --effort high); rc=$?
  expect_code 1 "$rc" "a Pi claude-bridge ship with no account must refuse where accounts are declared: $out"
  assert_refused_before_launch "$id" "$out" "--model claude-bridge/claude-opus-5-5 needs --claude-account <name> (declared: main second)"
  WT="$CASE/wt-$id-scout"
  git -C "$PROJ" worktree add --quiet -b "wt-$id-scout" "$WT" >/dev/null 2>&1 || fail "could not create a copy for the scout"
  fm_test_spawn_brief "$HOME_DIR" "$id-scout"
  : > "$CASE/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id-scout" "$PROJ" --scout --harness pi --model claude-bridge/claude-opus-5-5); rc=$?
  expect_code 1 "$rc" "a Pi claude-bridge scout with no account must refuse where accounts are declared: $out"
  assert_refused_before_launch "$id-scout" "$out" "needs --claude-account <name>"
  out=$(spawn_ship "$id-named" --harness pi --model claude-bridge/claude-opus-5-5 --effort high --claude-account main); rc=$?
  expect_code 0 "$rc" "the same spawn naming an account should launch: $out"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/main" "$CASE/pi-worker" "the named account, not the pane's login, should reach the bridge"
  pass "a Pi claude-bridge spawn with no account refuses before launch where config/claude-accounts declares accounts"
}

test_pi_claude_bridge_without_an_account_is_unchanged_elsewhere() {
  local out rc id=cacct-bridge-kept
  new_case pi-bridge-no-map pi
  out=$(spawn_ship "$id-nomap" --harness pi --model claude-bridge/claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "with no config/claude-accounts a Pi claude-bridge spawn should launch as before: $out"
  printf '%s\n' '# no accounts yet' > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-empty" --harness pi --model claude-bridge/claude-opus-5-5); rc=$?
  expect_code 0 "$rc" "a map declaring no account should leave a Pi claude-bridge spawn as before: $out"
  printf '%s\n' "main $CASE/main" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-other" --harness pi --model openai-codex/gpt-6-luna); rc=$?
  expect_code 0 "$rc" "a Pi model on another provider needs no Claude account: $out"
  pass "a Pi claude-bridge spawn with no account is unchanged without declared accounts and off the bridge"
}

test_claude_account_ordinary_requires_clauth_to_report_it_active() {
  local out rc id=cacct-ordinary
  new_case ordinary-account pi
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  printf '%s\n' 'main ordinary' > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-noclauth" --model claude-bridge/claude-opus-5-5 --claude-account main); rc=$?
  expect_code 1 "$rc" "an ordinary account must refuse when clauth cannot confirm it"
  assert_refused_before_launch "$id-noclauth" "$out" "clauth status --json failed, so the ordinary login cannot be confirmed as main"
  printf 'second' > "$CASE/clauth-active"
  out=$(spawn_ship "$id-other" --model claude-bridge/claude-opus-5-5 --claude-account main); rc=$?
  expect_code 1 "$rc" "an ordinary account must refuse while another clauth profile is active"
  assert_refused_before_launch "$id-other" "$out" "which clauth reports is profile 'second'"
  printf 'main' > "$CASE/clauth-active"
  out=$(spawn_ship "$id" --model claude-bridge/claude-opus-5-5 --claude-account main); rc=$?
  expect_code 0 "$rc" "an ordinary account clauth reports active should launch: $out"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/pi-worker" "the ordinary account must drop an ambient root"
  pass "an ordinary account launches only while clauth reports that profile active"
}

test_named_account_without_subquo_row_must_not_call_clauth() {
  local out rc id=cacct-no-subquo
  new_case no-subquo pi
  signed_in_claude_root "$CASE/second"
  printf '%s\n' "second $CASE/second" > "$HOME_DIR/config/claude-accounts"
  printf '%s\n' '{"default":{"harness":"pi","model":"claude-bridge/claude-opus-5-5","provider":"claude","claude_account":"second"}}' > "$HOME_DIR/config/crew-dispatch.json"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/subquo"
  chmod +x "$FAKEBIN/subquo"
  out=$(spawn_ship "$id" --model claude-bridge/claude-opus-5-5 --claude-account second); rc=$?
  expect_code 0 "$rc" "the unavailable quota reading skips the gate: $out"
  assert_absent "$CASE/clauth-calls" "a named account with no subquo row must not call clauth"
  assert_contains "$out" 'quota gate skipped: subquo cannot verify account second' "the skip names the unavailable account reading"
  pass "a named account with no subquo row must not call clauth"
}

test_claude_account_refusals() {
  local out rc id=cacct-bad
  new_case account-refusals pi
  mkdir -p "$CASE/second"
  out=$(spawn_ship "$id-nomap" --model claude-bridge/claude-opus-5-5 --claude-account second); rc=$?
  expect_code 1 "$rc" "an account with no map must refuse"
  assert_refused_before_launch "$id-nomap" "$out" "--claude-account second needs a login declared for it in config/claude-accounts"
  printf '%s\n' "second $CASE/second" > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-out" --model claude-bridge/claude-opus-5-5 --claude-account second); rc=$?
  expect_code 1 "$rc" "a signed-out account root must refuse"
  assert_refused_before_launch "$id-out" "$out" "maps account second to $CASE/second, which is not signed in"
  out=$(spawn_ship "$id-undeclared" --model claude-bridge/claude-opus-5-5 --claude-account main); rc=$?
  expect_code 1 "$rc" "an undeclared account must refuse"
  assert_refused_before_launch "$id-undeclared" "$out" "--claude-account main needs a login declared"
  signed_in_claude_root "$CASE/second"
  out=$(spawn_ship "$id-codex" --harness "codex --print raw" --claude-account second); rc=$?
  expect_code 1 "$rc" "a codex spawn must refuse an account"
  assert_refused_before_launch "$id-codex" "$out" "--claude-account applies to the claude harness and to Pi claude-bridge models, not codex"
  out=$(spawn_ship "$id-pimodel" --harness pi --model openai-codex/gpt-6-luna --claude-account second); rc=$?
  expect_code 1 "$rc" "a Pi spawn on another provider must refuse an account"
  assert_refused_before_launch "$id-pimodel" "$out" "needs --model claude-bridge/<id>"
  out=$(spawn_ship "$id-raw" --harness "claude --print raw" --claude-account second); rc=$?
  expect_code 1 "$rc" "a raw launch must refuse an account"
  assert_refused_before_launch "$id-raw" "$out" "cannot carry --claude-account"
  printf '%s\n' 'second relative/root' > "$HOME_DIR/config/claude-accounts"
  out=$(spawn_ship "$id-malformed" --model claude-bridge/claude-opus-5-5 --claude-account second); rc=$?
  expect_code 1 "$rc" "a malformed account map must refuse"
  assert_refused_before_launch "$id-malformed" "$out" "config/claude-accounts line 1 must be"
  pass "--claude-account refuses unmapped, signed-out, undeclared, wrong-runner, raw, and malformed launches"
}

test_absent_pin_keeps_the_launch_unchanged
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_claude_account_reaches_a_pi_claude_bridge_worker
test_pi_claude_bridge_without_an_account_refuses_where_accounts_are_declared
test_pi_claude_bridge_without_an_account_is_unchanged_elsewhere
test_claude_account_ordinary_requires_clauth_to_report_it_active
test_claude_account_refusals
test_named_account_without_subquo_row_must_not_call_clauth

echo "# all fm-worker-account tests passed"
