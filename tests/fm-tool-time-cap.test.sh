#!/usr/bin/env bash
# Executes the Pi tool-time cap's input clamps, config reading and event
# handlers against synthetic fixtures, without a model or SDK install.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! results=$(
  cd "$ROOT"
  NODE_NO_WARNINGS=1 node --input-type=module-typescript <<'TS'
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_CAP_SECONDS, clampToolInput, isPrimarySession, readCap, registerToolTimeCap } from "./.pi/extensions/fm-primary-tool-time-cap.ts";

function check(name: string, body: () => void) {
  try {
    body();
  } catch (error) {
    console.error(`Assertion failed: ${name}`);
    throw error;
  }
  console.log(`pass\t${name}`);
}

const scratch = mkdtempSync(join(tmpdir(), "fm-tool-time-cap."));
const configWith = (text: string) => {
  const file = join(scratch, `cap-${Math.random()}`);
  writeFileSync(file, text);
  return file;
};

check("bash call without a timeout gets the cap instead of running unbounded", () => {
  const input: Record<string, unknown> = { command: "sleep 200" };
  assert.deepEqual(clampToolInput("bash", input, 90), { tool: "bash", requestedSeconds: undefined, capSeconds: 90 });
  assert.deepEqual(input, { command: "sleep 200", timeout: 90 });
});

check("bash timeout above the cap is lowered rather than trusted", () => {
  const input: Record<string, unknown> = { command: "sleep 200", timeout: 600 };
  assert.equal(clampToolInput("bash", input, 90)?.requestedSeconds, 600);
  assert.equal(input.timeout, 90);
});

check("bash timeout at or below the cap is kept rather than raised", () => {
  for (const timeout of [5, 90]) {
    const input: Record<string, unknown> = { command: "true", timeout };
    assert.equal(clampToolInput("bash", input, 90), undefined);
    assert.equal(input.timeout, timeout);
  }
});

check("codemode script without an options line gains one and keeps its source", () => {
  const code = "const r = await tools.bash({command: 'sleep 200'});\nreturn r.output;";
  const input: Record<string, unknown> = { code };
  assert.equal(clampToolInput("codemode", input, 90)?.requestedSeconds, undefined);
  assert.equal(input.code, `// @options: {"timeout_ms":90000}\n${code}`);
});

check("codemode timeout_ms above the cap is lowered and other options survive", () => {
  const input: Record<string, unknown> = { code: '// @options: {"max_output_tokens": 2000, "timeout_ms": 600000}\nreturn 1;' };
  assert.equal(clampToolInput("codemode", input, 90)?.requestedSeconds, 600);
  assert.equal(input.code, '// @options: {"max_output_tokens":2000,"timeout_ms":90000}\nreturn 1;');
});

check("codemode options without timeout_ms gain the cap and keep max_output_tokens", () => {
  const input: Record<string, unknown> = { code: '// @options: {"max_output_tokens": 50}\nreturn 1;' };
  assert.ok(clampToolInput("codemode", input, 90));
  assert.equal(input.code, '// @options: {"max_output_tokens":50,"timeout_ms":90000}\nreturn 1;');
});

check("codemode timeout_ms within the cap is kept rather than raised", () => {
  const code = '// @options: {"timeout_ms": 5000}\nreturn 1;';
  const input: Record<string, unknown> = { code };
  assert.equal(clampToolInput("codemode", input, 90), undefined);
  assert.equal(input.code, code);
});

check("other tools pass through untouched instead of gaining a timeout", () => {
  const input: Record<string, unknown> = { path: "/x" };
  assert.equal(clampToolInput("read", input, 90), undefined);
  assert.deepEqual(input, { path: "/x" });
});

check("cap config: absent uses 90, a valid integer wins, garbage falls back to 90 and says so", () => {
  assert.equal(DEFAULT_CAP_SECONDS, 90);
  assert.deepEqual(readCap(join(scratch, "absent")), { seconds: 90 });
  assert.deepEqual(readCap(configWith("30\n")), { seconds: 30 });
  for (const bad of ["abc", "0", "-5", "1.5", "86401"]) {
    const cap = readCap(configWith(bad));
    assert.equal(cap.seconds, 90, bad);
    assert.ok(cap.invalidConfig, bad);
  }
});

check("worker env or a foreign cwd is not treated as the primary session", () => {
  const ctx: any = { cwd: process.cwd() };
  assert.equal(isPrimarySession(ctx, {}, process.cwd()), true);
  assert.equal(isPrimarySession(ctx, { FM_TASK_ID: "t" }, process.cwd()), false);
  assert.equal(isPrimarySession(ctx, { FM_TASK_INBOX: "/i" }, process.cwd()), false);
  assert.equal(isPrimarySession(ctx, { FM_SUPERVISION_ACTOR: "branch" }, process.cwd()), false);
  assert.equal(isPrimarySession({ cwd: scratch } as any, {}, process.cwd()), false);
});

function harness(primary: boolean, configFile = join(scratch, "absent")) {
  const handlers = new Map<string, any>();
  const pi: any = { on(name: string, fn: any) { handlers.set(name, fn); } };
  registerToolTimeCap(pi, { configFile, isPrimary: () => primary });
  const ctx: any = { cwd: process.cwd() };
  return {
    call: (toolCallId: string, toolName: string, input: any, parentToolCallId?: string) =>
      handlers.get("tool_call")({ type: "tool_call", toolCallId, toolName, input, parentToolCallId }, ctx),
    result: (toolCallId: string, isError: boolean, parentToolCallId?: string) =>
      handlers.get("tool_result")({ type: "tool_result", toolCallId, parentToolCallId, isError,
        content: [{ type: "text", text: "out" }], structuredContent: { output: "out" } }, ctx),
  };
}

check("non-primary session keeps an unbounded bash call unchanged", () => {
  const h = harness(false);
  const input = { command: "sleep 200" };
  h.call("a", "bash", input);
  assert.deepEqual(input, { command: "sleep 200" });
  assert.equal(h.result("a", true), undefined);
});

check("lowered bash call tells the model why, and keeps structuredContent", () => {
  const h = harness(true);
  const input = { command: "sleep 200", timeout: 300 };
  assert.equal(h.call("a", "bash", input), undefined);
  assert.equal(input.timeout, 90);
  const patch = h.result("a", true);
  assert.match(patch.content[1].text, /asked for 300 s and was limited to 90 s/);
  assert.deepEqual(patch.structuredContent, { output: "out" });
});

check("defaulted bash call that succeeds carries no note rather than noise on every call", () => {
  const h = harness(true);
  h.call("a", "bash", { command: "true" });
  assert.equal(h.result("a", false), undefined);
});

check("defaulted bash call that fails names the cap so a timeout is explained", () => {
  const h = harness(true, configWith("5"));
  h.call("a", "bash", { command: "sleep 30" });
  assert.match(h.result("a", true).content[1].text, /asked for no time limit and was limited to 5 s/);
});

check("nested bash clamp is reported on the codemode result, not lost in the script", () => {
  const h = harness(true);
  const outer = { code: "return 1;" };
  h.call("c", "codemode", outer);
  const inner = { command: "sleep 200" };
  h.call("c/1", "bash", inner, "c");
  assert.equal(inner.command, "sleep 200");
  assert.equal((inner as any).timeout, 90);
  assert.equal(h.result("c/1", true, "c"), undefined);
  const text = h.result("c", true).content.at(-1).text;
  assert.match(text, /this codemode call asked for no time limit and was limited to 90 s/);
  assert.match(text, /a nested bash call asked for no time limit and was limited to 90 s/);
});

check("invalid config is named in the note instead of silently applying 90", () => {
  const h = harness(true, configWith("lots"));
  h.call("a", "bash", { command: "sleep 200", timeout: 500 });
  assert.match(h.result("a", true).content[1].text, /config\/tool-time-cap is invalid/);
});
TS
); then
  printf '%s\n' "$results" >&2
  fail 'tool-time cap assertions failed'
fi
while IFS=$'\t' read -r result name; do
  case "$result" in
    pass) pass "$name" ;;
    *) fail "unexpected tool-time cap assertion result: $result $name" ;;
  esac
done <<< "$results"
