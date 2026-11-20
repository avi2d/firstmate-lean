#!/usr/bin/env bash
# Classifier, render-decision, and real-Pi checks for Firstmate's collapsed operational rows.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-operational-row-collapse)
LIB_DIR="$ROOT/.pi/extensions/lib"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
# The steering doorbell names only the inbox basename, so this is the identity every
# check below expects for launch-brief and doorbell rows.
TASK_ID=collapse-task
TASK_INBOX="$TMP_ROOT/state/$TASK_ID.inbox"

pi_package_available() {
  command -v node >/dev/null 2>&1 && [ -f "$PI_PACKAGE_DIR/package.json" ]
}

make_lib_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/lib" "$dir/node_modules/@earendil-works"
  cp "$LIB_DIR/fm-calm-operational-user-layout.ts" "$LIB_DIR/fm-calm-visibility.ts" \
    "$LIB_DIR/fm-operational-input.ts" "$dir/lib/"
  ln -s "$PI_PACKAGE_DIR" "$dir/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$dir/node_modules/@earendil-works/pi-tui"
  printf '%s\n' '{"type":"module"}' >"$dir/package.json"
}

run_fixture_node() {  # <dir>; script on stdin
  (cd "$1" && \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    FM_TASK_INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh" \
    FM_TASK_INBOX="$TASK_INBOX" TASK_ID="$TASK_ID" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    node --input-type=module 2>&1)
}

test_classifier() {
  local fixture out
  if ! pi_package_available; then
    echo "skip: node or the installed Pi package not found for the operational-row classifier test"
    return 0
  fi
  fixture="$TMP_ROOT/classifier"
  make_lib_fixture "$fixture"
  out=$(run_fixture_node "$fixture" <<'JS'
import { execFileSync } from "node:child_process";
const rows = await import("./lib/fm-calm-operational-user-layout.ts");
const input = await import("./lib/fm-operational-input.ts");
const doorbellFor = (inbox) => execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, inbox], { encoding: "utf8" });
const expectRow = (text, kind, identity) => {
  const row = rows.classifyFirstmateOperationalRow(text);
  if (row?.kind !== kind || row?.identity !== identity) {
    throw new Error(`expected ${kind} "${identity}" for ${JSON.stringify(text.slice(0, 60))}, got ${JSON.stringify(row)}`);
  }
};
const firstLines = {
  "session-start": "Session digest headline",
  watcher: "FIRSTMATE WATCHER WAKE: signal: probe done",
  "turn-end-guard": "TURN WOULD END BLIND - supervision is off.",
  "away-supervisor": "Away digest headline",
  "from-firstmate": "Steer headline",
  "branch-outcome": "Supervision processing request headline",
};
for (const [kind, headline] of Object.entries(firstLines)) {
  expectRow(input.encodeFirstmateOperationalInput(kind, `\n${headline}\nFULL_BODY_LINE`), kind, headline);
}
expectRow(input.encodeFirstmateOperationalInput("launch-brief", "# Current worker role contract\nFULL_BODY_LINE"), "launch-brief", process.env.TASK_ID);
expectRow(doorbellFor(process.env.FM_TASK_INBOX), "steering-doorbell", process.env.TASK_ID);
expectRow("\u2063Supervisor escalate (legacy) headline", "away-supervisor", "Supervisor escalate (legacy) headline");

const watcher = input.encodeFirstmateOperationalInput("watcher", "FIRSTMATE WATCHER WAKE: signal: x");
const captainText = [
  "please explain the FIRSTMATE_OP: v1 watcher: marker",
  "FIRSTMATE_OP: v1 watcher: ASCII_ONLY_CAPTAIN_MESSAGE",
  `Captain quote: ${watcher}`,
  "\u2063FIRSTMATE_OP: v1 not-a-kind: body",
  "\u2063FIRSTMATE_OP: v1 watcher:",
  doorbellFor(`${process.env.FM_TASK_INBOX}-other`),
  `${doorbellFor(process.env.FM_TASK_INBOX)} and please also look at this`,
  ": Firstmate instruction waiting: please look",
];
for (const text of captainText) {
  const row = rows.classifyFirstmateOperationalRow(text);
  if (row !== undefined) throw new Error(`classified captain text ${JSON.stringify(text)} as ${JSON.stringify(row)}`);
}
JS
) || fail "operational-row classifier failed: $out"
  [ -z "$out" ] || fail "operational-row classifier printed output: $out"

  out=$(cd "$fixture" && env -u FM_TASK_INBOX \
    FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
    FM_TASK_INBOX_LIB="$ROOT/bin/fm-task-inbox-lib.sh" DOORBELL_INBOX="$TASK_INBOX" \
    node --input-type=module 2>&1 <<'JS'
import { execFileSync } from "node:child_process";
const rows = await import("./lib/fm-calm-operational-user-layout.ts");
const input = await import("./lib/fm-operational-input.ts");
const doorbell = execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, process.env.DOORBELL_INBOX], { encoding: "utf8" });
if (rows.classifyFirstmateOperationalRow(doorbell) !== undefined) {
  throw new Error("a doorbell line collapsed in a process with no steering inbox of its own");
}
const brief = rows.classifyFirstmateOperationalRow(input.encodeFirstmateOperationalInput("launch-brief", "\n# Charter headline\nbody"));
if (brief?.identity !== "Charter headline") throw new Error(`launch brief without an inbox used ${JSON.stringify(brief)}`);
JS
) || fail "operational-row classifier outside a Firstmate launch failed: $out"
  pass "every Firstmate operational kind and this process's own steering doorbell classify with a kind and short identity, while captain text that mentions the marker, a foreign or extended doorbell, and a doorbell outside a launch stay unclassified"
}

test_render_decision() {
  local fixture out
  if ! pi_package_available; then
    echo "skip: node or the installed Pi package not found for the operational-row render test"
    return 0
  fi
  fixture="$TMP_ROOT/render"
  make_lib_fixture "$fixture"
  out=$(run_fixture_node "$fixture" <<'JS'
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ InteractiveMode }, { UserMessageComponent }, { initTheme, theme }, { visibleWidth }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/interactive-mode.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/user-message.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
]);
initTheme("dark");
const layout = await import("./lib/fm-calm-operational-user-layout.ts");
const visibility = await import("./lib/fm-calm-visibility.ts");
const input = await import("./lib/fm-operational-input.ts");
layout.installCalmOperationalUserLayout();
layout.bindOperationalRowTheme(theme);

const strip = (line) => line.replace(/\x1b\[[0-9;]*m|\x1b\][^\x07]*\x07/g, "");
const doorbell = execFileSync("bash", ["-c", '. "$1" && fm_task_inbox_doorbell_line "$2/x.msg"', "_", process.env.FM_TASK_INBOX_LIB, process.env.FM_TASK_INBOX], { encoding: "utf8" });
const operational = [
  ["launch brief", input.encodeFirstmateOperationalInput("launch-brief", "# Current worker role contract\nFULL_TEXT_LAUNCH")],
  ["watcher wake", input.encodeFirstmateOperationalInput("watcher", "FIRSTMATE WATCHER WAKE: signal: x\n\nFULL_TEXT_WATCHER")],
  ["supervision request", input.encodeFirstmateOperationalInput("branch-outcome", "Processing request\nFULL_TEXT_BRANCH")],
  ["steering doorbell", doorbell],
];
const captain = "CAPTAIN_TYPED mentions FIRSTMATE_OP: v1 watcher: and must stay whole";

function chatMode(expanded) {
  return {
    chatContainer: { children: [], addChild(component) { this.children.push(component); } },
    editor: { addToHistory() {} },
    getMarkdownTransformers: () => [],
    getMarkdownThemeWithSettings: () => undefined,
    getUserMessageText: (message) => typeof message.content === "string"
      ? message.content
      : message.content.map((block) => block.text).join(""),
    outputPad: 1,
    toolOutputExpanded: expanded,
  };
}
const stockRows = (text) => ["", ...new UserMessageComponent(text, undefined, 1, []).render(100)];
const click = (y) => ({ type: "click", button: "left", x: 2, y, screenX: 2, screenY: 10 + y, width: 100, height: 4, shift: false, alt: false, ctrl: false });

const mode = chatMode(false);
mode.chatContainer.children.push({ render: () => ["PREDECESSOR"] });
for (const [, text] of operational) {
  InteractiveMode.prototype.addMessageToChat.call(mode, { role: "user", content: [{ type: "text", text }] });
}
InteractiveMode.prototype.addMessageToChat.call(mode, { role: "user", content: captain });
const [, ...added] = mode.chatContainer.children;
const captainRow = added.pop();

for (const [index, [label, text]] of operational.entries()) {
  const row = added[index];
  for (const width of [100, 40]) {
    const collapsed = row.render(width);
    if (collapsed.length !== 2 || collapsed[0] !== "") {
      throw new Error(`${label} did not collapse to its spacer and one line at width ${width}: ${JSON.stringify(collapsed)}`);
    }
    if (visibleWidth(collapsed[1]) > width) throw new Error(`${label} overflowed width ${width}`);
    if (strip(collapsed[1]).includes("FULL_TEXT") || strip(collapsed[1]).includes("instruction waiting")) {
      throw new Error(`${label} leaked its full text into the collapsed line`);
    }
  }
  const line = strip(row.render(100)[1]);
  if (!line.includes(`[firstmate] ${label}`) || !line.includes("to expand")) {
    throw new Error(`${label} collapsed line does not name its kind and expansion: ${line}`);
  }
  if ((label === "launch brief" || label === "steering doorbell") && !line.includes(process.env.TASK_ID)) {
    throw new Error(`${label} collapsed line does not name its task: ${line}`);
  }
  if (label === "watcher wake" && !line.includes("signal: x")) {
    throw new Error(`watcher collapsed line does not name its wake: ${line}`);
  }
  row.setExpanded(true);
  if (JSON.stringify(row.render(100)) !== JSON.stringify(stockRows(text))) {
    throw new Error(`${label} expanded row differs from Pi's stock user row`);
  }
  row.setExpanded(false);
  if (row.handleMouse(click(0)) !== undefined || row.render(100).length !== 2) {
    throw new Error(`${label} toggled from a click on its leading spacer`);
  }
  if (!row.handleMouse(click(1))?.handled || JSON.stringify(row.render(100)) !== JSON.stringify(stockRows(text))) {
    throw new Error(`${label} did not expand on a click`);
  }
  if (!row.handleMouse(click(1))?.handled || row.render(100).length !== 2) {
    throw new Error(`${label} did not collapse again on a second click`);
  }
}
if (JSON.stringify(captainRow.render(100)) !== JSON.stringify(new UserMessageComponent(captain, undefined, 1, []).render(100))) {
  throw new Error("captain text that mentions the marker did not render as Pi's stock user row");
}

const expandedMode = chatMode(true);
expandedMode.chatContainer.children.push({ render: () => ["PREDECESSOR"] });
InteractiveMode.prototype.addMessageToChat.call(expandedMode, { role: "user", content: operational[1][1] });
if (JSON.stringify(expandedMode.chatContainer.children[1].render(100)) !== JSON.stringify(stockRows(operational[1][1]))) {
  throw new Error("a row added while tools are expanded did not start expanded");
}

visibility.setCalmPresentation(true);
for (const [index, [label]] of operational.entries()) {
  const rendered = added[index].render(100);
  if (label === "steering doorbell") {
    if (rendered.length !== 2) throw new Error("Calm hid the plain-text steering doorbell instead of leaving it collapsed");
  } else if (rendered.length !== 0) {
    throw new Error(`Calm left the marker-carried ${label} row visible`);
  }
}
visibility.setCalmPresentation(false);
JS
) || fail "operational-row render decision failed: $out"
  [ -z "$out" ] || fail "operational-row render decision printed output: $out"
  pass "operational rows render as one themed in-width line under their spacer, expand to Pi's exact stock row by the expand control or a click, start expanded with tools expanded, stay hidden under Calm only when marker-carried, and captain text renders stock"
}


test_classifier
test_render_decision
