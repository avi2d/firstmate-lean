import { readFileSync } from "node:fs";

const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const unique = (items) => new Set(items.map(({ id }) => id)).size === items.length;
const label = (value) => typeof value === "string" && /^[a-z0-9][a-z0-9_-]{0,63}$/u.test(value);
const timestamp = (value) => {
  if (typeof value !== "string") return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString() === value;
};
const percent = (value) => value === null || (Number.isFinite(value) && value >= 0 && value <= 100);
const failure = (value) => ["timeout", "rate_limited", "auth_required", "auth_unverified"].includes(value);
const deadline = ({ observedAt, windows }) =>
  Math.min(Date.parse(observedAt) + 120_000, ...windows.filter(({ resetsAt }) => resetsAt !== null).map(({ resetsAt }) => Date.parse(resetsAt)));

function validObservation(observation, writtenAt) {
  if (!record(observation)) return false;
  if (observation.status === "unavailable") return failure(observation.code);
  if (observation.source !== "provider" || !timestamp(observation.observedAt) ||
      Date.parse(observation.observedAt) > writtenAt) return false;
  const { windows } = observation;
  if (!Array.isArray(windows) || windows.length === 0 || !windows.every((window) =>
    record(window) && label(window.id) && (window.status === "not_returned"
      ? (!Object.hasOwn(window, "scope") || label(window.scope)) && window.percentLeft === null && window.resetsAt === null
      : label(window.scope) && percent(window.percentLeft) && (window.resetsAt === null || timestamp(window.resetsAt)))) || !unique(windows)) return false;
  if (observation.status === "stale") return observation.code === null || failure(observation.code);
  return observation.status === "fresh" && timestamp(observation.validUntil) &&
    Date.parse(observation.validUntil) === deadline(observation) && writtenAt < deadline(observation);
}

function validSnapshot(snapshot) {
  if (!record(snapshot) || snapshot.version !== "subquo.v1" || !timestamp(snapshot.writtenAt) ||
      !Array.isArray(snapshot.accounts)) return false;
  return snapshot.accounts.every((account) =>
    record(account) && label(account.id) && ["claude", "codex", "opencode-go"].includes(account.provider) &&
    (!Object.hasOwn(account, "loginEndsInDays") || account.loginEndsInDays === null ||
      (Number.isInteger(account.loginEndsInDays) && account.loginEndsInDays >= 0 && account.loginEndsInDays <= 7)) &&
    validObservation(account.observation, Date.parse(snapshot.writtenAt))) && unique(snapshot.accounts);
}

function availability(scope, windows) {
  const exhausted = windows.filter(({ percentRemaining }) => percentRemaining === 0).map(({ id }) => id);
  const known = windows.every(({ percentRemaining }) => percentRemaining !== null);
  const boundIds = windows.map(({ id }) => id);
  return {
    scope,
    status: known ? "known" : "unknown",
    ...(known ? { effectivePercentRemaining: Math.min(...windows.map(({ percentRemaining }) => percentRemaining)) } : {}),
    boundedBy: boundIds,
    limitingWindowIds: exhausted,
    runway: exhausted.length > 0 ? { status: "exhausted_now", usableRunwaySeconds: 0 } : { status: "unknown" },
  };
}

function providerRow({ id, provider, observation }, now) {
  const identity = { accountKey: id, provider, source: "subquo" };
  if (observation.status === "unavailable") return { ...identity, unavailable: observation.code };
  if (observation.status === "stale" || now < Date.parse(observation.observedAt) || now >= deadline(observation)) {
    return { ...identity, unavailable: "stale" };
  }

  const windows = observation.windows.filter(({ status }) => status !== "not_returned").map(({ id: name, scope, percentLeft, resetsAt }) => ({
    id: name, scope, percentRemaining: percentLeft,
    percentUsed: percentLeft === null ? null : 100 - percentLeft, resetsAt,
  }));
  const account = windows.filter(({ scope }) => scope === "all");
  const scoped = [...new Set(windows.map(({ scope }) => scope))].filter((scope) => scope !== "all");
  const effectiveAvailability = [
    ...(account.length > 0 ? [availability("all_models", account)] : []),
    ...scoped.map((scope) => availability(
      `${scope === "code-review" ? "product" : "model"}:${scope}`,
      [...account, ...windows.filter((window) => window.scope === scope)],
    )),
  ];
  return { ...identity, windows, quotaSemantics: { status: "partial", effectiveAvailability } };
}

try {
  const snapshot = JSON.parse(readFileSync(0, "utf8"));
  if (!validSnapshot(snapshot)) throw new Error();
  const now = Date.now();
  const providers = snapshot.accounts.map((account) => providerRow(account, now));
  process.stdout.write(JSON.stringify({ schemaVersion: 6, source: "subquo", providers }) + "\n");
} catch {
  process.exitCode = 1;
}
