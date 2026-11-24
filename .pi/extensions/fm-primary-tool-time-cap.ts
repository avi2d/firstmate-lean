import { readFileSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export const DEFAULT_CAP_SECONDS = 90;
const MAX_CAP_SECONDS = 86400;
const OPTIONS_PREFIX = "// @options:";

export type Cap = { seconds: number; invalidConfig?: string };

export type Clamp = {
  tool: "bash" | "codemode";
  requestedSeconds: number | undefined;
  capSeconds: number;
};

export function readCap(configFile: string): Cap {
  let text: string;
  try {
    text = readFileSync(configFile, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { seconds: DEFAULT_CAP_SECONDS };
    return { seconds: DEFAULT_CAP_SECONDS, invalidConfig: String(error) };
  }
  const value = text.trim();
  const seconds = Number(value);
  if (!/^[0-9]+$/.test(value) || seconds < 1 || seconds > MAX_CAP_SECONDS) {
    return { seconds: DEFAULT_CAP_SECONDS, invalidConfig: `not an integer from 1 through ${MAX_CAP_SECONDS}: ${JSON.stringify(value.slice(0, 40))}` };
  }
  return { seconds };
}

function clampBash(input: Record<string, unknown>, capSeconds: number): Clamp | undefined {
  const requested = input.timeout;
  // Pi rejects a non-numeric or non-positive timeout before the command runs.
  if (requested !== undefined && (typeof requested !== "number" || !Number.isFinite(requested) || requested <= 0)) return undefined;
  if (typeof requested === "number" && requested <= capSeconds) return undefined;
  input.timeout = capSeconds;
  return { tool: "bash", requestedSeconds: requested, capSeconds };
}

function clampCodemode(input: Record<string, unknown>, capSeconds: number): Clamp | undefined {
  if (typeof input.code !== "string" || input.code.trim() === "") return undefined;
  const code = input.code;
  const newline = code.indexOf("\n");
  const firstLine = (newline === -1 ? code : code.slice(0, newline)).replace(/\r$/, "");
  const capMs = capSeconds * 1000;
  if (!firstLine.trimStart().startsWith(OPTIONS_PREFIX)) {
    input.code = `${OPTIONS_PREFIX} ${JSON.stringify({ timeout_ms: capMs })}\n${code}`;
    return { tool: "codemode", requestedSeconds: undefined, capSeconds };
  }
  let options: unknown;
  try {
    options = JSON.parse(firstLine.trimStart().slice(OPTIONS_PREFIX.length).trim());
  } catch {
    // Pi fails a malformed options line before the script runs.
    return undefined;
  }
  if (typeof options !== "object" || options === null || Array.isArray(options)) return undefined;
  const fields = options as Record<string, unknown>;
  const requested = fields.timeout_ms;
  if (requested !== undefined && (typeof requested !== "number" || !Number.isSafeInteger(requested) || requested <= 0)) return undefined;
  if (typeof requested === "number" && requested <= capMs) return undefined;
  const rest = newline === -1 ? "" : code.slice(newline);
  input.code = `${OPTIONS_PREFIX} ${JSON.stringify({ ...fields, timeout_ms: capMs })}${rest}`;
  return { tool: "codemode", requestedSeconds: typeof requested === "number" ? requested / 1000 : undefined, capSeconds };
}

// Mutates input in place, which is how Pi's tool_call hands a change to the tool.
export function clampToolInput(toolName: string, input: Record<string, unknown>, capSeconds: number): Clamp | undefined {
  if (toolName === "bash") return clampBash(input, capSeconds);
  if (toolName === "codemode") return clampCodemode(input, capSeconds);
  return undefined;
}

export function clampNote(clamp: Clamp, cap: Cap, nested: boolean): string {
  const what = nested ? `a nested ${clamp.tool} call` : `this ${clamp.tool} call`;
  const asked = clamp.requestedSeconds === undefined ? "no time limit" : `${clamp.requestedSeconds} s`;
  const config = cap.invalidConfig ? ` (config/tool-time-cap is invalid, so the default applies: ${cap.invalidConfig})` : "";
  return `[Pi tool-time cap: ${what} asked for ${asked} and was limited to ${clamp.capSeconds} s${config}. Do not wait inside a tool call; end the turn and let the next wake resume the work.]`;
}

// Filling a missing limit is reported only on a failed call, where a hit
// deadline shows up, so every ordinary bash result does not carry the note.
function shouldReport(clamp: Clamp, isError: boolean): boolean {
  return clamp.requestedSeconds !== undefined || isError;
}

export function isPrimarySession(ctx: ExtensionContext, env: NodeJS.ProcessEnv, codeRoot: string): boolean {
  if (env.FM_TASK_ID || env.FM_TASK_INBOX || env.FM_SUPERVISION_ACTOR) return false;
  try {
    return realpathSync(ctx.cwd) === realpathSync(codeRoot);
  } catch {
    return false;
  }
}

type Pending = { clamp: Clamp; cap: Cap };

export function registerToolTimeCap(pi: ExtensionAPI, options: {
  configFile: string; isPrimary: (ctx: ExtensionContext) => boolean;
}): void {
  const own = new Map<string, Pending>();
  const nestedByTopCall = new Map<string, Pending[]>();

  pi.on("tool_call", (event, ctx) => {
    if (!options.isPrimary(ctx)) return;
    const cap = readCap(options.configFile);
    const clamp = clampToolInput(event.toolName, event.input as Record<string, unknown>, cap.seconds);
    if (!clamp) return;
    if (event.parentToolCallId) {
      const top = event.parentToolCallId.split("/")[0];
      nestedByTopCall.set(top, [...(nestedByTopCall.get(top) ?? []), { clamp, cap }]);
    } else {
      own.set(event.toolCallId, { clamp, cap });
    }
  });

  pi.on("tool_result", (event) => {
    if (event.parentToolCallId) return;
    const mine = own.get(event.toolCallId);
    const nested = nestedByTopCall.get(event.toolCallId) ?? [];
    own.delete(event.toolCallId);
    nestedByTopCall.delete(event.toolCallId);
    const notes = [
      ...(mine && shouldReport(mine.clamp, event.isError) ? [clampNote(mine.clamp, mine.cap, false)] : []),
      ...nested.filter((p) => shouldReport(p.clamp, event.isError)).map((p) => clampNote(p.clamp, p.cap, true)),
    ];
    if (notes.length === 0) return;
    return {
      content: [...event.content, { type: "text" as const, text: [...new Set(notes)].join("\n") }],
      structuredContent: event.structuredContent,
    };
  });
}

export default function (pi: ExtensionAPI): void {
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configFile = join(process.env.FM_CONFIG_OVERRIDE || join(home, "config"), "tool-time-cap");
  registerToolTimeCap(pi, { configFile, isPrimary: (ctx) => isPrimarySession(ctx, process.env, root) });
}
