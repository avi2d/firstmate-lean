#!/usr/bin/env bun
import { Effect } from "effect";
import { runArmPolicy } from "../bin/fm-arm-command-policy.mjs";
import { runCdPolicy } from "../bin/fm-cd-command-policy.mjs";
import { runSharePolicy } from "../bin/fm-share-guard/policy";

const [command, ...args] = process.argv.slice(2);

if (command === "arm-policy") {
  runArmPolicy(args);
} else if (command === "cd-policy") {
  runCdPolicy(args);
} else if (command === "share-policy") {
  process.stdout.write(Effect.runSync(runSharePolicy(args)));
} else if (command === undefined || command === "--help") {
  console.log("Usage: fm-effect-run.sh <command> [arg ...]");
} else {
  console.error(`fm-effect-run.sh: unknown command: ${command}`);
  process.exitCode = 2;
}
