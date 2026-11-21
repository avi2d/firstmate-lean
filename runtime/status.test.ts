import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { classifyStatusLine, classifyStatusLog, statusLineEpoch } from "@avi2d/firstmate-runtime/status";

const lineCases = [
  ["keeps prose about a merge quiet", "working: rebased onto merged main", true, false, false],
  ["surfaces a terminal declaration with an unreadable stamp", "done [at=10:30]: shipped", true, true, false],
  ["keeps a legacy bare merge visible", "  MERGED into default", true, true, false],
  ["does not mistake a clock time for a declaration", "10:30 local", false, false, false],
  ["does not mistake a prose label for an unknown lowercase verb", "Reason: jobs are busy", false, false, false],
  ["does not hide a misspelled wait verb", "parked: still working", true, true, false],
  ["does not erase a malformed correlation token", "working corr=broken: waiting", true, true, false],
  ["does not treat a valid correlation token as part of the verb", "working corr=abcd1234abcd1234: PR ready", true, false, false],
  ["keeps a followup visible without treating it as terminal", "followup: improve docs", true, false, true],
] as const;

for (const [title, raw, event, captainRelevant, unreadSurface] of lineCases) {
  test(title, () => {
    expect(classifyStatusLine(raw)).toMatchObject({ event, captainRelevant, unreadSurface });
  });
}

const logCases = [
  {
    name: "does not let an unrelated resolution hide a keyed pause",
    lines: ["paused [key=ci]: running", "resolved [key=docs]: answered", "more context"],
    wait: "paused [key=ci]: running",
    current: "paused [key=ci]: running",
  },
  {
    name: "does not keep a pause after resolution of its own key",
    lines: ["paused [key=ci]: running", "resolved [key=ci]: finished"],
    wait: "",
    current: "resolved [key=ci]: finished",
  },
  {
    name: "does not equate a keyless pause with an explicit default key",
    lines: ["paused: running", "resolved [key=default]: different phase"],
    wait: "paused: running",
    current: "paused: running",
  },
  {
    name: "does not hide a blocked decision behind unrelated progress",
    lines: ["blocked [at=10:30]: [key=design] bring a decision", "working: other work"],
    wait: "",
    current: "blocked [key=design]: bring a decision",
  },
  {
    name: "does not let bare terminal prose clear an open decision",
    lines: ["needs-decision [key=api]: pick a shape", "done"],
    wait: "",
    current: "needs-decision [key=api]: pick a shape",
  },
  {
    name: "does not let a later resolution retain an older captain hold",
    lines: ["captain-held [key=api]: pick a shape", "resolved [key=other]: answered"],
    wait: "",
    current: "resolved [key=other]: answered",
  },
  {
    name: "does not leave an open decision after a known ship fails",
    lines: ["needs-decision [key=api]: pick a shape", "failed: exited"],
    wait: "",
    current: "failed: exited",
  },
] as const;

const shellClassifier = fileURLToPath(new URL("../bin/fm-classify-lib.sh", import.meta.url));

for (const { name, lines, wait, current } of logCases) {
  test(name, () => {
    const fixture = lines.join("\n");
    const status = classifyStatusLog(fixture, { kind: "ship" });
    expect(status.declaredWait ?? "").toBe(wait);
    expect(status.current).toBe(current);

    const scratch = mkdtempSync(join(tmpdir(), "fm-status-replay."));
    try {
      const statusFile = join(scratch, "task.status");
      writeFileSync(statusFile, fixture);
      const replay = Bun.spawnSync([
        "bash", "-c",
        'source "$1"; printf "%s\\n" "$(status_declared_wait_line "$2")" "$(status_current_line "$2" ship)" "$(last_status_line "$2")"',
        "bash", shellClassifier, statusFile,
      ]);
      expect(replay.stderr.toString()).toBe("");
      expect(replay.exitCode).toBe(0);
      expect(replay.stdout.toString()).toBe([wait, current, status.latestEvent ?? "", ""].join("\n"));
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  });
}

test("does not infer an epoch from multiple, noncanonical, or note-only stamps", () => {
  expect(statusLineEpoch("working [at=1788576000]: running")).toBe(1788576000);
  expect(statusLineEpoch("working [at=1788576000] [at=1]: running")).toBeUndefined();
  expect(statusLineEpoch("working [at=001]: running")).toBeUndefined();
  expect(statusLineEpoch("working: trace [at=1]")).toBeUndefined();
});

test("does not let an unrelated note close a reserved decision", () => {
  const options = { reservedPrefixes: ["pending-"] };
  const opener = "blocked [key=pending-reply]: pending-reply: awaiting a response";
  const forgedClose = "resolved [key=pending-reply]: other work";
  const ownerClose = "resolved [key=pending-reply]: pending-reply: response arrived";
  expect(classifyStatusLog(opener + "\n" + forgedClose, options).decisions).toHaveLength(1);
  expect(classifyStatusLog(opener + "\n" + ownerClose, options).decisions).toHaveLength(0);
  expect(classifyStatusLine(ownerClose, options).unreadSurface).toBe(true);
  expect(classifyStatusLine(forgedClose, options).unreadSurface).toBe(false);
});
