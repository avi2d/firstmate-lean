#!/usr/bin/env bun
const [command] = process.argv.slice(2);

if (command === undefined || command === "--help") {
  console.log("Usage: fm-effect-run.sh <command> [arg ...]");
} else {
  console.error(`fm-effect-run.sh: unknown command: ${command}`);
  process.exitCode = 2;
}
