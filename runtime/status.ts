import { Schema } from "effect";
import { decodeStatusLog } from "./records";

export const StatusVerb = Schema.Literals([
  "working", "needs-decision", "blocked", "done", "failed", "note", "followup",
  "paused", "resolved", "captain-held",
]);
export const DecisionKey = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9._-]+$/));
export const StatusEpoch = Schema.String.check(Schema.isPattern(/^(?:0|[1-9][0-9]{0,11})$/));
const isVerb = Schema.is(StatusVerb);
const isKey = Schema.is(DecisionKey);
const isEpoch = Schema.is(StatusEpoch);

const terminalVerbs = new Set(["done", "needs-decision", "blocked", "failed"]);
const legacyPattern = /done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged/i;
const leadingLegacyPattern = new RegExp(String.raw`^[ \t\r\v\f]*(?:${legacyPattern.source})`, "i");
const keylessPhase = Symbol("keyless phase");

type Options = {
  readonly kind?: "ship" | "scout" | "unknown";
  readonly reservedPrefixes?: ReadonlyArray<string>;
};

type Decision = {
  readonly key: string;
  readonly verb: "needs-decision" | "blocked";
  readonly note: string;
};

function trimStart(line: string): string {
  return line.replace(/^[ \t\r\v\f]+/, "");
}

function statusVerb(line: string): string {
  const [head = ""] = line.split(/[:\[]/, 1);
  const prefix = trimStart(head).replace(/[ \t\r\v\f]+$/, "");
  const words = prefix.split(/[ \t\r\v\f]+/);
  const stripped = prefix.includes("corr=")
    ? words.filter((word, i) => i === 0 || !/^corr=[0-9a-fA-F]{16}$/.test(word)).join(" ")
    : prefix;
  const bareEpoch = /^[0-9]+[ \t\r\v\f]+(.*)$/.exec(stripped)?.[1];
  return bareEpoch !== undefined && isVerb(bareEpoch.split(/[ \t\r\v\f]+/)[0]) ? bareEpoch : stripped;
}

function withoutStatusStamps(raw: string): string {
  let kept = "";
  let rest = raw;
  while (true) {
    const stamp = rest.indexOf("[at=");
    const close = rest.indexOf("]", stamp + 4);
    if (stamp < 0 || close < 0) return kept + rest;
    const before = rest.slice(0, stamp);
    if (before.includes(":")) return kept + rest;
    kept += before.replace(/ $/, "");
    rest = rest.slice(close + 1);
  }
}

function hasUnrecognizedPrefix(unstamped: string): boolean {
  const colon = unstamped.indexOf(":");
  if (colon < 0 || !/^(?:[ \t\r\v\f]|$)/.test(unstamped.slice(colon + 1))) return false;
  const verb = statusVerb(unstamped);
  if (isVerb(verb)) return false;
  const [first = "", ...rest] = verb.split(/[ \t\r\v\f]+/);
  if (rest.length === 0) return /^[a-z][a-z-]*$/.test(first);
  const isBadCorrelation = (word: string) => /^corr(?:=|$)/.test(word);
  if (isBadCorrelation(first)) {
    const [next, ...remaining] = rest;
    return isVerb(next) && remaining.every(isBadCorrelation);
  }
  return isVerb(first) && rest.every(isBadCorrelation);
}

function decisionFields(unstamped: string) {
  const colon = unstamped.indexOf(":");
  const head = colon < 0 ? unstamped : unstamped.slice(0, colon);
  const headKey = /\[key=([^\]]*)\]/.exec(head)?.[1];
  const rawNote = colon < 0 ? unstamped : trimStart(unstamped.slice(colon + 1));
  const noteKey = colon < 0 ? undefined : /^\[key=([^\]]*)\]/.exec(rawNote)?.[1];
  const statedKey = headKey ?? noteKey;
  const note = headKey === undefined && isKey(noteKey)
    ? trimStart(rawNote.slice("[key=]".length + noteKey.length))
    : rawNote;
  return { statedKey, note, transition: colon >= 0 || headKey !== undefined };
}

function reservedPrefix(key: string, options: Options): string | undefined {
  return options.reservedPrefixes?.find((prefix) => key.startsWith(prefix));
}

function speaksForPrefix(note: string, prefix: string): boolean {
  return note.startsWith(prefix) && note.indexOf(":", prefix.length) >= 0;
}

export function statusLineEpoch(line: string): number | undefined {
  const [head = ""] = line.split(":", 1);
  const stamp = /\[at=([^\]]*)\](.*)$/.exec(head);
  const epoch = stamp?.[1];
  return isEpoch(epoch) && !stamp?.[2]?.includes("[at=") ? Number(epoch) : undefined;
}

export function classifyStatusLine(raw: string, options: Options = {}) {
  const verb = statusVerb(raw);
  const unstamped = withoutStatusStamps(raw);
  const { statedKey, note, transition } = decisionFields(unstamped);
  const key = statedKey === undefined ? "default" : isKey(statedKey) ? statedKey : undefined;
  const unrecognized = hasUnrecognizedPrefix(unstamped);
  const event = (raw.includes(":") && isVerb(verb)) || unrecognized || leadingLegacyPattern.test(unstamped);
  const quiet = verb === "working" || verb === "paused" || verb === "resolved" || verb === "captain-held";
  const captainRelevant = !quiet && (unrecognized || terminalVerbs.has(verb) || legacyPattern.test(unstamped));
  const prefix = key === undefined ? undefined : reservedPrefix(key, options);
  const trustedTransition = prefix === undefined || speaksForPrefix(note, prefix);
  const unreadSurface = verb === "note" || verb === "followup" ||
    ((verb === "resolved" || verb === "captain-held") && prefix !== undefined && trustedTransition);

  return {
    raw, verb, event, captainRelevant, unreadSurface, note, key, statedKey,
    transition: transition && key !== undefined && trustedTransition,
    terminalDeclaration: unstamped.includes(":") && (verb === "done" || verb === "failed"),
  };
}

export function classifyStatusLog(text: string, options: Options = {}) {
  const events = [];
  const openDecisions = new Map<string, Decision>();
  const closedPhases = new Set<string | typeof keylessPhase>();
  let lastWait: ReturnType<typeof classifyStatusLine> | undefined;
  let fallback: string | undefined;

  for (const raw of decodeStatusLog(text)) {
    if (trimStart(raw) === "") continue;
    fallback = raw;
    const line = classifyStatusLine(raw, options);
    const { verb, key, note, statedKey } = line;

    if (line.event) {
      events.push(line);
      const phase = statedKey === undefined ? keylessPhase : key ?? "";
      if (verb === "resolved") {
        closedPhases.add(phase);
      } else {
        closedPhases.clear();
        lastWait = verb === "paused" || verb === "captain-held" ? line : undefined;
      }
    }

    if (line.terminalDeclaration && (options.kind === "ship" || options.kind === "scout")) {
      openDecisions.clear();
    } else if (line.transition && key !== undefined) {
      if (verb === "needs-decision" || verb === "blocked") {
        openDecisions.delete(key);
        openDecisions.set(key, { key, verb, note });
      } else if (verb === "resolved" || verb === "captain-held") {
        openDecisions.delete(key);
      }
    }
  }

  const latestEvent = events.at(-1)?.raw ?? fallback;
  const waitPhase = lastWait?.statedKey === undefined ? keylessPhase : lastWait.key ?? "";
  const fallbackVerb = latestEvent === undefined ? "" : statusVerb(latestEvent);
  const declaredWait = fallbackVerb === "paused" || fallbackVerb === "captain-held"
    ? latestEvent
    : lastWait?.verb === "paused" && !closedPhases.has(waitPhase) ? lastWait.raw : undefined;
  const decisions = [...openDecisions.values()];
  const decision = decisions.at(-1);
  const current = decision === undefined
    ? declaredWait ?? latestEvent
    : decision.verb + " [key=" + decision.key + "]: " + decision.note;

  return { events, latestEvent, declaredWait, decisions, current };
}
