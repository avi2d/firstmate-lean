import { Schema } from "effect";

const asciiSlug = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9._-]+$/));
const oneLine = Schema.String.check(Schema.isPattern(/^[^\n]*$/));

function lines(text: string): ReadonlyArray<string> {
  if (text === "") return [];
  const parts = text.split("\n");
  if (text.endsWith("\n")) parts.pop();
  return parts;
}

export const TaskMeta = Schema.StructWithRest(Schema.Struct({
  backend: Schema.optionalKey(oneLine),
  branch: Schema.optionalKey(oneLine),
  harness: Schema.optionalKey(oneLine),
  kind: Schema.optionalKey(oneLine),
  mode: Schema.optionalKey(oneLine),
  pr: Schema.optionalKey(oneLine),
  project: Schema.optionalKey(oneLine),
  window: Schema.optionalKey(oneLine),
  worktree: Schema.optionalKey(oneLine),
  yolo: Schema.optionalKey(oneLine),
}), [Schema.Record(oneLine, oneLine)]);

const taskMeta = Schema.decodeUnknownSync(TaskMeta);

export function decodeTaskMeta(text: string): typeof TaskMeta.Type {
  const fields = lines(text).flatMap((line) => {
    const separator = line.indexOf("=");
    return separator > 0 ? [[line.slice(0, separator), line.slice(separator + 1)]] : [];
  });
  return taskMeta(Object.fromEntries(fields));
}

export const StatusLog = Schema.Array(oneLine);
const statusLog = Schema.decodeUnknownSync(StatusLog);

export const decodeStatusLog = (text: string): typeof StatusLog.Type => statusLog(lines(text));

export const ForgeProvider = Schema.Literals(["github", "gitlab", "gerrit", "forgejo"]);
export const PrPollRecord = Schema.Struct({
  provider: ForgeProvider,
  url: Schema.NonEmptyString,
  host: Schema.String.check(Schema.isPattern(/^[a-z0-9.-]{1,253}$/)),
  path: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*$/)),
  number: Schema.String.check(Schema.isPattern(/^[1-9][0-9]*$/)),
}).check(Schema.makeFilter(({ provider, url, host, path, number }) => {
  const segments = path.split("/");
  if (segments.some((segment) => segment === "." || segment === "..")) return "Path contains a dot segment";
  if ((provider === "github" || provider === "forgejo") && segments.length !== 2) return "Path must name an owner and repository";
  if (provider === "gitlab" && segments.length < 2) return "Path must name a group and project";
  const route = {
    github: path + "/pull",
    gitlab: path + "/-/merge_requests",
    gerrit: "c/" + path + "/+",
    forgejo: path + "/pulls",
  }[provider];
  return url === "https://" + host + "/" + route + "/" + number || "URL must match the sidecar identity";
}));

const prPollLines = Schema.decodeUnknownSync(Schema.Tuple([
  Schema.String, Schema.String, Schema.String, Schema.String, Schema.String, Schema.Literal(""),
]));
const prPollRecord = Schema.decodeUnknownSync(PrPollRecord);

export function decodePrPollRecord(text: string): typeof PrPollRecord.Type {
  const [provider, url, host, path, number] = prPollLines(text.split("\n"));
  return prPollRecord({ provider, url, host, path, number });
}

export const DeliveryMode = Schema.Literals(["no-mistakes", "direct-PR", "local-only"]);
export const RegisteredDeliveryMode = Schema.Union([DeliveryMode, Schema.Literal("no-mistakes-prod-only")]);
export const ProjectRegistry = Schema.Array(Schema.Struct({
  name: Schema.NonEmptyString,
  annotations: Schema.Array(Schema.NonEmptyString),
  description: oneLine,
}));
const projectRegistry = Schema.decodeUnknownSync(ProjectRegistry);

export function decodeProjectRegistry(text: string): typeof ProjectRegistry.Type {
  return projectRegistry(lines(text).filter((line) => line.startsWith("- ")).map((line) => {
    const [, name, annotations, description] = /^- (.+?)(?: \[([^\]]*)\])?(?: - (.*))?$/.exec(line) ?? [];
    return { name, annotations: annotations?.split(/[ \t]+/).filter(Boolean) ?? [], description: description ?? "" };
  }));
}

export const RemoteHomeRegistry = Schema.Array(Schema.Struct({
  id: asciiSlug,
  host: Schema.NonEmptyString,
  root: Schema.NonEmptyString,
  home: Schema.NonEmptyString,
  session: asciiSlug,
  scope: Schema.NonEmptyString,
  projects: oneLine,
  added: Schema.String.check(Schema.isPattern(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)),
}));
const remoteHomeRegistry = Schema.decodeUnknownSync(RemoteHomeRegistry);
const remoteHomeRow = /^- ([A-Za-z0-9._-]+) - .+ \(host:[ \t]*([^;)]*);[ \t]*root:[ \t]*([^;)]*);[ \t]*home:[ \t]*([^;)]*);[ \t]*(?:session:[ \t]*([^;]*);[ \t]*)?scope:[ \t]*(.*);[ \t]*projects:[ \t]*([^;)]*);[ \t]*added[ \t]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[ \t]*$/;

export function decodeRemoteHomeRegistry(text: string): typeof RemoteHomeRegistry.Type {
  return remoteHomeRegistry(lines(text).filter((line) => line.startsWith("- ")).map((line) => {
    const [, id, host, root, home, session, scope, projects, added] = remoteHomeRow.exec(line) ?? [];
    return { id, host, root, home, session: session?.trim() || "fm-remote", scope, projects, added };
  }));
}

const optional = Schema.optionalKey;
const providerId = Schema.String.check(Schema.isPattern(/^[a-z0-9]+(?:-[a-z0-9]+)*$/));
const profileFloor = Schema.Struct({
  scope: Schema.NonEmptyString,
  min_percent: Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 100 })),
});
const ruleFloor = profileFloor.mapFields((fields) => ({ ...fields, provider: providerId }));
const profile = Schema.Struct({
  harness: Schema.NonEmptyString,
  model: optional(Schema.NonEmptyString),
  effort: optional(Schema.Literals(["low", "medium", "high", "xhigh", "max", "ultra"])),
  provider: optional(providerId),
  quota_scope: optional(Schema.NonEmptyString),
  claude_account: optional(Schema.NonEmptyString),
  floor: optional(profileFloor),
});
const profileChoice = Schema.Union([profile, Schema.NonEmptyArray(profile)]);
const rule = Schema.Struct({
  when: Schema.NonEmptyString,
  use: profileChoice,
  why: optional(Schema.String),
  approval: optional(Schema.Literal("captain")),
  min_confidence: optional(Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 1 }))),
  floor: optional(ruleFloor),
  select: optional(Schema.Literal("quota-balanced")),
});

export const CrewDispatchConfig = Schema.Struct({
  array_order: optional(Schema.Literal("preference")),
  preferred_provider: optional(providerId),
  shared_quota: optional(Schema.Boolean),
  rules: optional(Schema.Array(rule)),
  default: optional(profileChoice),
}).check(Schema.makeFilter(({ array_order, rules }) =>
  array_order !== "preference" || !rules?.some(({ select }) => select !== undefined) ||
  "array_order preference conflicts with rule select",
));

export const decodeCrewDispatchConfig = Schema.decodeUnknownSync(Schema.fromJsonString(CrewDispatchConfig));
