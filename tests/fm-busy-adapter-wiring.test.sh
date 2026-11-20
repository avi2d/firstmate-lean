#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_single_herdr_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  fm_test_run_single_herdr_spawn "$home" "$wt" "$fakebin" "$@" --harness pi --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  local target
  target=$(sed -n 's/^window=//p' "$3/$2.meta")
  fm_busy_classify herdr "$target" "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" STOP_TEXT="${3-}" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: (name, fn) => { handlers[name] = fn; } } });
const ctx = {
  isIdle: () => process.env.MODE !== "settle-continuing",
  model: { provider: "openrouter" },
  sessionManager: {
    getEntries: () => process.env.MODE === "provider-limit"
      ? [{ type: "message", message: { role: "assistant", stopReason: "error", errorMessage: process.env.STOP_TEXT } }]
      : [],
  },
};
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "provider-limit": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  case "progress": await handlers["codex-native:progress"]({ type: "commandExecution", phase: "completed" }); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (["turn-end", "progress"].includes(process.env.MODE)) {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

# drive_pi_ext_shutdown <ext-path> <scenario> [entries-json]: load the
# generated Pi extension in a plain Node host behind a Pi-faithful runner:
# every pi and ctx getter throws the installed Pi 1.2.0 stale-context error
# once the runner is invalidated, and session_shutdown is delivered before
# invalidation exactly as Pi's teardown does. Scenarios: live-start (no
# shutdown), settle-quota (shutdown lands while the quota lookup is in
# flight), start-exclusion (shutdown lands while agent_start is in flight).
drive_pi_ext_shutdown() {
  EXT_PATH="$1" SCENARIO="$2" ENTRIES_JSON="$3" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = {};
const runner = {
  stale: null,
  assertActive() {
    if (this.stale) throw new Error(this.stale);
  },
};
const entries = JSON.parse(process.env.ENTRIES_JSON || "[]");
const ctx = {
  isIdle() { runner.assertActive(); return true; },
  get sessionManager() { runner.assertActive(); return { getEntries: () => entries }; },
  get model() { runner.assertActive(); return { provider: "openrouter" }; },
};
const pi = {
  on(name, fn) { handlers[name] = fn; },
  getAllTools() { runner.assertActive(); return [{ name: "read" }, { name: "bash" }]; },
  events: { on() {} },
};
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
await mod.default(pi);
const shutdown = async () => {
  if (handlers["session_shutdown"]) {
    await handlers["session_shutdown"]({ type: "session_shutdown", reason: "reload" }, ctx);
  }
  runner.stale = "This extension ctx is stale after session replacement or reload.";
};
switch (process.env.SCENARIO) {
  case "live-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "settle-quota":
  case "start-exclusion": {
    const pending = process.env.SCENARIO === "settle-quota"
      ? handlers["agent_settled"]({ type: "agent_settled", aborted: false }, ctx)
      : handlers["agent_start"]({ type: "agent_start" }, ctx);
    await shutdown();
    await pending;
    break;
  }
  default: throw new Error("unknown scenario " + process.env.SCENARIO);
}
EOF
}

test_pi_extension_session_shutdown_stops_stale_reads() {
  local rec id=busy-pi-shutdown out state ext entries
  rec=$(make_spawn_case pi-shutdown "$id")
  read_case_record "$rec"
  quota_stub="$HOME_DIR/quota-stub-bin"
  quota_marker="$HOME_DIR/quota-called"
  mkdir -p "$quota_stub"
  rm -f "$quota_marker"
  cat > "$quota_stub/quota-axi" <<SH
#!/usr/bin/env bash
echo called >> "$quota_marker"
printf '%s' '{"providers":[]}'
SH
  chmod +x "$quota_stub/quota-axi"
  echo some-missing-tool > "$HOME_DIR/config/crew-exclude-tools"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(drive_pi_ext_shutdown "$ext" live-start "[]") || fail "live agent_start drive failed: $out"
  assert_not_contains "$out" "stale" "live agent_start raised a stale-context error"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "live agent_start must classify 'busy pi-ext', got '$out'"
  assert_contains "$(cat "$state/$id.status")" "some-missing-tool" "the live exclusion check did not warn about the unmatched entry"

  entries='[{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"OpenRouter daily usage limit reached"}}]'
  out=$(PATH="$quota_stub:$PATH" drive_pi_ext_shutdown "$ext" settle-quota "$entries") || fail "shutdown settle drive failed: $out"
  assert_not_contains "$out" "stale" "a settle resumed after session_shutdown touched the dead context"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle resumed after session_shutdown must record nothing, got '$out'"
  [ -f "$quota_marker" ] || fail "settle-quota never reached the quota lookup"

  out=$(drive_pi_ext_shutdown "$ext" start-exclusion "[]") || fail "shutdown agent_start drive failed: $out"
  assert_not_contains "$out" "stale" "an agent_start resumed after session_shutdown read the dead registry"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "an agent_start resumed after session_shutdown must record nothing new, got '$out'"
  pass "pi extension snapshots pi and ctx before awaits and records nothing after session_shutdown"
}

test_pi_provider_limit_uses_session_reset_and_clears_on_work() {
  local rec id=busy-pi-provider-stop out state ext future reset expected
  rec=$(make_spawn_case pi-provider-limit "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  future=2099-01-02T03:04:05Z
  out=$(drive_pi_ext "$ext" provider-limit "OpenRouter daily usage limit reached; reset at $future") \
    || fail "provider-limit drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "paused pi-ext" ] || fail "worker-session usage-limit stop should classify paused, got '$out'"
  reset=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^reset=/) {sub(/^reset=/, "", $i); print $i}}' "$state/$id.busy-state")
  expected=$(node -e 'process.stdout.write(String(Date.parse(process.argv[1]) / 1000))' "$future")
  [ "$reset" = "$expected" ] || fail "session reset timestamp was not recorded exactly: $reset != $expected"
  out=$(drive_pi_ext "$ext" agent-start) || fail "agent-start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "later worker activity must clear the provider wait, got '$out'"
  cat > "$FAKEBIN_DIR/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"providers":[{"provider":"openrouter","resetsAt":"2099-01-02T03:04:05Z"}]}'
SH
  chmod +x "$FAKEBIN_DIR/quota-axi"
  PATH="$FAKEBIN_DIR:$PATH" drive_pi_ext "$ext" provider-limit \
    "OpenRouter daily usage limit reached" || fail "quota fallback drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "paused pi-ext" ] || fail "quota resetsAt fallback should classify paused, got '$out'"
  reset=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^reset=/) {sub(/^reset=/, "", $i); print $i}}' "$state/$id.busy-state")
  [ "$reset" = "$expected" ] || fail "quota-axi resetsAt was not recorded: $reset != $expected"
  pass "Pi worker-session usage-limit stops retain session or quota reset times and later activity clears the wait"
}

test_pi_stream_extension_activation_and_lifecycle() {
  local rec id=stream-pi state ext out version option enabled label
  for label in disabled zero negative malformed leading maximum overflow verified newer malformed-version older; do
    version=1.2.0 option=300 enabled=1
    case "$label" in
      disabled) option='' enabled=0 ;;
      zero) option=0 enabled=0 ;;
      negative) option=-1 enabled=0 ;;
      malformed) option=invalid enabled=0 ;;
      leading) option=00300 ;;
      maximum) option=999999999 ;;
      overflow) option=1000000000 enabled=0 ;;
      newer) version=1.3.0 enabled=0 ;;
      malformed-version) version=not-a-version enabled=0 ;;
      older) version=0.82.0 enabled=0 ;;
    esac
    rec=$(make_spawn_case "stream-$label" "$id")
    read_case_record "$rec"
    cat > "$FAKEBIN_DIR/pi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then printf '%s\\n' '$version'; fi
exit 0
SH
    chmod +x "$FAKEBIN_DIR/pi"
    out=$(FM_STREAM_SILENT_MAX_SECS="$option" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
    expect_code 0 $? "stream spawn should succeed: $out"
    case "$label" in
      newer|older|malformed-version)
        printf '%s\n' "$out" | grep -Fx "warning: pi model-stream observation unavailable for version $version; verified version: 1.2.0; existing busy bound remains active" >/dev/null || fail "missing exact version warning"
        ;;
    esac
    state="$HOME_DIR/state"
    ext="$state/$id.pi-ext.ts"
    STREAM_STATE="$state" STREAM_ID="$id" STREAM_ENABLED="$enabled" EXT_PATH="$ext" node --input-type=module <<'JS' || fail "generated stream lifecycle failed for $label"
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync } from "node:fs";
const { default: extension } = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
extension({on: (name, fn) => { handlers[name] = fn; }, events: { on() {} }});
const state = process.env.STREAM_STATE, id = process.env.STREAM_ID;
const marker = state + "/" + id + ".model-stream";
let idle = true;
const ctx = {isIdle: () => idle};
let clock = 10000;
Date.now = () => clock;
const fire = async (name, event = {}) => { await handlers[name]?.(event, ctx); };
const assert = (ok, message) => { if (!ok) throw new Error(message); };
await fire("agent_start");
await fire("context", {messages: []});
if (process.env.STREAM_ENABLED !== "1") {
  assert(!existsSync(marker), "disabled/unverified worker produced stream evidence");
  for (const name of ["context", "message_update", "message_end", "tool_execution_start"]) {
    assert(!handlers[name], "unverified worker installed stream handler " + name);
  }
} else {
  assert(existsSync(marker), "foreground context did not open stream evidence");
  const initial = readFileSync(marker, "utf8");
  await fire("message_update", {message: {role: "assistant", content: [{type:"text",text:""}]}});
  assert(readFileSync(marker,"utf8") === initial, "empty event refreshed stream");
  await fire("message_update", {message: {role: "assistant", content: [{type:"thinking",thinking:"reason"}]}});
  const progressed = readFileSync(marker,"utf8");
  assert(progressed !== initial, "thinking did not advance progress");
  await fire("message_update", {message: {role: "assistant", content: [{type:"text",text:"token"}]}});
  assert(readFileSync(marker,"utf8") === progressed, "unthrottled content event");
  clock += 1001;
  await fire("message_update", {message: {role: "assistant", content: [{type:"toolCall",name:"bash",arguments:{command:"true"}}]}});
  assert(readFileSync(marker,"utf8") !== progressed, "tool arguments did not advance progress");
  const last = readFileSync(marker,"utf8");
  clock += 1001;
  await fire("message_update", {message: {role: "assistant", content: [{type:"toolCall",name:"bash",arguments:{command:"true"}}]}});
  assert(readFileSync(marker,"utf8") === last, "unchanged content refreshed progress after throttle");
  idle = false;
  await fire("agent_settled");
  assert(readFileSync(marker,"utf8") === last, "continuing settlement closed active request");
  idle = true;
  await fire("message_end", {message: {role:"user"}});
  assert(existsSync(marker), "user message end closed assistant stream");
  await fire("message_end", {message: {role:"assistant"}});
  assert(!existsSync(marker), "assistant end left stream open");
  clock += 1001;
  await fire("message_update", {message: {role:"assistant", content:[{type:"text",text:"late"}]}});
  assert(!existsSync(marker), "late event resurrected closed stream");
  await fire("context", {messages: []});
  assert(existsSync(marker), "retry did not open new stream");
  const retry = readFileSync(marker,"utf8");
  const closing = fire("message_end", {message: {role:"assistant"}});
  const opening = fire("context", {messages: []});
  await Promise.all([closing, opening]);
  assert(existsSync(marker) && readFileSync(marker,"utf8") !== retry, "overlapping close/open lost new request");
  await fire("tool_execution_start");
  assert(!existsSync(marker), "tool phase retained stream");
  await fire("context", {messages: []});
  await fire("agent_settled");
  assert(!existsSync(marker), "settlement retained stream");
}
JS
  done
  pass "generated Pi wiring gates stream observation and clears model phases without accepting late updates"
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" progress) || fail "native progress drive failed: $out"
  [ -f "$state/$id.progress" ] || fail "native progress did not write its separate marker"
  [ ! -e "$state/$id.turn-ended" ] || fail "native progress fabricated a completed turn"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "native progress changed semantic state: $out"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  out=$(drive_pi_ext "$ext" progress) || fail "stale progress drive failed: $out"
  [ ! -e "$state/$id.progress" ] || fail "stale native progress refreshed the new incarnation"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

test_pi_provider_limit_uses_session_reset_and_clears_on_work
test_pi_stream_extension_activation_and_lifecycle
test_pi_extension_semantic_lifecycle
test_pi_extension_session_shutdown_stops_stale_reads
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected

echo "all fm-busy-adapter-wiring tests passed"
