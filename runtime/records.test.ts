import { expect, test } from "bun:test";
import {
  decodeCrewDispatchConfig,
  decodePrPollRecord,
  decodeProjectRegistry,
  decodeRemoteHomeRegistry,
  decodeStatusLog,
  decodeTaskMeta,
} from "@avi2d/firstmate-runtime/records";

test("metadata keeps the last field and does not cut values at a second equals sign", () => {
  expect(decodeTaskMeta("mode=no-mistakes\nignored prose\nmode=direct-PR\nfuture=x=y")).toEqual({
    mode: "direct-PR",
    future: "x=y",
  });
});

test("status log does not lose continuation prose or the final unterminated event", () => {
  expect(decodeStatusLog("working: started\n\nreason: second line\nresolved: finished")).toEqual([
    "working: started", "", "reason: second line", "resolved: finished",
  ]);
  expect(decodeStatusLog("working: started\n")).toEqual(["working: started"]);
});

test("PR sidecar does not flatten a Gerrit project or accept conflicting fields", () => {
  const record = "gerrit\nhttps://review.example.com/c/tool/+/42\nreview.example.com\ntool\n42\n";
  expect(decodePrPollRecord(record)).toEqual({
    provider: "gerrit",
    url: "https://review.example.com/c/tool/+/42",
    host: "review.example.com",
    path: "tool",
    number: "42",
  });
  expect(() => decodePrPollRecord(record.replace("tool\n42", "tool\n43"))).toThrow();
  expect(() => decodePrPollRecord(record.slice(7))).toThrow();
});

test("project rows do not split names at spaces or discard an empty branch override", () => {
  expect(decodeProjectRegistry("# Projects\n- Tool Suite [host=west branch= direct-PR] - Release tools\n- Old project\n")).toEqual([
    { name: "Tool Suite", annotations: ["host=west", "branch=", "direct-PR"], description: "Release tools" },
    { name: "Old project", annotations: [], description: "" },
  ]);
});

test("remote routes do not require a session in an older record", () => {
  const row = "- west - WSL (host: westbox; root: /srv/firstmate; home: /srv/fleet; scope: workers; projects: demo; added 2026-11-20)";
  expect(decodeRemoteHomeRegistry(row)).toEqual([{
    id: "west", host: "westbox", root: "/srv/firstmate", home: "/srv/fleet",
    session: "fm-remote", scope: "workers", projects: "demo", added: "2026-11-20",
  }]);
  expect(() => decodeRemoteHomeRegistry(row.replace("scope:", "missing:"))).toThrow();
});

test("dispatch config does not coerce switches, discard legacy single profiles, or accept an empty choice", () => {
  expect(decodeCrewDispatchConfig('{"default":{"harness":"pi"}}')).toEqual({ default: { harness: "pi" } });
  expect(() => decodeCrewDispatchConfig('{"shared_quota":"false"}')).toThrow();
  expect(() => decodeCrewDispatchConfig('{"default":[]}')).toThrow();
});
